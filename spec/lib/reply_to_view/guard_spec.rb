# frozen_string_literal: true

# 权限判定引擎单元测试：覆盖完整判定矩阵
RSpec.describe ReplyToView::Guard do
  fab!(:author) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:topic) { Fabricate(:topic, user: author) }
  fab!(:target_post) { Fabricate(:post, topic: topic, user: author) }
  fab!(:viewer) { Fabricate(:user, trust_level: TrustLevel[0]) }

  let(:reply_block) { ReplyToView::Engine::Block.new(type: :reply, count: nil, content: "x", index: 1, checksum: 0) }
  let(:login_block) { ReplyToView::Engine::Block.new(type: :login, count: nil, content: "x", index: 1, checksum: 0) }
  let(:count_block) { ReplyToView::Engine::Block.new(type: :reply, count: 3, content: "x", index: 1, checksum: 0) }

  def guard_for(user)
    described_class.new(user, target_post)
  end

  before do
    # 请求级缓存在用例间手动清理（生产环境由 Rails Executor 每请求重置）,
    # 避免 (user, topic) 回复足迹缓存跨用例残留
    ReplyToView::Current.reset
  end

  describe "[login-visible] 标记" do
    it "匿名不可见" do
      expect(guard_for(nil).can_view?(login_block)).to be false
    end

    it "任意已登录用户（TL0~TL4）可见" do
      expect(guard_for(viewer).can_view?(login_block)).to be true
    end

    it "信任等级豁免设置不影响 login 判定（豁免关闭/开启行为一致）" do
      SiteSetting.min_trust_level_to_bypass = 4
      expect(guard_for(viewer).can_view?(login_block)).to be true
      SiteSetting.min_trust_level_to_bypass = 0
      expect(guard_for(viewer).can_view?(login_block)).to be true
    end
  end

  describe "[reply-visible] 标记 - 特权判定" do
    before { SiteSetting.min_trust_level_to_bypass = 0 }
    it "匿名不可见" do
      expect(guard_for(nil).can_view?(reply_block)).to be false
    end

    it "帖子作者始终可见" do
      expect(guard_for(author).can_view?(reply_block)).to be true
    end

    it "主题楼主可见（即使不是帖子作者）" do
      starter = Fabricate(:user)
      other_topic = Fabricate(:topic, user: starter)
      author_reply = Fabricate(:post, topic: other_topic, user: author)
      expect(described_class.new(starter, author_reply).can_view?(reply_block)).to be true
    end

    it "全站管理员始终可见" do
      expect(guard_for(Fabricate(:admin)).can_view?(reply_block)).to be true
    end

    it "全站版主始终可见" do
      expect(guard_for(Fabricate(:moderator)).can_view?(reply_block)).to be true
    end

    it "对应分类的分类版主始终可见（需开启核心分类版主功能）" do
      SiteSetting.enable_category_group_moderation = true
      cat_mod = Fabricate(:user)
      group = Fabricate(:group)
      topic.category.moderating_groups << group
      group.add(cat_mod)

      expect(guard_for(cat_mod).can_view?(reply_block)).to be true
    end

    it "其他分类的分类版主不可见" do
      SiteSetting.enable_category_group_moderation = true
      other_mod = Fabricate(:user)
      other_category = Fabricate(:category)
      group = Fabricate(:group)
      other_category.moderating_groups << group
      group.add(other_mod)

      expect(guard_for(other_mod).can_view?(reply_block)).to be false
    end
  end

  describe "[reply-visible] 标记 - 信任等级豁免" do
    it "TL >= min_trust_level_to_bypass 时无需回复即可见" do
      SiteSetting.min_trust_level_to_bypass = 2
      tl2 = Fabricate(:user, trust_level: TrustLevel[2])
      expect(guard_for(tl2).can_view?(reply_block)).to be true
    end

    it "设置为 0 时完全不启用豁免（TL4 也需回复）" do
      SiteSetting.min_trust_level_to_bypass = 0
      tl4 = Fabricate(:user, trust_level: TrustLevel[4])
      expect(guard_for(tl4).can_view?(reply_block)).to be false
    end
  end

  describe "[reply-visible] 标记 - any_reply 模式（默认）" do
    before { SiteSetting.min_trust_level_to_bypass = 0 }

    it "发布过任意有效回复即解锁" do
      Fabricate(:post, topic: topic, user: viewer, reply_to_post_number: target_post.post_number)
      expect(guard_for(viewer).can_view?(reply_block)).to be true
    end

    it "已删除的回复不算有效回复" do
      p = Fabricate(:post, topic: topic, user: viewer)
      PostDestroyer.new(Fabricate(:admin), p).destroy
      expect(guard_for(viewer).can_view?(reply_block)).to be false
    end

    it "被标记隐藏（hidden）的回复不算有效回复" do
      Fabricate(:post, topic: topic, user: viewer, hidden: true)
      expect(guard_for(viewer).can_view?(reply_block)).to be false
    end
  end

  describe "[reply-visible] 标记 - exact_post 模式" do
    before do
      SiteSetting.min_trust_level_to_bypass = 0
      SiteSetting.reply_to_view_mode = "exact_post"
    end

    it "直接回复目标楼层后该楼解锁" do
      Fabricate(:post, topic: topic, user: viewer, reply_to_post_number: target_post.post_number)
      expect(guard_for(viewer).can_view?(reply_block)).to be true
    end

    it "仅回复其他楼层不能解锁目标楼" do
      other = Fabricate(:post, topic: topic, user: author)
      Fabricate(:post, topic: topic, user: viewer, reply_to_post_number: other.post_number)
      expect(guard_for(viewer).can_view?(reply_block)).to be false
    end

    it "主楼兼容「直接回复主题」（reply_to_post_number 为空）" do
      first_post = topic.first_post
      Fabricate(:post, topic: topic, user: viewer) # 无 reply_to_post_number
      expect(described_class.new(viewer, first_post).can_view?(reply_block)).to be true
    end

    it "主楼兼容「回复主楼」（reply_to_post_number = 1）" do
      first_post = topic.first_post
      Fabricate(:post, topic: topic, user: viewer, reply_to_post_number: 1)
      expect(described_class.new(viewer, first_post).can_view?(reply_block)).to be true
    end
  end

  describe "[reply-visible=N] 计数模式" do
    before { SiteSetting.min_trust_level_to_bypass = 0 }

    it "启用计数语法：回复数达到 N 才解锁" do
      SiteSetting.reply_to_view_allow_count = true
      Fabricate(:post, topic: topic, user: viewer)
      Fabricate(:post, topic: topic, user: viewer)
      expect(guard_for(viewer).can_view?(count_block)).to be false

      Fabricate(:post, topic: topic, user: viewer)
      # 模拟请求边界:真实环境每次 HTTP 请求由 Rails Executor 重置请求级缓存,
      # 回复创建与视图序列化不会发生在同一请求周期内
      ReplyToView::Current.reset
      expect(guard_for(viewer).can_view?(count_block)).to be true
    end

    it "关闭计数语法：[reply-visible=N] 降级为普通 [reply-visible]（任意回复即解锁）" do
      SiteSetting.reply_to_view_allow_count = false
      Fabricate(:post, topic: topic, user: viewer)
      expect(guard_for(viewer).can_view?(count_block)).to be true
    end
  end

  describe ".author_below_use_threshold?" do
    it "作者 TL 低于 min_trust_level_to_use 时标记对该帖不生效" do
      SiteSetting.min_trust_level_to_use = 3
      expect(described_class.author_below_use_threshold?(target_post)).to be true
    end

    it "作者 TL 达标或设置关闭时不降级" do
      SiteSetting.min_trust_level_to_use = 1
      expect(described_class.author_below_use_threshold?(target_post)).to be false

      SiteSetting.min_trust_level_to_use = 0
      expect(described_class.author_below_use_threshold?(target_post)).to be false
    end
  end
end
