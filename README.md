# discourse-reply-to-view

回帖可见 / 登录可见内容保护插件。提供 `[reply]` / `[login]` / `[reply=N]` 三种 BBCode 标记,
隐藏内容的可见性判定 **100% 在服务端完成**,数据库 cooked 字段**零原文存储**,
并对搜索索引、邮件、摘要、raw 导出等全部内容出口做了泄露封堵。

> [English Documentation](README_EN.md)

## 相关链接

- 作者博客：<https://blog.zeruns.com/>
- 演示论坛网站：<https://bbs.eeclub.top/>
- 本项目由 AI 开发

## 环境要求

- 验证环境:Discourse **v2026.9.0-latest**（master 分支, 2026-09-16 构建）
- 最低兼容:依赖核心 markdown-it `md.block.bbcode.ruler` 体系与
  `assets/javascripts/**/discourse-markdown/**` 插件规则加载机制（约 2024 中以后的版本,即 3.4+）
  旧版本未验证,不建议使用
- 不修改任何 Discourse 核心源码,全部通过官方扩展 API 实现

---

## 更新日志

### v1.1.2（当前）

- **修复:非默认语言下隐藏内容直接可见**。站点开启内容本地化（content_localization）时,
  翻译产物可能丢失 [reply]/[login] 的占位容器结构,已翻译的隐藏内容会经
  `ContentLocalization.translated_post_cooked` 直接提供给非默认语言用户。
  现帖子含隐藏标记且当前用户不满足"全部块可见"时,本地化 cooked 变体一律拒绝
  （回退到受保护的默认 cooked）,特权与已解锁用户不受影响
- 后台 `enable_rtv` 设置描述顶部添加作者博客链接（全 49 种语言）
- 新增 6 个本地化泄露测试,合计 79 个用例全部通过

### v1.1.1

- 修复「回复后可见」按钮无法弹出编辑器（composer.open 的 draftKey 参数契约）
- 编辑器的两个插入按钮从工具栏移入「+」扩展菜单,修复插入示例文本显示为未翻译键名的问题

### v1.1.0

- `min_trust_level_to_bypass` 默认值改为 **0**（严格回帖可见；v1.0.0 默认 1 会导致 TL1+ 用户免回复直接可见）
- **多语言**：补齐 Discourse 支持的全部 49 种语言（前台文案 + 后台设置项描述与搜索关键词）
- **安全加固**：封堵修订历史 diff 泄露面（`/posts/:id/revisions/latest` 的 raw 词级差异对非特权用户替换为占位提示）
- 回复后自动刷新改为更新帖子模型（Ember 响应式重渲染,装饰器完整保留）
- 新增 `rake rtv:rebake` 任务:重烘焙插件安装前已存在的含标记历史帖子

### v1.0.0

- 首个版本:[reply] / [login] / [reply=N] 标记、服务端权限判定、cooked 零原文存储、raw 出口封堵、搜索脱敏

## 一、BBCode 语法

| 标记 | 语义 |
| --- | --- |
| `[reply]内容[/reply]` | 回帖可见:按站点模式判定解锁 |
| `[login]内容[/login]` | 登录可见:任何已登录用户（TL0~TL4）可见 |
| `[reply=N]内容[/reply]` | 计数模式:在本主题下发布至少 N 条有效回复后可见（需开启 `reply_to_view_allow_count`） |

- 标记内部可嵌套任意普通 Markdown（代码块、图片、链接、列表等）
- **支持两种形态**:块级（开/闭标记各独占一行,允许缩进）与单行完整对（`[reply]xxx[/reply]` 整行）
- **禁止两种标记互相嵌套**:异名嵌套时内层标记作为外层块的内容被整体处理,不单独生效
- 未闭合 / 非法形态（行内前后有其他文字、属性非正整数等）按普通文本原样输出,不报错

## 二、可见性判定规则

`[login]`:匿名访客看到占位框与「登录后可见」按钮（跳转 `/login?redirect_to=当前帖子`）;
信任等级豁免设置对本标记不生效。

`[reply]` 判定优先级（从高到低）:

1. 全站管理员、全站版主、对应分类的分类版主（需开启核心 `enable_category_group_moderation`）:始终可见
2. 帖子作者本人:始终可见（查看时内容带虚线边框 + 提示条）
3. `min_trust_level_to_bypass`:用户 TL ≥ 该值直接可见（0 = 不启用豁免）
4. 普通用户按 `reply_to_view_mode` 判定:
   - `any_reply`（默认）:在本主题发布过任意有效回复（未删除、未隐藏）即解锁全部 `[reply]` 内容
   - `exact_post`:必须直接回复 `[reply]` 内容所在楼层;主楼兼容「直接回复主题」与「回复主楼」
5. 计数模式（`reply_to_view_allow_count` 开启时）:本主题有效回复总数 ≥ N 时解锁 `[reply=N]`

## 三、安全架构（最高优先级设计）

```
raw（永久保存 BBCode 原文，仅作者/管理员/版主可取回）
        │
        ▼  cook 阶段（markdown-it bbcode 规则,无用户/帖子上下文）
cooked = <div class="rtv-block rtv-reply" data-rtv-type data-rtv-index
              data-rtv-count data-rtv-checksum></div>   ← 占位容器,零原文
        │
        ├─▶ 存储层占位文案:post_process_cooked 钩子烘焙默认语言提示
        │   （覆盖搜索索引 / 邮件 / 每日摘要 / Onebox / 列表摘要 / 导出 / RSS）
        │
        ▼  PostSerializer 序列化阶段（唯一原文注入点,带用户上下文）
   权限判定 → 注入渲染后的原文（unlocked/owner）或占位文案（locked）
```

- **对齐校验（防错位注入）**:cook 时在容器写入块内容的 FNV-1a 指纹
  （JS 与 Ruby 双端实现完全一致）,序列化注入前逐块校验类型 / 计数 / 指纹,
  **任何不一致整帖降级为占位符 —— 宁可整帖隐藏,绝不错位注入**
- **raw 出口封堵**:`/posts/:id/raw`、`/raw/:topic_id/:post_number`、
  修订历史、`/posts.json?id=latest`（`add_raw: true` 序列化）全部经净化器,
  非特权用户（含已解锁用户）拿到的 raw 中隐藏块替换为占位提示
- **缓存安全**:权限判定实时计算,仅做单请求记忆化（`ActiveSupport::CurrentAttributes`）,
  绝不落跨请求缓存 —— 回复后立即解锁,无低权限命中高权限缓存的窗口;
  唯一跨请求缓存是「块渲染产物」（键含 post 版本 + 内容指纹,与用户无关）;
  匿名请求输出统一占位版本,可安全进入 CDN / 匿名共享缓存
- **XSS 防护**:注入的原文一律通过 `Post#cook`（Discourse 官方 Markdown 管线 + 白名单）,
  占位文案为 i18n 文本节点,不存在绕过白名单拼 HTML 的路径
- **搜索脱敏**:官方 `:post_search_index_text` 修改器作为第二道防线
  （主防线是 cooked 零原文 + 存储层占位文案）

## 四、站点设置

安装后在 **管理后台 → 设置 → 插件** 中配置（`/admin/site_settings/category/plugins`）:

| 设置 | 类型 / 默认值 | 说明 |
| --- | --- | --- |
| `enable_rtv` | 布尔 / `true` | 总开关。关闭后历史标记内容在渲染视图明文回显（无框直出）,开关可逆 |
| `reply_to_view_mode` | 枚举 / `any_reply` | `any_reply` 任意回复解锁 / `exact_post` 精确楼层解锁 |
| `reply_to_view_allow_count` | 布尔 / `false` | 启用 `[reply=N]` 计数语法;关闭时自动降级为普通 `[reply]` |
| `min_trust_level_to_bypass` | 0~4 / `0` | TL 豁免线,0 = 不豁免（默认,严格「回帖可见」体验）。如希望 TL1+ 用户免回复可见,可按需调高 |
| `min_trust_level_to_use` | 0~4 / `1` | 使用权限:低于该等级的用户发布的标记不生效（内容对所有人直接可见）,编辑器按钮也对其隐藏 |

## 五、安装（官方 Docker 部署）

### 方式 A:git 仓库（推荐生产使用）

将插件推送到你的 git 仓库后,编辑 `app.yml`:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/your-org/discourse-reply-to-view.git
```

然后重建容器（前端资产需重新编译,必须 rebuild 而非 restart）:

```bash
cd /www/wwwroot/discourse
./launcher rebuild app
```

### 方式 B:本地目录（临时验证）

```bash
docker cp /path/to/discourse-reply-to-view app:/var/www/discourse/plugins/
./launcher rebuild app
```

注意:直接 `docker cp` 进容器的文件在 `rebuild` 后丢失,正式使用请走方式 A。

### 验证安装

1. 管理后台 → 插件:确认 `discourse-reply-to-view` 出现且启用
2. 发一个测试帖:

   ```
   [login]登录可见的内容[/login]

   [reply]回复可见的内容[/reply]
   ```

3. 匿名窗口打开:应看到绿色（登录）与蓝色（回复）两个占位框
4. 登录另一个账号:login 块可见、reply 块仍为占位;回复该主题后页面自动局部刷新解锁


## 多语言支持

插件内置 Discourse 支持的全部 49 种语言（与核心 locale 列表逐一对应）：
前台占位文案、按钮与提示条、后台插件设置描述与搜索关键词均已翻译。
序列化层按当前请求用户的 locale 渲染占位文案；邮件、搜索等直读 cooked 的通道
使用站点默认语言的烘焙文案。

## 历史帖子重烘焙

插件安装前已存在的含标记帖子,其 cooked 中是未解析的字面标记文本。
执行以下命令重烘焙（重新走 cook 管线,生成占位容器并烘焙占位文案）：

```bash
./launcher enter app
rake rtv:rebake
```

插件安装后新发布的帖子无需此操作（自动走正常烘焙链路）。

## 六、运行测试

```bash
# 容器内准备（一次性）
docker exec -u postgres app -- psql -c 'CREATE DATABASE discourse_test OWNER discourse;' \
  # 或:docker exec app su - postgres -c "psql -c \"CREATE DATABASE discourse_test OWNER discourse;\""
docker exec app bash -lc "cd /var/www/discourse && bundle config set --local without none && \
  bundle config set --local with test development && bundle install"
docker exec -u discourse app bash -lc "cd /var/www/discourse && \
  LOAD_PLUGINS=1 SKIP_MULTISITE=1 RAILS_ENV=test bin/rails db:migrate"

# 运行全部插件测试
docker exec -u discourse app bash -lc "cd /var/www/discourse && \
  SKIP_MULTISITE=1 RAILS_ENV=test bin/rspec plugins/discourse-reply-to-view/spec/"
```

测试结果:73 examples, 0 failures（连续多次随机顺序运行稳定）。

覆盖场景:
- 服务端 cook:占位容器生成 / 原文零泄露 / 计数属性 / 未闭合原样 / 嵌套语义 / 跨端指纹对齐（含中文与 Emoji）
- 权限矩阵:匿名、登录未回复、已回复（any_reply / exact_post / 计数）、作者、管理员、版主、
  分类版主（本分类 / 其他分类）、TL 豁免、使用权限降级、删除与隐藏回复不计入
- 出口封堵:话题 JSON、单帖 JSON、raw 三端点、latest 流（add_raw）、搜索索引（tsvector 与全文检索）、
  摘要通道、存储层烘焙、对齐校验失败的安全兜底

## 七、升级与版本兼容注意事项

- **Discourse 大版本升级后**:先在测试环境 rebuild 并运行上述测试套件;
  `markdown` / `markdown_for_topic` 等控制器扩展与核心实现保持同构,若核心调整了这些方法需同步
- **降级 / 卸载**:`enable_rtv` 关闭即明文回显历史内容,无数据丢失;
  彻底删除插件后,raw 中的 BBCode 标记按未注册标记原样显示（无害）
- **多语言**:占位文案在序列化层按请求用户 locale 渲染;
  邮件 / 搜索等直读 cooked 的通道使用站点默认语言（`default_locale`）的烘焙文案

## 八、已知边界与设计取舍

1. `min_trust_level_to_use` 降级（标记不生效）只在序列化视图生效;
   邮件 / 搜索等直读 cooked 的通道中该帖仍显示占位提示（方向保守,无泄露风险）
2. 编辑器预览仅作者本人可见内容与提示条,不影响服务端渲染
3. 分类版主豁免依赖核心 `enable_category_group_moderation` 开关
4. 前端「回复后自动解锁」为渐进增强:页面内锁定帖单帖局部刷新,
   失败时整页刷新自然生效,不影响正确性

## 九、目录结构

```
discourse-reply-to-view/
├── plugin.rb                       插件入口:设置注册、prepend 注册、事件钩子、搜索修改器
├── config/
│   ├── settings.yml                5 个站点设置项
│   └── locales/                    服务端/客户端 × 英文/简体中文 i18n
├── assets/
│   ├── javascripts/
│   │   ├── discourse-markdown/     markdown-it 规则（官方自动加载目录,两端共享）
│   │   │   ├── server-rtv-rule.js    服务端 cook 规则（丢弃内容,产出带指纹的占位容器）
│   │   │   └── client-rtv-rule.js    客户端预览规则（渲染内容 + 包裹预览容器）
│   │   └── discourse/
│   │       ├── initializers/
│   │       │   └── reply-to-view.js  「+」菜单插入项 / 占位框装饰 / 回复后局部刷新
│   │       └── components/
│   │           └── rtv-block.gjs     占位框交互组件（登录/回复按钮）
│   └── stylesheets/
│       └── common/
│           └── reply-to-view.scss    蓝（reply）/ 绿（login）主题与虚线提示条
├── lib/
│   └── reply_to_view/
│       ├── current.rb               请求级状态（ActiveSupport::CurrentAttributes）
│       ├── engine.rb                块提取引擎（与 JS bbcode 引擎逐语义对齐 + FNV-1a）
│       ├── guard.rb                 可见性判定引擎（100% 服务端）
│       ├── cooked_injector.rb       序列化期注入器（对齐校验 + 占位构建）
│       ├── raw_sanitizer.rb         raw 出口净化器
│       ├── placeholder_baker.rb     存储层占位文案烘焙 + 搜索脱敏
│       ├── cache.rb                 缓存与失效策略
│       └── extensions.rb            PostSerializer / PostsController prepend 扩展
└── spec/                            RSpec（components / lib / requests / services）
```
