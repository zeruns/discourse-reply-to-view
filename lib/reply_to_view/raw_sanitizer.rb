# frozen_string_literal: true

# 作者: discourse-reply-to-view
#
# raw 文本出口净化器：封堵所有直接返回帖子原始文本的接口。
#
# 【安全背景】核心存在多个“能看帖即可取 raw”的出口：
#   - GET /posts/:id/raw              （PostsController#markdown_id）
#   - GET /raw/:topic_id/:post_number （PostsController#markdown_num）
#   - GET /raw/:topic_id?revision=N   （修订历史原文）
#   - GET /posts.json?id=latest       （PostSerializer 以 add_raw: true 输出 raw）
# 这些出口若不处理，未解锁用户可绕过 cooked 占位符直接读出 [reply] 内的原文。
#
# 净化策略：作者本人、全站管理员、全站版主可获取带标记的完整原文（编辑需要）；
# 其他所有用户（包括已回复解锁的用户 —— 解锁仅对渲染视图生效）一律将标记块
# 替换为 i18n 占位提示文本。
module ReplyToView
  module RawSanitizer
    class << self
      # @param raw  [String] 帖子原始文本
      # @param user [User, nil] 当前请求用户
      # @param post [Post, nil] 帖子对象（nil 时按非特权处理 —— 默认拒绝）
      def sanitize(raw, user, post)
        return raw if raw.blank?
        return raw unless SiteSetting.enable_rtv
        return raw if privileged?(user, post)

        Engine.replace_blocks(raw, placeholder_text)
      end

      private

      def privileged?(user, post)
        return false if user.nil? || post.nil?
        Guard.new(user, post).privileged?
      end

      def placeholder_text
        I18n.t("reply_to_view.sanitized_placeholder")
      end
    end
  end
end
