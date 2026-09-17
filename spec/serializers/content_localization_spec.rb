# frozen_string_literal: true

# 内容本地化变体的权限处理测试
#
# 【背景】核心内容本地化把 post_localizations 中的翻译 cooked 提供给
# 非默认语言用户（多个序列化出口共用 ContentLocalization.translated_post_cooked）。
# AI 翻译保留 [reply-visible]/[login-visible] 标记时,本地化 cooked 带有完整的占位容器结构
# （标记内容在 cook 阶段被规则丢弃）,可直接放行,由注入器按用户权限逐块处理;
# 若翻译产物丢失容器结构（翻译后的隐藏内容明文暴露）,则仅对满足
# "全部块可见"的用户放行,其他用户回退到受保护的默认 cooked。
#
# 测试 stub 固定核心的放行决策(show_translated_post?),聚焦本插件逻辑。
RSpec.describe ContentLocalization, type: :request do
  fab!(:author) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:topic) { Fabricate(:topic, user: author) }
  fab!(:marked_post) do
    Fabricate(:post, topic: topic, user: author, raw: <<~MD)
      帖子正文

      [reply-visible]
      中文隐藏内容
      [/reply-visible]
    MD
  end
  fab!(:viewer) { Fabricate(:user, trust_level: TrustLevel[0]) }
  fab!(:localizer) { Fabricate(:admin) }

  let(:en_raw) { "Post body\n\n[reply-visible]\nEN-TRANSLATED-SECRET\n[/reply-visible]\n" }
  # 结构完好:cook 后容器保留,翻译内容被规则丢弃
  let(:well_formed_cooked) { PrettyText.cook(en_raw) }

  before do
    SiteSetting.enable_rtv = true
    SiteSetting.min_trust_level_to_bypass = 0
    SiteSetting.min_trust_level_to_use = 1
    SiteSetting.content_localization_enabled = true

    PostLocalization.create!(
      post: marked_post,
      locale: "en",
      raw: en_raw,
      cooked: well_formed_cooked,
      post_version: marked_post.version,
      localizer_user_id: localizer.id,
    )
    marked_post.update_columns(locale: "zh_CN")

    allow(ContentLocalization).to receive(:show_translated_post?).and_return(true)
  end

  describe "结构完好的本地化变体（容器保留）" do
    it "对任何用户都放行（注入器负责按权限处理）" do
      expect(
        described_class.translated_post_cooked(marked_post.reload, Guardian.new(viewer))
      ).to eq(well_formed_cooked)

      expect(
        described_class.translated_post_cooked(marked_post.reload, Guardian.new(nil))
      ).to eq(well_formed_cooked)
    end

    it "未回复用户:序列化输出为锁定占位框（本语言文案）,无隐藏内容泄露" do
      html = PostSerializer.new(marked_post.reload, scope: Guardian.new(viewer), root: false).cooked

      aggregate_failures do
        expect(html).to include("rtv-block")
        expect(html).to include(%(data-rtv-state="locked"))
        expect(html).not_to include("EN-TRANSLATED-SECRET")
        expect(html).not_to include("中文隐藏内容")
      end
    end

    it "回复后的用户:序列化输出为解锁的英文翻译内容" do
      Fabricate(:post, topic: topic, user: viewer)
      ReplyToView::Current.reset

      html = PostSerializer.new(marked_post.reload, scope: Guardian.new(viewer), root: false).cooked

      aggregate_failures do
        expect(html).to include(%(data-rtv-state="unlocked"))
        expect(html).to include("EN-TRANSLATED-SECRET")
      end
    end

    it "管理员:可见英文翻译内容" do
      html = PostSerializer.new(marked_post.reload, scope: Guardian.new(Fabricate(:admin)), root: false).cooked
      expect(html).to include("EN-TRANSLATED-SECRET")
    end
  end

  describe "结构破损的本地化变体（容器丢失,翻译内容明文暴露）" do
    before do
      marked_post.localizations.find_by(locale: "en").update!(
        raw: "Post body\n\nEN-BROKEN-SECRET 直接暴露",
        cooked: "<p>Post body</p><p>EN-BROKEN-SECRET 直接暴露</p>",
      )
    end

    it "未回复用户被拒绝（回退到受保护的默认 cooked）" do
      expect(
        described_class.translated_post_cooked(marked_post.reload, Guardian.new(viewer))
      ).to be_nil
    end

    it "匿名用户被拒绝" do
      expect(
        described_class.translated_post_cooked(marked_post.reload, Guardian.new(nil))
      ).to be_nil
    end

    it "特权用户（管理员）仍可获取" do
      expect(
        described_class.translated_post_cooked(marked_post.reload, Guardian.new(Fabricate(:admin)))
      ).to include("EN-BROKEN-SECRET")
    end
  end

  describe "不含隐藏标记的帖子" do
    it "本地化正常放行,不受插件影响" do
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
  end
end
