# frozen_string_literal: true

# name: discourse-reply-to-view
# version: 1.0.0
# authors: Discourse Plugins Engineering
# url: https://github.com/your-org/discourse-reply-to-view
# about: 回帖可见 / 登录可见内容保护插件（[reply] 与 [login] BBCode 标记，
#   服务端权限判定 + cooked 零原文存储，全场景防泄露）

# —— 插件整体启用开关（对应站点设置 enable_rtv）——
enabled_site_setting :enable_rtv

register_asset "stylesheets/common/reply-to-view.scss"

# ============ 后端核心库加载 ============
# 【加载说明】plugin.rb 由 Plugin::Instance#activate! 以 instance_eval 执行,
# 其中直接定义的常量会嵌套在插件单例作用域下;
# 因此全部功能模块（含核心类的 prepend 扩展）统一在 lib 中以顶层命名空间定义,
# 此处仅负责加载与注册。
require_relative "lib/reply_to_view/engine"
require_relative "lib/reply_to_view/current"
require_relative "lib/reply_to_view/guard"
require_relative "lib/reply_to_view/cooked_injector"
require_relative "lib/reply_to_view/raw_sanitizer"
require_relative "lib/reply_to_view/placeholder_baker"
require_relative "lib/reply_to_view/cache"
require_relative "lib/reply_to_view/extensions"

# markdown-it 规则（服务端 cook 与客户端预览）无需手动注册：
# assets/javascripts/**/discourse-markdown/** 目录为官方约定的自动加载机制
# （见核心 lib/pretty_text.rb 中插件规则 glob），前端构建管线亦自动纳入。

# ============ 核心类 prepend 注册 ============
# PostSerializer（内容注入点）与 PostsController（raw 出口封堵）。
# 挂载在 Rails to_prepare 阶段执行:插件 activate! 发生在 Rails 启动早期
# （Zeitwerk 自动加载尚未就绪）,to_prepare 在应用初始化完成后执行 ——
# 此时核心类可安全引用,且开发环境代码重载后自动重新应用补丁。
Rails.application.config.to_prepare do
  ::PostSerializer.prepend(::ReplyToView::PostSerializerExtension)
  ::PostsController.prepend(::ReplyToView::PostsControllerExtension)
end

# ============ 搜索索引脱敏（官方 :post_search_index_text 修改器） ============
# 核心以 cooked 为索引数据源（HtmlScrubber 提取纯文本）,
# 而 cooked 不含隐藏原文 —— 本修改器作为第二道防线:
# 帖子含 rtv 容器时,确保索引文本中出现统一的受保护内容提示,
# 覆盖占位文案烘焙（post_process_cooked）缺失的防御场景。
register_modifier(:post_search_index_text) do |text, _post_id, cooked, _locale|
  next text unless cooked.to_s.include?("rtv-block")

  placeholder = I18n.t("reply_to_view.search_placeholder")
  text.include?(placeholder) ? text : "#{text} #{placeholder}"
end

# ============ 事件钩子 ============

# 帖子保存后处理阶段:向数据库 cooked 写入默认语言的占位提示文案,
# 覆盖搜索索引 / 邮件 / 摘要 / Onebox / RSS 等直读 cooked 的场景
# （事件块在插件上下文中执行,常量以顶层作用域引用）
on(:post_process_cooked) do |doc, post|
  ::ReplyToView::PlaceholderBaker.bake!(doc, post)
end

# 新回复发布:清理作者信任等级缓存等（权限判定本身实时计算,无缓存可失效）
on(:post_created) { |post| ::ReplyToView::CacheInvalidator.on_post_created(post) }
on(:post_updated) { |post| ::ReplyToView::CacheInvalidator.on_post_updated(post) }
