# frozen_string_literal: true

# 作者: discourse-reply-to-view
#
# 核心类的 prepend 扩展模块集合。
#
# 【加载说明】本文件必须通过 require_relative 加载（顶层命名空间）。
# plugin.rb 由 Plugin::Instance#activate! 以 instance_eval 执行,
# 其内定义的常量会嵌套在插件单例作用域下 —— 因此所有 Extension 模块
# 统一放在 lib 中定义,plugin.rb 仅负责 prepend 注册。
module ReplyToView
  # ============ PostSerializer 扩展（唯一的内容注入点） ============
  # 【安全优先级：最高】
  # cooked:数据库只存占位容器,序列化时按当前请求用户权限动态注入原文;
  # raw:raw 属性仅在核心以 add_raw 输出时出现,此处统一做出口净化,
  # 确保非特权用户拿到的 raw 不含隐藏原文。
  module PostSerializerExtension
    def cooked
      html = super
      return html if html.blank?
      # 匿名 / 后台任务等无用户上下文时,注入器内部全部输出占位符（默认拒绝）
      ::ReplyToView::CookedInjector.inject(html, object, scope&.user)
    end

    def raw
      value = super
      return value if value.blank?
      ::ReplyToView::RawSanitizer.sanitize(value, scope&.user, object)
    end
  end

  # ============ PostRevisionSerializer 扩展（修订历史 diff 脱敏） ============
  # 【安全优先级：最高】
  # 核心修订历史的 body_changes.side_by_side_markdown 输出 raw 的词级 diff,
  # 含 [reply] / [login] 标记内的隐藏原文,是 cooked 占位体系之外的泄露面。
  # 非特权用户（作者/管理员/版主/分类版主之外）查看含标记帖子的修订时,
  # 整个 body_changes 替换为占位提示 —— 保守方向,杜绝任何 diff 还原的可能。
  # 特权用户（编辑需要）不受影响。
  module PostRevisionSerializerExtension
    def body_changes
      changes = super
      return changes if changes.nil? || !SiteSetting.enable_rtv

      post = object.post
      return changes if post.nil?

      # 仅当新旧两个版本的 raw 都不含标记时才放行
      # （防止“先带标记后删除”的历史版本经 diff 泄露）
      old_raw = previous.respond_to?(:[]) ? previous["raw"].to_s : ""
      new_raw = current.respond_to?(:[]) ? current["raw"].to_s : ""
      return changes if !Engine.contains_marks?(old_raw) && !Engine.contains_marks?(new_raw)

      # 特权用户可查看完整 diff（编辑需要）
      return changes if Guard.new(scope&.user, post).privileged?

      placeholder = I18n.t("reply_to_view.revision_placeholder")
      {
        inline: %(<p>#{CGI.escapeHTML(placeholder)}</p>),
        side_by_side: %(<p>#{CGI.escapeHTML(placeholder)}</p>),
        side_by_side_markdown: placeholder,
      }
    end
  end

  # ============ PostsController 扩展（封堵 raw 文本出口） ============
  # 核心的 markdown 系列端点（/posts/:id/raw、/raw/:topic_id/:post_number、
  # 修订历史）对“能看帖的用户”直接输出 post.raw,必须统一净化。
  module PostsControllerExtension
    # 单帖 raw 出口（/posts/:id/raw 与 /raw/:topic_id/:post_number 共用）
    def markdown(post)
      if post && guardian.can_see?(post)
        render plain: ::ReplyToView::RawSanitizer.sanitize(post.raw, current_user, post)
      else
        raise Discourse::NotFound
      end
    end

    # 修订历史 raw 出口（/raw/:topic_id/:post_number?revision=N）
    def markdown_for_revision
      raw = super
      post = Post.find_by(
        topic_id: params[:topic_id].to_i,
        post_number: params[:post_number].to_i,
      )
      # post 为 nil 时 sanitize 内部按非特权处理（默认拒绝）
      ::ReplyToView::RawSanitizer.sanitize(raw, current_user, post)
    end

    # 整主题 raw 导出（/raw/:topic_id）—— 与核心逻辑一致,仅对 raw 做净化。
    # 契约:返回拼接后的 Markdown 字符串,由外层 markdown_num 统一 render
    # （核心的 MARKDOWN_TOPIC_PAGE_SIZE 为私有常量,无法从扩展模块引用,
    # 此处取相同值 100,漂移仅影响分页大小,不影响安全）
    RTV_MARKDOWN_TOPIC_PAGE_SIZE = 100

    def markdown_for_topic
      topic_view =
        TopicView.new(
          params[:topic_id],
          current_user,
          page: params[:page],
          limit: RTV_MARKDOWN_TOPIC_PAGE_SIZE,
        )
      topic_view.posts.select { |post|
        guardian.can_see?(post)
      }.map { |post|
        <<~MD
          #{post.user.username} | #{post.updated_at} | ##{post.post_number}

          #{::ReplyToView::RawSanitizer.sanitize(post.raw, current_user, post)}

          -------------------------
        MD
      }.join
    end
  end
end
