# frozen_string_literal: true

# 作者: discourse-reply-to-view
#
# 可见性判定引擎：所有 [reply] / [login] 标记的解锁判定 100% 在服务端完成。
#
# 【安全设计】
#   1. 判定优先级（从高到低）：
#      ① 全站管理员 / 全站版主 / 该帖所属分类的分类版主 —— 始终可见
#      ② 帖子作者本人 —— 始终可见
#      ③ min_trust_level_to_bypass 信任等级豁免（仅对 [reply] 生效，[login] 不受该设置影响）
#      ④ 普通用户按站点模式判定（any_reply / exact_post）
#      ⑤ 进阶计数模式 [reply=N]（reply_to_view_allow_count 启用时）
#   2. 回复状态查询按“单次请求”维度记忆化（ReplyToView::Current），
#      绝不做跨请求缓存 —— 避免“回复后延迟可见”与低权限命中高权限缓存的窗口，
#      这是缓存安全（需求四.4）的前提：宁可多查一次数据库，不给泄露留任何时间差。
#   3. 所有判定失败路径（用户为空、主题缺失、异常数据）一律返回不可见 —— 默认拒绝。
module ReplyToView
  class Guard
    def initialize(user, post)
      @user = user
      @post = post
    end

    # 判定给定块对当前用户是否可见
    def can_view?(block)
      return false if block.nil?
      return false if @post.nil?
      return true if privileged?

      case block.type
      when :login
        # 已登录用户（TL0~TL4）即可见完整内容；信任等级豁免设置对本标记不生效
        !@user.nil?
      when :reply
        return false if @user.nil?
        return true if bypass_trust_level?

        data = reply_data
        if block.count && SiteSetting.reply_to_view_allow_count
          # 进阶计数模式：本主题下有效回复总数 >= N
          data[:total] >= block.count
        elsif SiteSetting.reply_to_view_mode == "exact_post"
          # 精确楼层模式：必须直接回复过该内容所在楼
          unlocked_exact_post?(data)
        else
          # 默认 any_reply 模式：在本主题发布过任意有效回复即解锁
          data[:replied]
        end
      else
        false
      end
    rescue StandardError => e
      Rails.logger.warn("reply-to-view guard error: #{e.class} #{e.message}")
      # 判定异常时保守处理：不可见
      false
    end

    # 特权用户：帖子作者 / 主题楼主 / 全站管理员 / 全站版主 / 对应分类的分类版主
    def privileged?
      return @privileged if defined?(@privileged)
      @privileged =
        !@user.nil? && (
          @user.id == @post.user_id ||
          @post.topic&.user_id == @user.id ||
          @user.staff? ||
          category_moderator?
        )
    end

    # 当前请求用户是否为帖子作者本人（用于前端“作者提示条”展示）
    def author?
      !@user.nil? && @user.id == @post.user_id
    end

    # 当前用户是否可查看该帖的全部隐藏块
    # （特权,或满足所有块的解锁条件）。用于本地化变体的放行判定。
    def all_blocks_visible?
      blocks = Engine.extract(@post.raw.to_s)
      return true if blocks.empty?
      privileged? || blocks.all? { |b| can_view?(b) }
    end

    # 信任等级豁免（仅 [reply]）：0 表示不启用豁免
    def bypass_trust_level?
      min = SiteSetting.min_trust_level_to_bypass.to_i
      min.positive? && @user.trust_level >= min
    end

    # 帖子作者的信任等级是否低于 min_trust_level_to_use（标记对该帖不生效，内容直出）
    def self.author_below_use_threshold?(post)
      min = SiteSetting.min_trust_level_to_use.to_i
      return false if min <= 0
      author_tl(post) < min
    end

    # 作者信任等级（短 TTL 缓存：该值只影响“标记是否失效”的降级判定，
    # 不参与任何解锁判定，因此允许极短的跨请求缓存以避免列表页逐帖查询）
    def self.author_tl(post)
      Discourse.cache.fetch("rtv_atl:#{post.user_id}", expires_in: 5.minutes) do
        User.where(id: post.user_id).pick(:trust_level) || 0
      end
    end

    private

    # 分类版主判定复用核心 Guardian 的分类版主作用域
    def category_moderator?
      category = @post.topic&.category
      return false if category.nil?
      Guardian.new(@user).is_category_group_moderator?(category)
    end

    # 当前用户在本主题下的有效回复足迹。
    # “有效回复”定义：未删除（deleted_at 为空）、未被社区标记隐藏（hidden 为 false）。
    # 审核中的队列帖子（ReviewableQueuedPost）尚不会生成 Post 记录，天然被排除。
    # 同一请求内对相同 (user, topic) 只查询一次（请求级记忆化,见 ReplyToView::Current）。
    def reply_data
      return @reply_data if @reply_data
      return EMPTY_REPLY_DATA if @user.nil? || @post.topic_id.nil?

      cache = (Current.reply_data_cache ||= {})
      cache_key = "rtv_rd:#{@user.id}:#{@post.topic_id}"
      @reply_data = (cache[cache_key] ||= begin
        # 说明:未采用 TopicUser.posted 非规范化标志做快速短路 ——
        # import_mode / auto_track:false 的发帖路径不写该标志（假阴性会导致
        # 已回复用户无法解锁）,且本查询带索引且请求级记忆化,开销可忽略
        rows = Post
          .where(user_id: @user.id, topic_id: @post.topic_id)
          .where(deleted_at: nil)
          .where(hidden: false)
          .pluck(:reply_to_post_number)

        # 直接回复主题（reply_to_post_number 为空）在 exact_post 模式下视作回复 1 楼（主楼）
        target_post_numbers = rows.map { |pn| pn || 1 }
        {
          # 注意不能用 rows.any?：直接回复主题的行值为 nil，
          # 无块 any? 按真值判断会把 [nil] 当作空
          replied: rows.present?,
          total: rows.size,
          target_post_numbers: target_post_numbers.uniq,
        }
      end)
    end

    def unlocked_exact_post?(data)
      data[:target_post_numbers].include?(@post.post_number)
    end

    EMPTY_REPLY_DATA = { replied: false, total: 0, target_post_numbers: [] }.freeze
  end
end
