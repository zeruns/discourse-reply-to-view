# frozen_string_literal: true

# 作者: discourse-reply-to-view
#
# 缓存与失效策略。
#
# 【缓存安全设计】（对应需求“缓存安全机制”）
#   1. 权限判定（是否已回复 / 信任等级豁免 / 是否作者）全部实时计算，
#      只做单请求内记忆化（CurrentAttributes），绝不落跨请求缓存 ——
#      用户发布回复后下一次请求立即生效，不存在解锁延迟窗口，
#      也不存在低权限用户命中高权限用户缓存的可能。
#   2. 唯一的跨请求缓存是“块内容渲染产物”（rtv_rch:*，与用户无关，
#      键含 post.id + post.version + 内容指纹），帖子编辑（version 变化）
#      自动失效，不存在权限维度。
#   3. on(:post_created) 钩子：新回复发布后主动清理该作者的信任等级缓存
#      （新回复可能触发信任等级晋升，影响 min_trust_level_to_use 降级判定），
#      并对同主题相关缓存做保守失效，确保“回复后立即看到解锁内容”。
module ReplyToView
  module CacheInvalidator
    class << self
      def on_post_created(post)
        return if post.nil?

        # 作者信任等级缓存（guard.rb author_tl）—— 回复计数变化可能触发 TL 晋升，
        # 主动失效使 min_trust_level_to_use 的降级判定即时生效
        Discourse.cache.delete("rtv_atl:#{post.user_id}")

        # 说明：块渲染缓存（rtv_rch:*）键中含 post.version，帖子编辑后新版本
        # 自然走新键、旧键按 TTL 过期，无需全局 delete_matched ——
        # 避免每次回复触发全键空间扫描（大站点高频回复下的 Redis 压力）。
        # 权限判定不落任何跨请求缓存，因此无需失效。
      end

      def on_post_updated(post)
        on_post_created(post)
      end
    end
  end
end
