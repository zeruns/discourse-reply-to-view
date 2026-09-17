/**
 * discourse-reply-to-view —— 服务端 cook 规则
 *
 * 【安全架构 - 最高优先级】
 * 本规则运行在服务端 markdown-it（mini_racer）上下文中，职责是：
 * 在 cook（Markdown → HTML）阶段解析 [reply] / [login] / [reply=N] 标记，
 * 输出纯结构的占位容器，并【完全丢弃标记内部的隐藏原文】。
 *
 * 因此数据库中的 cooked 字段永远不包含隐藏原文，所有直读 cooked 的下游场景
 * （搜索索引、通知邮件、每日摘要、Onebox、话题列表摘要、话题导出、RSS）
 * 天然不泄露原文；原文仅在 PostSerializer 序列化阶段按用户权限动态注入。
 *
 * 与核心引擎的契约（配对语义与 lib/reply_to_view/engine.rb 保持一致）：
 *   - 块级形态：开标记独占一行，同名嵌套按计数配对（最后一个闭合生效）；
 *   - 单行形态：整行恰好为一个完整开闭对；
 *   - 未闭合 / 非法形态：核心引擎不触发本规则，标记按普通文本原样输出；
 *   - 异名标记嵌套：内层标记作为外层块的内容被一并丢弃，不单独生效。
 *
 * 容器上的 data 属性是序列化期注入的安全前提：
 *   - data-rtv-index：块在帖内的 1 基序号（Ruby 端按同序提取）
 *   - data-rtv-type：reply / login
 *   - data-rtv-count：[reply=N] 的 N（仅有效正整数时输出）
 *   - data-rtv-checksum：块内容的 FNV-1a 指纹（与 Ruby 端算法一致），
 *     序列化期逐块校验，任何不一致整帖降级为占位符 —— 宁可整帖隐藏，绝不错位注入
 */

// 服务端 mini_racer 上下文标志（核心 pretty_text.rb 中设置），
// 用于确保服务端规则与客户端预览规则（client-rtv-rule.js）互斥注册
const IS_SERVER = typeof __PRETTY_TEXT !== "undefined" && __PRETTY_TEXT === true;

/**
 * FNV-1a 32 位指纹，按 Unicode 码点迭代。
 * 必须与 lib/reply_to_view/engine.rb 的 Checksum.fnv1a 输出完全一致 —— 用于跨端对齐校验。
 */
function fnv1a32(str) {
  let hash = 0x811c9dc5;
  for (const ch of str) {
    hash ^= ch.codePointAt(0);
    // Math.imul 完成 32 位截断乘法，>>> 0 归一为无符号数
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash >>> 0;
}

/**
 * 解析标记属性中的计数值：仅正整数字符串有效，其他情况返回空（按普通 [reply] 处理）。
 * 判定逻辑与 Ruby 端 Engine.parse_count 一致。
 */
function parseCount(tagInfo) {
  const raw = tagInfo && tagInfo.attrs && tagInfo.attrs["_default"];
  if (raw && /^\d+$/.test(raw) && parseInt(raw, 10) > 0) {
    return parseInt(raw, 10);
  }
  return null;
}

/** 取得全局递增的块序号（state.env 生命周期为单次解析，天然隔离） */
function nextIndex(state) {
  state.env.rtvIndex = (state.env.rtvIndex || 0) + 1;
  return state.env.rtvIndex;
}

/** 构造单个标记的 bbcode 规则（rule.replace 形态：整体替换、丢弃内容） */
function makeReplaceRule(tag, type) {
  return {
    tag,
    replace(state, tagInfo, content) {
      const index = nextIndex(state);
      const count = parseCount(tagInfo);
      const checksum = fnv1a32(content).toString(16);

      // 注意：token.content 中只允许出现结构属性与指纹，
      // 任何情况下都不得拼接 content（隐藏原文）本身。
      // type 为归一化类型（reply/login），新标签 reply-visible/login-visible
      // 与旧标签 reply/login 共用同一容器结构与 CSS 主题
      const attrs = [
        `class="rtv-block rtv-${type}"`,
        `data-rtv-type="${type}"`,
        `data-rtv-index="${index}"`,
        count ? `data-rtv-count="${count}"` : "",
        `data-rtv-checksum="${checksum}"`,
      ]
        .filter(Boolean)
        .join(" ");

      const token = state.push("html_block", "", 0);
      token.content = `<div ${attrs}></div>`;
      return true;
    },
  };
}

export function setup(helper) {
  // 仅服务端注册；客户端（编辑器预览）由 client-rtv-rule.js 接管
  if (!IS_SERVER) {
    return;
  }

  helper.allowList([
    // 注意:sanitizer 对 class 做整值匹配,必须列出完整的 class 组合
    "div.rtv-block rtv-reply",
    "div.rtv-block rtv-login",
    "div[data-rtv-type]",
    "div[data-rtv-index]",
    "div[data-rtv-count]",
    "div[data-rtv-checksum]",
    "div[data-rtv-state]",
    "div[data-post-id]",
  ]);

  helper.registerPlugin((md) => {
    // 新标签（v1.2.0 起主用）
    md.block.bbcode.ruler.push("rtv_reply_visible", makeReplaceRule("reply-visible", "reply"));
    md.block.bbcode.ruler.push("rtv_login_visible", makeReplaceRule("login-visible", "login"));
    // 旧标签向后兼容：历史帖子仍受保护,移除将导致旧隐藏内容明文泄露
    md.block.bbcode.ruler.push("rtv_reply", makeReplaceRule("reply", "reply"));
    md.block.bbcode.ruler.push("rtv_login", makeReplaceRule("login", "login"));
  });
}
