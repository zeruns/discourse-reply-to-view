/**
 * discourse-reply-to-view —— 打开回复编辑器的共享助手
 *
 * 【修复说明】composer.open 有严格的参数契约（与核心 topic 控制器一致）：
 *   1. 必须传 draftKey / draftSequence（取自 topic 的 draft_key / draft_sequence），
 *      缺失会导致 open 内部异常、编辑器无法弹出；
 *   2. 回复首楼（post_number === 1）时传 topic（回复主题本身），
 *      回复其他楼层时传 post（针对该楼回复）。
 * 参见核心 frontend/discourse/app/controllers/topic.js 中 reply 部分的实现。
 */
import Composer from "discourse/models/composer";

export function openReplyComposer(owner, post) {
  const composer = owner?.lookup?.("service:composer");
  const get = (obj, key) => (obj?.get ? obj.get(key) : obj?.[key]);
  const topic = get(post, "topic");

  if (!composer || !topic) {
    // 上下文缺失时兜底:滚动至回复区
    document.getElementById("reply-control")?.scrollIntoView({ behavior: "smooth" });
    return;
  }

  const opts = {
    action: Composer.REPLY || "reply",
    draftKey: get(topic, "draft_key"),
    draftSequence: get(topic, "draft_sequence") || 0,
  };

  if (post && get(post, "post_number") !== 1) {
    opts.post = post;
  } else {
    opts.topic = topic;
  }

  Promise.resolve(composer.open(opts)).catch((error) => {
    // 打开失败时兜底,保证按钮至少有可见反馈
    // eslint-disable-next-line no-console
    console?.warn?.("reply-to-view: failed to open composer", error);
    document.getElementById("reply-control")?.scrollIntoView({ behavior: "smooth" });
  });
}
