/**
 * discourse-reply-to-view —— 前端主入口
 *
 * 职责：
 *   1. 编辑器「+」扩展菜单中的两个插入选项（回帖可见 / 登录可见）
 *   2. 帖子渲染与编辑器预览的占位框装饰（作者提示条 / 登录与回复按钮）
 *   3. 用户回复成功后对页面内锁定帖子做单帖局部刷新（不重拉整个主题）
 *
 * 【安全说明】前端的一切展示均为渐进增强：可见性判定 100% 在服务端完成，
 * 未解锁用户收到的 HTML 中本就不含隐藏原文，前端无需也不做任何“隐藏”逻辑。
 */
import { apiInitializer } from "discourse/lib/api";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";
import RtvBlock from "../components/rtv-block";
import { openReplyComposer } from "../lib/rtv-composer";

export default apiInitializer("1.34.0", (api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  const currentUser = api.getCurrentUser();

  if (!siteSettings.enable_rtv) {
    return;
  }

  /* ==================== 1. 编辑器「+」扩展菜单选项 ====================
   * 通过官方 addComposerToolbarPopupMenuOption 注册到编辑器工具栏的
   * 「+」扩展菜单（与“引用整个帖子/插表/隐藏详细信息”同级），
   * 桌面端与移动端一致。
   *
   * 注意两点实现契约（与核心 d-editor 保持一致）：
   *   - label 为完整 i18n 键（菜单组件自行翻译）；
   *   - applySurround 的 exampleKey 会被核心拼接 composer. 前缀
   *     （composer.${exampleKey}），故此处只传短键，翻译放在
   *     js.composer.rtv_*_surround_example 下。
   *
   * 使用权限：staff 始终可用；普通用户按 min_trust_level_to_use 判定。
   * 前端仅控制菜单项显隐，服务端序列化层仍是最终权威（低等级标记不生效）。
   */
  const minTL = parseInt(siteSettings.min_trust_level_to_use ?? "0", 10);
  const canUse =
    !currentUser || currentUser.staff || currentUser.trust_level >= minTL;

  api.addComposerToolbarPopupMenuOption({
    name: "rtv-reply",
    icon: "reply", // fas fa-reply
    label: "composer.rtv_reply_option",
    condition: () => canUse,
    action: (toolbarEvent) => {
      // 有选中文本时包裹选区；无选中文本时插入空标签对，
      // 光标定位到标签中间（example 文本处于选中态，可直接输入替换）。
      // v1.2.0 起新帖使用 [reply-visible] 标签;旧标签 [reply] 仍受支持
      toolbarEvent.applySurround(
        "[reply-visible]\n",
        "\n[/reply-visible]",
        "rtv_reply_surround_example"
      );
    },
  });

  api.addComposerToolbarPopupMenuOption({
    name: "rtv-login",
    icon: "user", // fas fa-user
    label: "composer.rtv_login_option",
    condition: () => canUse,
    action: (toolbarEvent) => {
      toolbarEvent.applySurround(
        "[login-visible]\n",
        "\n[/login-visible]",
        "rtv_login_surround_example"
      );
    },
  });

  /* ==================== 2. 帖子 / 预览装饰 ==================== */
  api.decorateCookedElement(
    (element, helper) => decorateRtvBlocks(element, helper),
    { id: "reply-to-view-decorator" }
  );

  function decorateRtvBlocks(element, helper) {
    element.querySelectorAll(".rtv-block").forEach((el) => {
      // —— 编辑器预览（作者本人视角）：完整内容 + 虚线边框 + 提示条，所见即所得 ——
      if (el.classList.contains("rtv-preview")) {
        addNotice(el, "reply_to_view.block.preview_notice", "rtv-preview-notice");
        return;
      }

      const state = el.getAttribute("data-rtv-state");

      // —— 作者本人查看自己的隐藏内容：内容 + 虚线边框 + 淡色提示条 ——
      if (state === "owner") {
        addNotice(el, "reply_to_view.block.owner_notice", "rtv-owner-notice");
      }

      // —— 未解锁：挂载交互组件（登录后可见 / 回复后可见按钮）——
      if (state === "locked") {
        mountActions(el, helper);
      }
    });
  }

  function addNotice(el, key, className) {
    if (el.querySelector(`.${className}`)) {
      return;
    }
    const notice = document.createElement("div");
    notice.className = `rtv-notice ${className}`;
    notice.textContent = i18n(key);
    el.prepend(notice);
  }

  function mountActions(el, helper) {
    const target = el.querySelector(".rtv-actions");
    if (!target || target.childElementCount > 0) {
      return;
    }
    const isLogin = el.classList.contains("rtv-login");
    const data = { isLogin, post: helper?.model };

    // 优先以 Glimmer 组件挂载（官方 renderGlimmer 装饰器通道）
    if (helper && typeof helper.renderGlimmer === "function") {
      helper.renderGlimmer(target, RtvBlock, data);
    } else {
      buildFallbackActions(target, data);
    }
  }

  // renderGlimmer 不可用时的纯 DOM 兜底（行为与组件一致）
  function buildFallbackActions(target, { isLogin, post }) {
    const btn = document.createElement("button");
    btn.className = "btn btn-primary rtv-action-btn";
    btn.textContent = i18n(
      isLogin
        ? "reply_to_view.block.login_button"
        : "reply_to_view.block.reply_button"
    );
    btn.addEventListener("click", (event) => {
      event.preventDefault();
      performAction({ isLogin, post });
    });
    target.appendChild(btn);
  }

  function performAction({ isLogin, post }) {
    if (isLogin) {
      // 跳转登录页并携带 redirect_to，登录成功后自动跳回当前帖子
      const here = window.location.pathname + window.location.search;
      window.location.assign(
        `${getURLBase()}/login?redirect_to=${encodeURIComponent(here)}`
      );
      return;
    }
    openReplyComposer(api.container, post);
  }

  // 登录跳转基址（避免在插件初始化顶层引入额外依赖时的轻量封装）
  function getURLBase() {
    return document.querySelector('meta[name="discourse-base-uri"]')?.content || "";
  }

  /* ==================== 3. 回复成功后的局部刷新 ====================
   * 监听回复创建完成事件（appEvents "post:created"），
   * 仅对页面内处于锁定态的 rtv 帖子发起 /posts/:id.json 单帖刷新：
   *   - 优先走 store 更新 post 模型的 cooked，Ember 响应式自动重渲染，
   *     帖子的全部装饰器（@提及、灯箱等）由组件重新应用；
   *   - 模型不在当前身份映射表时退回 DOM 替换。
   * 全程不重拉整个主题流。
   */
  const appEvents = api.container.lookup("service:app-events");
  const store = api.container.lookup("service:store");
  appEvents.on("post:created", () => refreshLockedBlocks());

  async function refreshLockedBlocks() {
    const locked = document.querySelectorAll(
      ".rtv-block[data-rtv-state='locked'][data-post-id]"
    );
    if (!locked.length) {
      return;
    }

    const postIds = new Set(
      [...locked].map((el) => el.getAttribute("data-post-id"))
    );

    for (const id of postIds) {
      try {
        const refreshed = await ajax(`/posts/${id}.json`);
        if (!refreshed?.cooked) {
          continue;
        }
        const numericId = Number(id);
        let model = null;
        try {
          model = store.peekRecord("post", numericId);
        } catch {
          model = null;
        }

        if (model) {
          // 响应式路径：更新模型触发组件重渲染（装饰器完整保留）
          model.set("cooked", refreshed.cooked);
        } else {
          // 兜底路径：直接替换 DOM,并对新节点重新应用本插件的装饰
          document
            .querySelectorAll(`.rtv-block[data-post-id='${CSS.escape(id)}']`)
            .forEach((el) => {
              const cookedEl = el.closest(".cooked");
              if (cookedEl) {
                cookedEl.innerHTML = refreshed.cooked;
                decorateRtvBlocks(cookedEl, null);
              }
            });
        }
      } catch {
        // 静默失败：下一次整页加载时服务端判定自然生效
      }
    }
  }
});
