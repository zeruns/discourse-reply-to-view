/**
 * discourse-reply-to-view —— 占位框交互组件
 *
 * 挂载于未解锁（locked）占位框的 .rtv-actions 节点上（通过官方装饰器通道
 * helper.renderGlimmer 挂载，见 initializers/reply-to-view.js）。
 *
 * 两种交互：
 *   - [login] 占位框：「登录后可见」按钮 → 跳转 /login 并携带
 *     ?redirect_to=当前帖子 URL，登录成功后自动跳回
 *   - [reply] 占位框：「回复后可见」按钮 → 打开针对该帖的回复编辑器
 */
import Component from "@glimmer/component";
import { getOwner } from "@ember/owner";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";
import getURL from "discourse/lib/get-url";

export default class RtvBlock extends Component {
  get isLogin() {
    return !!this.args.data?.isLogin;
  }

  get label() {
    return i18n(
      this.isLogin
        ? "reply_to_view.block.login_button"
        : "reply_to_view.block.reply_button"
    );
  }

  @action
  perform() {
    if (this.isLogin) {
      const here = window.location.pathname + window.location.search;
      window.location.assign(
        `${getURL("/login")}?redirect_to=${encodeURIComponent(here)}`
      );
    } else {
      this.openReplyComposer();
    }
  }

  openReplyComposer() {
    const post = this.args.data?.post;
    const composer = getOwner(this).lookup("service:composer");
    if (composer && post && post.topic) {
      // Composer.REPLY === "reply"
      composer.open({ action: "reply", topic: post.topic, post });
    } else {
      // 兜底：上下文缺失时滚动至回复区
      document
        .getElementById("reply-control")
        ?.scrollIntoView({ behavior: "smooth" });
    }
  }

  <template>
    <button
      type="button"
      class="btn btn-primary rtv-action-btn"
      {{on "click" this.perform}}
    >
      {{this.label}}
    </button>
  </template>
}
