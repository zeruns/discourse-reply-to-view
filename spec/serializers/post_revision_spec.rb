# frozen_string_literal: true

# 修订历史 diff 的泄露封堵测试
#
# 【安全背景】核心 PostRevisionSerializer 的 body_changes.side_by_side_markdown
# 输出 raw 的词级 diff,含 [reply-visible] / [login-visible] 标记内的隐藏原文。
# 本插件对非特权用户整体替换为占位提示;特权用户（作者/管理员/版主）不受影响。
RSpec.describe PostRevisionSerializer, type: :request do
  fab!(:author) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:topic) { Fabricate(:topic, user: author) }
  fab!(:viewer) { Fabricate(:user, trust_level: TrustLevel[0]) }

  fab!(:marked_post) do
    Fabricate(:post, topic: topic, user: author, raw: <<~MD)
      帖子正文

      [reply-visible]
      REVISION-SECRET-44
      [/reply-visible]
    MD
  end

  before do
    SiteSetting.enable_rtv = true
    SiteSetting.min_trust_level_to_bypass = 0
    SiteSetting.min_trust_level_to_use = 1
  end

  def revision_json(as_user)
    user = as_user
    sign_in(user) if user
    get "/posts/#{marked_post.id}/revisions/latest"
    expect(response.status).to eq(200)
    JSON.parse(response.body)
  end

  it "作者编辑后,非特权用户查看修订无隐藏原文泄露" do
    # 作者编辑（保留标记块,追加正文）产生修订
    PostRevisor.new(marked_post, topic).revise!(
      author,
      { raw: marked_post.raw + "\n\n追加的一段正文" },
      force_new_version: true,
    )

    body = revision_json(viewer)

    aggregate_failures do
      expect(body["body_changes"]).to be_present
      expect(JSON.generate(body["body_changes"])).not_to include("REVISION-SECRET-44")
      expect(JSON.generate(body)).not_to include("REVISION-SECRET-44")
    end
  end

  it "特权用户（管理员）查看修订可见完整 diff（编辑需要）" do
    PostRevisor.new(marked_post, topic).revise!(
      author,
      { raw: marked_post.raw + "\n\n追加的一段正文" },
      force_new_version: true,
    )

    body = revision_json(Fabricate(:admin))

    aggregate_failures do
      expect(body["body_changes"]).to be_present
      expect(JSON.generate(body["body_changes"])).to include("REVISION-SECRET-44")
    end
  end

  it "作者本人查看修订可见完整 diff" do
    PostRevisor.new(marked_post, topic).revise!(
      author,
      { raw: marked_post.raw + "\n\n追加的一段正文" },
      force_new_version: true,
    )

    body = revision_json(author)
    expect(JSON.generate(body["body_changes"])).to include("REVISION-SECRET-44")
  end
end
