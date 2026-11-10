// The bar of an OpenUI window that the chat opens (claude-chat/openui.js): the panel's title to drag the window by, and
// a button that closes it. The window's id is in shared "oui.windows" under the window's key, written by the chat.
import { View, div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { props, theme, shared, setShared, closeOverlay } from "herdr";

export default class OuiWindow extends View {
  close() {
    const p = props() ?? {}, windows = shared("oui.windows") ?? {};
    const id = p.overlay ?? windows[p.key];
    if (id) closeOverlay(id);
    if (p.key in windows) { const { [p.key]: _gone, ...rest } = windows; setShared("oui.windows", rest); }
  }

  render() {
    const t = theme(), p = props() ?? {};
    return h_flex().size_full().pl(12).pr(6).gap(8).items_center().bg(t.chrome).border_b_1().border_color(t.border)
      .text_size(12).text_color(t.muted)
      .child(div().flex_none().text_color(t.accent).child("◧"))
      .child(div().flex_1().min_w(0).truncate().child(p.title ?? "OpenUI"))
      .child(h_flex().id("oui-close").size(22).flex_none().items_center().justify_center().rounded(5).cursor_pointer()
        .hover((s) => s.bg(t.hover).text_color(t.foreground))
        .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
        .on_click(() => this.close())
        .child("✕"));
  }
}
