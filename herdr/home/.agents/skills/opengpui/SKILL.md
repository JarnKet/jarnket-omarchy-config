---
name: opengpui
description: "Show the person a native UI in a Herdr pane and get their input back: write OpenUI Lang to a .oui file, check it with `opengpui check`, open it with `opengpui show`, and receive what they click or submit as an event (typed into your terminal, or from `opengpui wait`). Use when something is easier to read or answer as UI than as text (a form, a choice, a table to review, numbers, approve/reject), or when the person asks for a panel, form or dashboard in Herdr. Requires herdr-app with the opengpui mod and the opengpui CLI."
---

# opengpui: UI in a Herdr pane, answers back to you

You write a `.oui` file in OpenUI Lang (https://openui.com). A Herdr pane draws it
with native elements and redraws whenever the file changes. What the person does
there comes back to you as an event.

## 1. Learn the language

```sh
opengpui prompt > /tmp/openui-manual.md      # read it once per task
```

It is the manual for exactly what the pane draws: syntax, every component's
signature, `$variables`, actions, examples, rules. Write only what it lists.
Options, given the same way to `prompt`, `check` and `show`:

- `--library chat` (default `openui`): the chat library, rooted at `Card` instead of `Stack`.
- `--components Stack,Form,TextArea,…`: only these components. What a kept signature can
  only hold comes along (`Table` brings `Col`, `Form` brings `Buttons`, `FormControl`,
  `Button`); where it offers a choice (`FormControl`'s input), list one, or the command
  exits 2 and names the options.
- `--tools tools.json` (`prompt`, `check` and `show`): teaches `Query()`/`Mutation()` for
  those tools, and `check` refuses a tool not in the file; see Tools below.

## 2. Write, check, show

1. Write the whole file at once (write to a temp file and rename if your tool
   writes in pieces): the pane reports errors in whatever it reads. Under 1 MiB,
   `root = …` first. Where:
   - A pane is part of the conversation, not of the project: write it to
     `~/.cache/opengpui/<project>-<topic>.oui` (create the folder), never into the
     repository. For the same topic, rewrite the same file instead of adding new ones.
   - Herdr mods read only under the home folder, so not `/tmp` or `$TMPDIR`.
   - Never delete these files yourself. If the person asks to keep one, copy it where
     they say. `~/.cache/opengpui/` is theirs to clear whenever they like.
2. `opengpui check ~/.cache/opengpui/shop-deploy.oui`: parses it as the pane will. It prints each
   problem (unknown component, wrong argument, a name used but never defined, a
   statement root never reaches, an unclosed bracket, a Diagram id that matches
   nothing) and exits 1; fix until it prints `ok:`.
3. `opengpui show ~/.cache/opengpui/shop-deploy.oui --title "Deploy review"` opens the pane right of
   your terminal (`--down` below, `--tab` a new tab; `--look openui` for OpenUI's own
   colors instead of Herdr's). Show once: afterwards just rewrite the file. Showing a
   file again closes its earlier pane and starts a new event log.

Markdown with tables, strikethrough or task lists goes in `TextContent` (GitHub-flavored, as
upstream's): `MarkDownRenderer` is plain CommonMark, so a pipe table there shows as a paragraph
of `|` characters.

## 3. Get the answer

A button sends an event: `@ToAssistant("message", {context})`, or a button
without an action (its label is the message). A button inside a
`Form("name", buttons, fields)` sends the form's values and is held back until
required fields are valid. `@OpenUrl` opens the link itself; `$variables`,
`@Set` and `@Reset` change the pane without an event.

Choose how you receive events when you `show`:

- **Reply (default when `$HC_TERMINAL_ID` is set):** end your turn. The event is
  typed into your terminal as your next message:
  ```
  [opengpui /Users/you/.cache/opengpui/shop-deploy.oui] continue_conversation: Approve deploy
  {"at":"…","src":"/Users/you/.cache/opengpui/shop-deploy.oui","type":"continue_conversation","message":"Approve deploy","params":{"context":{"id":42}},"formName":"review","formState":{"review":{"note":"ship it"}}}
  ```
- **Wait:** `opengpui show … --no-reply`, then `opengpui wait ~/.cache/opengpui/shop-deploy.oui --timeout 100`
  blocks until an event and prints each one you haven't seen yet as a JSON line
  (none is lost between `show` and `wait`). Keep `--timeout` below your shell tool's
  time limit (default 110 s); exit 1 means nothing yet: run `wait` again.
  Don't combine it with replies: you'd get every event twice.

`opengpui events ~/.cache/opengpui/shop-deploy.oui` prints every event since `show`.

Reading an event: `message` is what the button said; `params.context` is
`@ToAssistant`'s second argument; `formState` is `{ "<form>": { "<field>": value } }`
for a button in a form (fields nobody touched may be missing), else every form and
every `$variable` (`"$name": value`). A date is the ISO instant of that day's local
midnight (`"2026-11-11T22:00:00.000Z"` = Nov 12 at UTC+2); read it in the person's time zone.

## 4. React

Rewrite the file: the pane follows (a confirmation, the next step, results).
Fields keep what the person typed as long as their names stay.

To stream a long answer as you produce it: write the first lines with the marker
line `]]>openui:content` on top (it is not a statement: `root = …` stays the first
statement), `show`, then keep rewriting the file with more statements (each write
the whole file so far), and finally add a last line `]]>openui:end`. Until that
line the pane shows "streaming…" and holds buttons and inputs, and `check` fails
with `streaming:`; run `check` after the end line.

If the file has errors once complete, the pane lists them and sends an event of
`"type": "errors"` (`errors: [{ code, message, hint, component, statementId }]`).
Fix the file; the pane redraws.

`opengpui close ~/.cache/opengpui/shop-deploy.oui` closes the pane when you're done with it.

## Diagrams

When a picture says it better than text (how something works, a flow, states, a plan, a data
model, who calls whom), draw it. The manual lists three diagram components; the pane lays each
out itself and lets the person pan, zoom and expand it:

- `Diagram`: boxes and arrows (`Node`, `Group`, `Edge`, and `Entity` for boxes with fields).
  Architecture, flowcharts (`decision`, `start`, `end` kinds), state machines, pipelines,
  dependency graphs, trees, data models (ER) and class diagrams.
- `Sequence`: who sends what to whom, in order (`Participant`, `Message`, `Block`).
- `Timeline`: tasks on a time axis (`Task` with dates or numbers, lanes, dependencies).

`opengpui examples` lists worked examples, one per common kind of diagram;
`opengpui examples <name>` prints one. Read the closest before writing your own and adapt it:
they are starting points, not templates to fill in.

- Several small diagrams beat one big one: keep each under about 20 boxes, 12 participants or
  40 tasks. `Tabs` (a tab per diagram) work well for a big picture plus its parts.
- `DiagramStep`s are optional. Add 3–7 when you walk the person through something in order;
  each step lights the ids it talks about.
- When you rewrite the file, keep items in the same order, or the layout jumps.
- A click on a box, a message or a task, or a step's ask button, sends `Tell me more about …`
  with `{diagram, …}` in `params.context`. Answer by adding a diagram (a tab), a step, or text
  beside it, rather than starting over.

## Tools (Query / Mutation)

`--tools tools.json` on `prompt`, `check` and `show` (the same file on all three):
`{ "name": { "command": "/abs/path", "args": [], "cwd": "…", "description": "…", "inputSchema": {…}, "outputSchema": {…} } }`.
The pane runs `command args… '<JSON arguments>'` and reads its stdout as JSON (or
text). It runs with the person's rights: only define tools you would run yourself.

## When it fails

Exit codes: 0 ok, 1 `check` found problems or `wait` timed out, 2 bad usage (the
message says what), 3 Herdr failed: `no Herdr window` means Herdr isn't running,
`no mod "opengpui"` that the mod isn't installed. Then say so and fall back to text.

## Updating

If `show` or `opengpui --version` says a newer release is out, tell the person once, with
https://github.com/lukachi/openGPUI/releases/latest. Do not download or install it yourself:
on this machine, third-party Herdr mods are reviewed before they're updated.
