# frozen_string_literal: true

# 内容本地化变体的泄露封堵测试
#
# 【安全背景】核心内容本地化会把 post_localizations 中的翻译 cooked 提供给
# 非默认语言用户（话题页 cooked、帖子列表摘要、excerpt 等出口共用
# ContentLocalization.translated_post_cooked）。翻译产物可能丢失 [reply]/[login]
# 的占位容器结构,导致已翻译的隐藏内容对未满足条件的用户直接可见。
# 修法:帖子含隐藏标记且当前用户不满足"全部块可见"时返回 nil,
# 核心出口自动回退到受保护的默认 cooked / 摘要。
#
# 测试通过 stub 固定核心的翻译放行决策(show_translated_post?),
# 使断言聚焦在本插件的拦截逻辑上,不受 user_option 等环境状态影响。
RSpec.describe ContentLocalization, type: :request do
  fab!(:author) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:topic) { Fabricate(:topic, user: author) }
  fab!(:marked_post) do
    Fabricate(:post, topic: topic, user: author, raw: <<~MD)
      帖子正文

      [reply]
      LOCALIZATION-SECRET-33
      [/reply]
    MD
  end
  fab!(:viewer) { Fabricate(:user, trust_level: TrustLevel[0]) }
  fab!(:localizer) { Fabricate(:admin) }

  let(:localized_cooked) { "<p>TRANSLATED-SECRET-33 的翻译内容</p>" }

  before do
    SiteSetting.enable_rtv = true
    SiteSetting.min_trust_level_to_bypass = 0
    SiteSetting.min_trust_level_to_use = 1
    SiteSetting.content_localization_enabled = true

    # 模拟一条英文翻译:翻译产物丢失了 rtv 容器,直接含已翻译的隐藏内容
    PostLocalization.create!(
      post: marked_post,
      locale: "en",
      raw: "Post body\n\nTRANSLATED-SECRET-33 translation",
      cooked: localized_cooked,
      post_version: marked_post.version,
      localizer_user_id: localizer.id,
    )
    marked_post.update_columns(locale: "zh_CN")

    # 固定核心的翻译放行决策为"放行",让拦截行为完全由本插件的决定
    allow(ContentLocalization).to receive(:show_translated_post?).and_return(true)
  end

  it "未回复用户无法获取本地化 cooked 变体（回退到受保护的默认 cooked）" do
    expect(
      described_class.translated_post_cooked(marked_post.reload, Guardian.new(viewer))
    ).to be_nil
  end

  it "匿名用户无法获取本地化 cooked 变体" do
    expect(
      described_class.translated_post_cooked(marked_post.reload, Guardian.new(nil))
    ).to be_nil
  end

  it "回复后的用户可获取本地化 cooked 变体（已解锁,翻译内容可看）" do
    Fabricate(:post, topic: topic, user: viewer)
    ReplyToView::Current.reset

    expect(
      described_class.translated_post_cooked(marked_post.reload, Guardian.new(viewer))
    ).to eq(localized_cooked)
  end

  it "特权用户（管理员）可获取本地化 cooked 变体" do
    expect(
      described_class.translated_post_cooked(marked_post.reload, Guardian.new(Fabricate(:admin)))
    ).to eq(localized_cooked)
  end

  it "不含隐藏标记的帖子不受影响（本地化正常放行）" do
    plain_post = Fabricate(:post, topic: topic, user: author, raw: "普通内容 PLAIN-TEXT")
    PostLocalization.create!(
      post: plain_post,
      locale: "en",
      raw: "plain EN",
      cooked: "<p>plain EN cooked</p>",
      post_version: plain_post.version,
      localizer_user_id: localizer.id,
    )
    plain_post.update_columns(locale: "zh_CN")

    expect(
      described_class.translated_post_cooked(plain_post.reload, Guardian.new(viewer))
    ).to eq("<p>plain EN cooked</p>")
  end

  it "端到端:未回复用户序列化 cooked 含受保护容器且无翻译内容泄露" do
    # 直接走序列化器,验证回退路径:本地化变体被拒后,默认 cooked 被注入锁定态
    html = PostSerializer.new(marked_post.reload, scope: Guardian.new(viewer), root: false).cooked

    aggregate_failures do
      expect(html).to include("rtv-block")
      expect(html).to include(%(data-rtv-state="locked"))
      expect(html).not_to include("LOCALIZATION-SECRET-33")
      expect(html).not_to include("TRANSLATED-SECRET-33")
    end
  end
end
