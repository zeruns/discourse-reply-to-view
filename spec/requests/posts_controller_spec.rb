# frozen_string_literal: true

# 端到端泄露封堵测试：覆盖所有返回帖子内容的接口视角。
#
# 【安全不变量】未满足条件的用户，从任何接口（话题 JSON / 帖子 JSON /
# raw 端点 / latest 流）得到的 HTML 或纯文本中均不得包含隐藏原文。
RSpec.describe "reply-to-view content protection", type: :request do
  fab!(:author) { Fabricate(:user, trust_level: TrustLevel[3]) }
  fab!(:topic) { Fabricate(:topic, user: author) }
  fab!(:marked_post) do
    Fabricate(:post, topic: topic, user: author, raw: <<~MD)
      帖子正文开头

      [login-visible]
      LOGIN-SECRET-99
      [/login-visible]

      [reply-visible]
      REPLY-SECRET-88
      [/reply-visible]

      [reply-visible=2]
      COUNT-SECRET-77
      [/reply-visible]
    MD
  end
  fab!(:viewer) { Fabricate(:user, trust_level: TrustLevel[0]) }

  def topic_json_posts(response)
    JSON.parse(response.body)["post_stream"]["posts"]
  end

  def cooked_of(posts_json, post)
    posts_json.find { |p| p["id"] == post.id }["cooked"]
  end

  # 取得指定帖子在话题视图中的 cooked
  def fetch_cooked(post, as: nil)
    sign_in(as) if as
    get "/t/#{topic.slug}/#{topic.id}.json"
    expect(response.status).to eq(200)
    cooked_of(topic_json_posts(response), post)
  end

  # 每个用例前将插件相关设置复位到统一基线:
  # 测试进程内 SiteSetting 修改可能跨用例残留（如豁免等级被其他用例调高后,
  # 会令本用例的普通用户意外命中豁免）,显式复位保证用例独立
  before do
    SiteSetting.enable_rtv = true
    SiteSetting.reply_to_view_mode = "any_reply"
    SiteSetting.reply_to_view_allow_count = false
    SiteSetting.min_trust_level_to_bypass = 0
    SiteSetting.min_trust_level_to_use = 1
    ReplyToView::Current.reset
  end

  describe "匿名用户" do
    it "两种标记均返回占位符，话题接口无原文泄露" do
      cooked = fetch_cooked(marked_post)

      aggregate_failures do
        expect(cooked).to include("rtv-block")
        expect(cooked).to include(%(data-rtv-state="locked"))
        expect(cooked).to include("rtv-placeholder")
        expect(cooked).not_to include("LOGIN-SECRET-99")
        expect(cooked).not_to include("REPLY-SECRET-88")
        expect(cooked).not_to include("COUNT-SECRET-77")
      end
    end

    it "单帖接口（/posts/:id.json）同样无泄露" do
      get "/posts/#{marked_post.id}.json"
      expect(response.status).to eq(200)
      cooked = JSON.parse(response.body)["cooked"]
      expect(cooked).not_to include("LOGIN-SECRET-99")
      expect(cooked).not_to include("REPLY-SECRET-88")
    end

    it "raw 端点输出脱敏文本" do
      get "/posts/#{marked_post.id}/raw"
      expect(response.status).to eq(200)
      expect(response.body).not_to include("LOGIN-SECRET-99")
      expect(response.body).not_to include("REPLY-SECRET-88")
      expect(response.body).to include(I18n.t("reply_to_view.sanitized_placeholder"))
    end

    it "cooked 端点输出锁定占位框且无原文泄露" do
      get "/posts/#{marked_post.id}/cooked.json"
      expect(response.status).to eq(200)
      cooked = JSON.parse(response.body)["cooked"]

      aggregate_failures do
        expect(cooked).to include(%(data-rtv-state="locked"))
        expect(cooked).not_to include("LOGIN-SECRET-99")
        expect(cooked).not_to include("REPLY-SECRET-88")
      end
    end

    it "按楼号 raw 端点输出脱敏文本" do
      get "/raw/#{topic.id}/#{marked_post.post_number}"
      expect(response.status).to eq(200)
      expect(response.body).not_to include("REPLY-SECRET-88")
    end

    it "整主题 raw 导出无泄露" do
      get "/raw/#{topic.id}"
      expect(response.status).to eq(200)
      expect(response.body).not_to include("LOGIN-SECRET-99")
      expect(response.body).not_to include("REPLY-SECRET-88")
    end
  end

  describe "登录未回复用户（TL0，无豁免）" do
    before { SiteSetting.min_trust_level_to_bypass = 0 }

    it "[login-visible] 内容可见、[reply-visible] 与 [reply-visible=N] 返回占位符" do
      cooked = fetch_cooked(marked_post, as: viewer)

      aggregate_failures do
        expect(cooked).to include("LOGIN-SECRET-99")
        expect(cooked).not_to include("REPLY-SECRET-88")
        expect(cooked).not_to include("COUNT-SECRET-77")

        doc = Nokogiri::HTML5.fragment(cooked)
        expect(doc.at_css(".rtv-login")["data-rtv-state"]).to eq("unlocked")
        expect(doc.at_css(".rtv-reply")["data-rtv-state"]).to eq("locked")
      end
    end

    it "已解锁用户请求 raw 端点仍为脱敏文本（解锁仅对渲染视图生效）" do
      sign_in(viewer)
      get "/posts/#{marked_post.id}/raw"
      expect(response.body).not_to include("LOGIN-SECRET-99")
    end
  end

  describe "已回复用户" do
    before { SiteSetting.min_trust_level_to_bypass = 0 }

    it "any_reply 模式：任意有效回复解锁全部 [reply-visible]（计数块未达标仍锁定）" do
      SiteSetting.reply_to_view_allow_count = true
      Fabricate(:post, topic: topic, user: viewer)
      cooked = fetch_cooked(marked_post, as: viewer)

      aggregate_failures do
        expect(cooked).to include("REPLY-SECRET-88")
        expect(cooked).not_to include("COUNT-SECRET-77") # [reply-visible=2] 需要两条回复
      end
    end

    it "计数模式：回复数达到 N 后计数块解锁" do
      SiteSetting.min_trust_level_to_bypass = 0
      SiteSetting.reply_to_view_allow_count = true
      Fabricate(:post, topic: topic, user: viewer)
      Fabricate(:post, topic: topic, user: viewer)
      cooked = fetch_cooked(marked_post, as: viewer)

      expect(cooked).to include("COUNT-SECRET-77")
    end

    it "exact_post 模式：必须直接回复该楼" do
      SiteSetting.min_trust_level_to_bypass = 0
      SiteSetting.reply_to_view_mode = "exact_post"

      # 回复其他楼层（作者跟帖）
      other = Fabricate(:post, topic: topic, user: author)
      Fabricate(:post, topic: topic, user: viewer, reply_to_post_number: other.post_number)
      cooked = fetch_cooked(marked_post, as: viewer)
      expect(cooked).not_to include("REPLY-SECRET-88")

      # 直接回复目标楼
      Fabricate(:post, topic: topic, user: viewer, reply_to_post_number: marked_post.post_number)
      cooked = fetch_cooked(marked_post, as: viewer)
      expect(cooked).to include("REPLY-SECRET-88")
    end
  end

  describe "特权用户" do
    it "管理员可见全部内容" do
      cooked = fetch_cooked(marked_post, as: Fabricate(:admin))
      expect(cooked).to include("LOGIN-SECRET-99")
      expect(cooked).to include("REPLY-SECRET-88")
      expect(cooked).to include("COUNT-SECRET-77")
    end

    it "版主可见全部内容" do
      cooked = fetch_cooked(marked_post, as: Fabricate(:moderator))
      expect(cooked).to include("REPLY-SECRET-88")
    end

    it "作者本人可见全部内容，且标记为 owner 状态（前端渲染虚线提示条）" do
      cooked = fetch_cooked(marked_post, as: author)
      expect(cooked).to include("REPLY-SECRET-88")
      expect(cooked).to include(%(data-rtv-state="owner"))
    end

    it "管理员可从 raw 端点取回带标记原文（编辑需要）" do
      admin = Fabricate(:admin)
      sign_in(admin)
      get "/posts/#{marked_post.id}/raw"
      expect(response.body).to include("[reply-visible]")
      expect(response.body).to include("REPLY-SECRET-88")
    end

    it "作者可从 raw 端点取回带标记原文" do
      sign_in(author)
      get "/posts/#{marked_post.id}/raw"
      expect(response.body).to include("REPLY-SECRET-88")
    end
  end

  describe "信任等级豁免" do
    it "TL 达到 min_trust_level_to_bypass 时无需回复即可见 [reply-visible]" do
      SiteSetting.min_trust_level_to_bypass = 3
      tl3 = Fabricate(:user, trust_level: TrustLevel[3])
      cooked = fetch_cooked(marked_post, as: tl3)
      expect(cooked).to include("REPLY-SECRET-88")
    end
  end

  describe "使用权限（min_trust_level_to_use）" do
    it "低信任等级作者发布的标记不生效：内容对所有人直出" do
      SiteSetting.min_trust_level_to_bypass = 0
      SiteSetting.min_trust_level_to_use = 2
      low_tl_author = Fabricate(:user, trust_level: TrustLevel[0])
      low_post = Fabricate(:post, topic: topic, user: low_tl_author, raw: <<~MD)
        [reply-visible]
        INERT-SECRET-66
        [/reply-visible]
      MD

      cooked = fetch_cooked(low_post, as: viewer)
      expect(cooked).to include("INERT-SECRET-66")
      expect(cooked).not_to include(%(data-rtv-state="locked"))
    end
  end

  describe "latest 流接口（add_raw: true 序列化路径）" do
    it "普通用户拿到的 raw 不含隐藏原文" do
      sign_in(viewer)
      get "/posts.json?id=latest"
      expect(response.status).to eq(200)

      body = response.body
      # viewer 已登录:[login-visible] 内容对其可见属预期(登录可见语义);
      # [reply-visible] 原文与 raw 中的隐藏块均不得出现
      expect(body).not_to include("REPLY-SECRET-88")
      expect(body).not_to include("COUNT-SECRET-77")
      expect(body).to include("[hidden content]")
    end
  end

  describe "BasicPostSerializer 路径（个人资料页等出口）" do
    it "锁定用户经 BasicPostSerializer 拿到的 cooked 同样是占位符" do
      cooked = BasicPostSerializer.new(
        marked_post.reload,
        scope: Guardian.new(viewer),
        root: false,
      ).cooked

      aggregate_failures do
        expect(cooked).to include(%(data-rtv-state="locked"))
        expect(cooked).not_to include("REPLY-SECRET-88")
      end
    end
  end

  describe "数据库 cooked 与邮件 / 摘要通道" do
    it "存储的 cooked 不含隐藏原文（邮件 / Onebox / 话题摘要共用该数据源）" do
      cooked = marked_post.reload.cooked
      expect(cooked).not_to include("LOGIN-SECRET-99")
      expect(cooked).not_to include("REPLY-SECRET-88")
      expect(cooked).not_to include("COUNT-SECRET-77")
    end

    it "CookedPostProcessor 烘焙后 cooked 带占位提示文案（邮件可见友好提示）" do
      post = Fabricate(:post, topic: topic, user: author, raw: "[reply-visible]\nBAKE-SECRET-55\n[/reply-visible]\n")
      # 与核心 ProcessPost job 一致:post_process 修改文档,job 将结果写回 DB
      cp = CookedPostProcessor.new(post, {})
      cp.post_process

      cooked = cp.html
      expect(cooked).to include("rtv-placeholder")
      expect(cooked).not_to include("BAKE-SECRET-55")
      # 占位文案内容来自 locale 文件（非硬编码）
      expect(cooked).to include(I18n.t("reply_to_view.reply.placeholder"))
    end
  end

  describe "对齐校验失败时的安全兜底" do
    it "cooked 与 raw 解析不一致时整帖降级为占位符（绝不错位注入）" do
      # 模拟：cook 之后 raw 被外部工具修改（块内容改变导致指纹不一致）
      marked_post.update_column(:raw, marked_post.raw.sub("REPLY-SECRET-88", "TAMPERED-CONTENT"))

      admin = Fabricate(:admin)
      sign_in(admin)
      get "/t/#{topic.slug}/#{topic.id}.json"
      cooked = cooked_of(topic_json_posts(response), marked_post)

      aggregate_failures do
        expect(cooked).to include(%(data-rtv-state="locked"))
        expect(cooked).not_to include("REPLY-SECRET-88")
        expect(cooked).not_to include("TAMPERED-CONTENT")
      end
    end
  end
end
