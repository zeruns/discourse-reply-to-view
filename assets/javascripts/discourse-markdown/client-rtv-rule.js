/**
 * discourse-reply-to-view —— 客户端预览规则
 *
 * 仅在浏览器端注册（服务端 mini_racer 上下文中由 server-rtv-rule.js 接管，
 * 两份规则通过核心 __PRETTY_TEXT 标志互斥，避免同名 bbcode 规则相互覆盖）。
 *
 * 职责：编辑器实时预览中正常渲染标记内部的 Markdown（代码块、图片、链接、
 * 列表等），并包裹 rtv-preview 容器 —— 预览的观众是作者本人，
 * 「所见即所得」：容器由前端装饰器附加虚线边框与提示条
 * （见 initializers/reply-to-view.js）。
 *
 * 预览逻辑只作用于本地编辑预览，不影响服务端渲染链路。
 */

const IS_SERVER = typeof __PRETTY_TEXT !== "undefined" && __PRETTY_TEXT === true;

/** 解析 [reply=N] 计数（与服务端规则保持一致：仅正整数有效） */
function parseCount(tagInfo) {
  const raw = tagInfo && tagInfo.attrs && tagInfo.attrs["_default"];
  if (raw && /^\d+$/.test(raw) && parseInt(raw, 10) > 0) {
    return parseInt(raw, 10);
  }
  return null;
}

/** 构造单个标记的 bbcode 规则（rule.wrap 形态：内容正常渲染 + 容器包裹） */
function makeWrapRule(tag, type) {
  return {
    tag,
    wrap(token, tagInfo) {
      const attrs = [
        ["class", `rtv-block rtv-${type} rtv-preview`],
        ["data-rtv-type", type],
      ];
      const count = parseCount(tagInfo);
      if (count) {
        attrs.push(["data-rtv-count", String(count)]);
      }
      token.attrs = attrs;
      return true;
    },
  };
}

export function setup(helper) {
  if (IS_SERVER) {
    return;
  }

  helper.allowList([
    // 注意:sanitizer 对 class 做整值匹配,必须列出完整的 class 组合
    "div.rtv-block rtv-reply rtv-preview",
    "div.rtv-block rtv-login rtv-preview",
    "div[data-rtv-type]",
    "div[data-rtv-count]",
  ]);

  helper.registerPlugin((md) => {
    // 新标签（主用）与旧标签（兼容历史内容）共用预览容器结构
    md.block.bbcode.ruler.push("rtv_reply_visible", makeWrapRule("reply-visible", "reply"));
    md.block.bbcode.ruler.push("rtv_login_visible", makeWrapRule("login-visible", "login"));
    md.block.bbcode.ruler.push("rtv_reply", makeWrapRule("reply", "reply"));
    md.block.bbcode.ruler.push("rtv_login", makeWrapRule("login", "login"));
  });
}
