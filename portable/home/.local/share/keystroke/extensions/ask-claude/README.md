# Ask Claude

Local Keystroke extension that opens the **Ask Claude** panel: the
`shadowone.ask-claude` Omarchy bar plugin, which answers through the signed-in
Claude Code CLI on Claude Sonnet.

- **Ask Claude** is the first row at the palette root (score 40, above
  Applications at 30) and opens the panel.
- Anything typed gets **Ask Claude here** under *Continue with*, just above
  Ask Codex here; `↵` sends the text to the panel.
- `ask <question>` sends the question straight away.

Every row runs `omarchy-shell shadowone.ask-claude open|ask <text>`. The panel
itself is also on `Super+A` and on the bar.
