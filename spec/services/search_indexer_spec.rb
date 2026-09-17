# frozen_string_literal: true

# 搜索索引与摘要通道的泄露封堵测试
RSpec.describe SearchIndexer do
  fab!(:author) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:topic) { Fabricate(:topic, user: author) }
  fab!(:marked_post) do
    Fabricate(:post, topic: topic, user: author, raw: <<~MD)
      公开的话题标题文字 SEARCHABLE-PLAIN

      [reply-visible]
      SEARCH-SECRET-REPLY
      [/reply-visible]

      [login-visible]
      SEARCH-SECRET-LOGIN
      [/login-visible]
    MD
  end

  before do
    SiteSetting.enable_rtv = true
    # 测试环境默认禁用搜索索引器（spec/support/test_setup）,本组用例需要真实索引
    SearchIndexer.enable
  end

  after { SearchIndexer.disable }

  it "搜索索引数据不包含隐藏原文" do
    SearchIndexer.index(marked_post, force: true)

    # 新版搜索索引直接写入 post_search_data 表（无独立 model）
    indexed_text =
      DB.query_single(
        "SELECT search_data::text FROM post_search_data WHERE post_id = ?",
        marked_post.id,
      ).first.to_s

    aggregate_failures do
      expect(indexed_text).to be_present
      expect(indexed_text).to include("searchable")
      # tsvector 为分词形式,隐藏原文若泄露必然出现 secret 词根
      expect(indexed_text).not_to include("secret")
    end
  end

  it "隐藏原文无法通过全文检索命中" do
    SearchIndexer.index(marked_post, force: true)

    aggregate_failures do
      # 隐藏原文作为关键词检索时不应命中该帖
      secret_hit = Search.execute("secret", guardian: Guardian.new)
      expect(secret_hit.posts.map(&:id)).not_to include(marked_post.id)

      # 公开内容关键词正常命中（证明索引本身工作正常）
      plain_hit = Search.execute("searchable", guardian: Guardian.new)
      expect(plain_hit.posts.map(&:id)).to include(marked_post.id)
    end
  end

  it "话题摘要通道（excerpt，Onebox / 列表摘要共用同一 cooked 数据源）不包含隐藏原文" do
    # 摘要 / Onebox 均从 cooked 提取纯文本，cooked 不含原文即通道安全；
    # 此处以核心的摘要提取函数直接验证
    excerpt = PrettyText.excerpt(marked_post.reload.cooked, 300, keep_emoji_images: true)

    expect(excerpt).not_to include("SEARCH-SECRET-REPLY")
    expect(excerpt).not_to include("SEARCH-SECRET-LOGIN")
  end

  it "SearchScrubber 将容器替换为中性占位文本（防御性加固）" do
    html = '<p>text</p><div class="rtv-block rtv-reply" data-rtv-type="reply">anything</div>'
    scrubbed = ReplyToView::SearchScrubber.scrub(html)

    expect(scrubbed).not_to include("rtv-block")
    expect(scrubbed).to include(I18n.t("reply_to_view.search_placeholder"))
  end
end
