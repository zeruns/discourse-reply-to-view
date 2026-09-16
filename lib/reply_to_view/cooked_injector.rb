# frozen_string_literal: true

# 作者: discourse-reply-to-view
#
# 序列化期原文注入器：PostSerializer 输出 cooked 时按当前请求用户权限动态注入。
#
# 【安全架构 - 最高优先级】
#   1. 数据库中的 cooked 字段只存储占位容器（<div class="rtv-block rtv-reply"></div>），
#      不含任何隐藏原文。因此所有直读 cooked 的场景（搜索索引、通知邮件、每日摘要、
#      Onebox、话题列表摘要、话题导出、RSS）天然不泄露原文。
#   2. 本注入器是全站唯一会把隐藏原文写回 HTML 的位置，且仅在 PostSerializer
#      序列化路径上执行 —— 即每个携带用户会话的请求都经过权限判定。
#   3. 对齐校验（防错位注入）：注入前必须确认 Ruby 端从 raw 提取的块序列
#      与 cook 期写入容器的 data-rtv-index / data-rtv-type / data-rtv-checksum
#      完全一致。任何不一致（raw 在 cook 后被外部工具改动、极端解析差异）
#      都会导致整帖降级为占位符 —— 宁可整帖隐藏，绝不错位注入。
#   4. 注入的原文一律通过 Post#cook（Discourse 官方 Markdown 管线 + 白名单净化），
#      不存在绕过白名单拼 HTML 的路径，杜绝 XSS。
#   5. 匿名请求输出统一的占位符版本，可安全进入 CDN / 应用级匿名共享缓存；
#      登录用户响应不进入匿名缓存（核心按 Cookie 区分），
#      且本插件不做任何跨请求的内容片段缓存，不存在低权限命中高权限缓存的可能。
module ReplyToView
  module CookedInjector
    CONTAINER_SELECTOR = "div.rtv-block[data-rtv-index]"

    class << self
      # @param html    [String] PostSerializer 输出的 cooked HTML
      # @param post    [Post]   帖子对象（raw 为原文来源）
      # @param user    [User, nil] 当前请求用户（nil = 匿名）
      def inject(html, post, user)
        return html if html.blank? || !html.include?("rtv-block")
        return html if post.nil? || post.raw.blank?

        doc = Nokogiri::HTML5.fragment(html)
        containers = doc.css(CONTAINER_SELECTOR)
        return html if containers.empty?

        # 插件总开关关闭：历史标记内容以明文回显（无框直出），
        # 保证站点关闭功能后内容不丢失、开关可逆
        unless SiteSetting.enable_rtv
          return rebuild(doc, post, user, all_visible: true, inert: true)
        end

        # 作者信任等级低于 min_trust_level_to_use：标记对该帖不生效，内容直出
        inert = Guard.author_below_use_threshold?(post)

        rebuild(doc, post, user, all_visible: false, inert: inert)
      end

      private

      # 对齐校验:容器序列（类型 / 计数 / 指纹）与某个 raw 的提取结果是否逐块一致
      def aligned?(containers, blocks)
        blocks.size == containers.size && containers.each_with_index.all? do |el, i|
          block = blocks[i]
          el["data-rtv-type"] == block.type.to_s &&
            el["data-rtv-checksum"] == block.checksum.to_s(16) &&
            (el["data-rtv-count"] || "") == (block.count ? block.count.to_s : "")
        end
      end

      # 找到与容器对齐的块序列:优先帖子原文 raw;
      # 不一致时依次尝试各语言本地化的 raw（本地化 cooked 的容器指纹
      # 对应的是翻译后内容 —— 内容本地化站点的多语言变体走此处对齐）。
      # 全部无法对齐时返回 nil,由调用方整帖降级为占位符。
      def resolve_blocks(post, containers)
        blocks = Engine.extract(post.raw.to_s)
        return blocks if aligned?(containers, blocks)

        post.localizations.find_each do |loc|
          candidate = Engine.extract(loc.raw.to_s)
          return candidate if aligned?(containers, candidate)
        end

        nil
      end

      def rebuild(doc, post, user, all_visible:, inert:)
        containers = doc.css(CONTAINER_SELECTOR)

        # —— 对齐校验（见模块注释第 3 条）——
        blocks = resolve_blocks(post, containers)
        aligned = !blocks.nil?

        guard = Guard.new(user, post)

        containers.each_with_index do |el, i|
          # post_id 属性在序列化阶段动态注入（cook 阶段不感知帖子上下文，
          # 这是数据边界要求：cook 只做语法解析生成容器结构）
          el["data-post-id"] = post.id.to_s

          block = aligned ? blocks[i] : nil

          if block && (all_visible || inert || guard.can_view?(block))
            state =
              if inert || all_visible
                "inert" # 标记不生效：无框直出
              elsif guard.author?
                "owner" # 作者本人查看：前端渲染虚线边框 + 淡色提示条
              else
                "unlocked"
              end

            el["data-rtv-state"] = state
            el.inner_html = render_block(post, block)
          else
            # 无权限（或对齐校验失败）：保留占位符，绝不注入原文
            el["data-rtv-state"] = "locked"
            build_placeholder!(el)
          end
        end

        doc.to_html
      end

      # 渲染块内容原文（Markdown → 白名单 HTML），结果按 post 版本 + 内容指纹缓存。
      # 注意：缓存的是“与用户无关”的渲染产物，权限判定本身从不缓存。
      def render_block(post, block)
        key = "rtv_rch:#{post.id}:#{post.version}:#{block.checksum.to_s(16)}"
        Discourse.cache.fetch(key, expires_in: 24.hours) do
          # 剥离嵌套标记，避免注入内容二次 cook 时再次生成占位容器
          content = Engine.strip_marks(block.content)
          post.cook(content).to_s
        end
      end

      # 构建占位框内容：文案全部走 I18n（按请求用户 locale 渲染），禁止硬编码。
      # rtv-actions 节点是前端 Glimmer 组件（登录/回复按钮）的挂载点。
      def build_placeholder!(el)
        type = (el["data-rtv-type"] || "reply").to_sym
        count = (el["data-rtv-count"] || "").to_i

        text =
          if type == :login
            I18n.t("reply_to_view.login.placeholder")
          elsif count.positive? && SiteSetting.reply_to_view_allow_count
            I18n.t("reply_to_view.reply.count_placeholder", count: count)
          else
            I18n.t("reply_to_view.reply.placeholder")
          end

        el.inner_html = <<~HTML
          <div class="rtv-placeholder">#{CGI.escapeHTML(text)}</div>
          <div class="rtv-actions"></div>
        HTML
      end
    end
  end
end
