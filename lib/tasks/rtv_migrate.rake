# frozen_string_literal: true

# discourse-reply-to-view —— 旧标签一次性迁移任务
#
# 背景：v2.0.0 起插件仅识别 [reply-visible] / [login-visible] / [reply-visible=N]。
# v1.x 时代发布的帖子使用旧标签 [reply] / [login] / [reply=N],
# 若不迁移,这些帖子升级后隐藏内容会以明文渲染（构成泄露）。
#
# 本任务将所有旧标记批量替换为新标记,同步处理帖子的本地化翻译版本,
# 并重新走 cook 管线生成占位容器。
#
# 用法（宿主机）：
#   ./launcher enter app
#   rake rtv:migrate_legacy_tags
#
# 幂等：已是新标签的帖子会被跳过,可安全重复执行。

def rtv_migrate_raw(raw)
  raw
    .gsub(/\[reply=([0-9]+\])/, "[reply-visible=\\1")
    .gsub("[/reply]", "[/reply-visible]")
    .gsub("[reply]", "[reply-visible]")
    .gsub("[/login]", "[/login-visible]")
    .gsub("[login]", "[login-visible]")
end

task "rtv:migrate_legacy_tags" => :environment do
  posts =
    Post
      .unscoped
      .where("raw ILIKE '%[reply]%' OR raw ILIKE '%[reply=%' OR raw ILIKE '%[/reply]%' OR " \
             "raw ILIKE '%[login]%' OR raw ILIKE '%[/login]%'")
      .order(:id)

  total = posts.count
  puts "发现 #{total} 个含旧标签的帖子,开始迁移..."
  done = 0

  posts.find_each do |post|
    new_raw = rtv_migrate_raw(post.raw)

    # 本地化翻译版本同步迁移（AI 翻译保留了标记结构,需一并替换）
    post.localizations.find_each do |loc|
      loc_new_raw = rtv_migrate_raw(loc.raw)
      next if loc_new_raw == loc.raw

      loc.raw = loc_new_raw
      loc.cooked = post.post_analyzer.cook(loc_new_raw, post.cooking_options || {})
      loc.post_version = post.version
      loc.save!
      begin
        processor = LocalizedCookedPostProcessor.new(loc, post, {})
        processor.post_process
        loc.update!(cooked: processor.html)
      rescue StandardError => e
        Rails.logger.warn("rtv migrate: localization post-process failed (#{loc.id}): #{e.message}")
      end
    end

    next if new_raw == post.raw

    post.update_columns(raw: new_raw)
    post.rebake!
    done += 1
    print "\r进度: #{done}/#{total}" if (done % 10).zero? || done == total
  end

  puts "\n迁移完成: #{done} 个帖子已转换为新标签。"
end
