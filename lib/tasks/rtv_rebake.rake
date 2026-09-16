# frozen_string_literal: true

# discourse-reply-to-view —— 历史帖子重烘焙任务
#
# 用途：插件安装前已存在的含 [reply] / [login] 标记的帖子，
# 其 cooked 中是未解析的字面标记文本（或缺少占位容器）。
# 本任务对其重新走 cook 管线，生成占位容器并烘焙占位文案。
#
# 用法（宿主机）：
#   ./launcher enter app
#   rake rtv:rebake
#
# 一般无需手动执行：插件安装后新发布的帖子自动走正常烘焙链路。

task "rtv:rebake" => :environment do
  # 轻量正则预筛（命中 [reply] / [login] / [reply=N] 三种形态）
  posts =
    Post
      .unscoped
      .where("raw ILIKE '%[reply]%' OR raw ILIKE '%[login]%'")
      .order(:id)

  total = posts.count
  puts "发现 #{total} 个含 rtv 标记的帖子,开始重烘焙..."

  done = 0
  posts.find_each do |post|
    post.rebake!
    done += 1
    print "\r进度: #{done}/#{total}" if (done % 10).zero? || done == total
  end

  puts "\n重烘焙完成: #{done} 个帖子。"
end
