# frozen_string_literal: true

# 作者: discourse-reply-to-view
#
# 请求级状态存储（官方姿势:继承 ActiveSupport::CurrentAttributes）。
#
# 【为什么不用 RequestStore】Discourse 核心未引入 RequestStore gem,
# 官方的每请求隔离机制是 Rails Executor + CurrentAttributes:
#   - 生产环境:每个请求开始时由 Executor 自动重置
#   - 测试环境:每个用例后由 rspec-rails 集成的 Executor 自动重置
#
# 用于单次请求内记忆化 (user, topic) 的回复足迹查询,
# 避免话题页 20 帖逐帖重复查询 —— 绝不做跨请求缓存（安全设计,详见 Guard）。
module ReplyToView
  class Current < ActiveSupport::CurrentAttributes
    attribute :reply_data_cache
  end
end
