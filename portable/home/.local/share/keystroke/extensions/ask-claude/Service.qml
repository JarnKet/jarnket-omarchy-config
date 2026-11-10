import QtQuick
import Quickshell

// Ask Claude for Keystroke. Puts the Ask Claude panel (the shadowone.ask-claude
// bar plugin, also on SUPER+A) first at the palette root, offers "Ask Claude
// here" for whatever is typed, and answers `ask <question>`. Every row hands
// off to the panel over omarchy-shell IPC; the palette closes first.
QtObject {
  id: root
  property var shell: null
  property var extension: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  readonly property string key: extension && extension.id ? String(extension.id) : "ask-claude"
  readonly property string subtitle: "Quick answers from Claude Sonnet · Super+A"

  readonly property var provider: ({
    apiVersion: 1,
    name: "Ask Claude",
    icon: "󰙴",
    description: "Quick answers from Claude Sonnet in the Ask Claude panel",
    settings: [],
    query: function(ctx) { return root.query(ctx) }
  })

  function openPanel() {
    return { type: "exec", argv: ["omarchy-shell", "shadowone.ask-claude", "open"] }
  }

  function askPanel(text) {
    return { type: "exec", argv: ["omarchy-shell", "shadowone.ask-claude", "ask", text] }
  }

  function query(ctx) {
    if (ctx.scope && ctx.scope !== root.key) return []

    if (ctx.command) {
      var question = String(ctx.command.rest || "").trim()
      return [{ id: "ask", title: "Ask Claude", subtitle: question || "Type your question after ask", icon: "󰙴",
                section: "Claude", verb: question ? "Ask" : "Open", tier: "answer", score: 100,
                action: question ? root.askPanel(question) : root.openPanel() }]
    }

    var text = String(ctx.rawQuery === undefined ? ctx.query || "" : ctx.rawQuery).trim()
    // Applications (30) and Omarchy Menu (28) lead the root otherwise.
    if (!text)
      return [{ id: "open", title: "Ask Claude", subtitle: root.subtitle, icon: "󰙴", section: "Claude",
                verb: "Open", tier: "item", score: 40, order: 0, action: root.openPanel() }]

    return [
      // Found by name ("claude", "ask", "ai"): the default matcher scores it.
      { id: "open", title: "Ask Claude", subtitle: root.subtitle, icon: "󰙴", section: "Claude", verb: "Open",
        tier: "item", keywords: "claude ai sonnet assistant chat question", action: root.openPanel() },
      // The typed text as a question, just above Ask Codex here (5).
      { id: "ask", title: "Ask Claude here", subtitle: text, icon: "󰙴", section: "Continue with", verb: "Ask",
        tier: "fallback", score: 6, action: root.askPanel(text) }
    ]
  }
}
