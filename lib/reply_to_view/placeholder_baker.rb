# frozen_string_literal: true

# 作者: discourse-reply-to-view
#
# 占位文案烘焙器 + 搜索索引脱敏器。
#
# 【占位文案烘焙】
# cook 阶段（markdown-it）产出的容器是纯结构（空 div，不含任何文案 —— cook 环境
# 无用户上下文，也不应写入任何语言文案）。文案在两个层面注入：
#   1. 存储层（本文件 bake!）：帖子保存后的 CookedPostProcessor 阶段（官方
#      post_process_cooked 事件）向数据库中的 cooked 写入一份站点默认语言的
#      占位提示 —— 覆盖所有“直读 cooked”的下游场景：搜索索引、通知邮件、
#      每日摘要、Onebox 预览、话题列表摘要、话题导出、RSS。
#   2. 序列化层（CookedInjector）：PostSerializer 输出时按当前请求用户的
#      locale 重建占位文案，满足 i18n 精确到用户的需求。
#
# 【搜索索引脱敏】（防御性加固）
# 核心搜索索引以 cooked 为数据源，存储层占位文案已保证原文不入索引；
# scrub 再将 rtv 容器统一替换为中性占位文本，作为占位烘焙缺失场景
# （如外部导入数据、未来核心流程变化）下的第二道防线。
module ReplyToView
  module PlaceholderBaker
    class << self
      # 官方钩子 DiscourseEvent.on(:post_process_cooked, doc, post) 的处理器
      def bake!(doc, post)
        return unless SiteSetting.enable_rtv
        return if post.nil? || !post.raw.to_s.include?("[")

        doc.css("div.rtv-block").each do |el|
          # 幂等：已烘焙过的容器不重复处理
          next if el.at_css(".rtv-placeholder").present?

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

          el.add_child(%(<div class="rtv-placeholder">#{CGI.escapeHTML(text)}</div>))
        end
      end
    end
  end

  module SearchScrubber
    class << self
      # 将 cooked 中的 rtv 容器替换为中性占位文本，返回脱敏后的 HTML 字符串
      def scrub(html)
        return html if html.blank? || !html.include?("rtv-block")

        doc = Nokogiri::HTML5.fragment(html)
        doc.css("div.rtv-block").each do |el|
          el.replace(I18n.t("reply_to_view.search_placeholder"))
        end
        doc.to_html
      end
    end
  end
end
