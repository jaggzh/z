##### File: help/pins.md

# Pinning

Pins are small snippets you inject into a system-prompt or chat, stable across queries (unless you change them). They are great for stable behavior (E.g. A user message like, "be terse"), recurring context (project notes), or lightweight few-shot examples (user|||assistant) messages.

They reduce boilerplate, make CLI sessions predictable, and keep your model grounded without rewriting prompts each time. You can add pins ad-hoc from the CLI, load them from files (pipes or JSON), or manage them via the Perl API. By default, pins persist per **session**; you control what's active by listing, editing, or clearing.

Pins also can be used to provide some other benefits, like:

* **"Current information" placed in the system prompt** (or the first user or assistant message). Keeping in mind that the pattern you establish in the system message can affect how the LLM responds.
* **Exploit the separation for LLM parsing:** Mixed material within the chat history can be difficult for the LLM to find, but it being in a set place of the system prompt, or as the first messages, can assist in the LLM giving it attention.
* **Assistant pattern modeling:** As mentioned, if your initial messages are injected as assistant role, the system prompt need not detail it fully. We often put *"Example session: User: such and such. Assistant: I respond like this."* You can do the same, but the assistant will see them, potentially very firmly, as the way it responded initially (at least that's what you're telling it it did).

Below is everything you need: options (complete), quick recipes for common needs, multiple ways to do the same thing (and why you'd choose one), plus a runnable mini-script at the end to copy-paste and go.

---

## Options (complete)

> Tip: "ast" = assistant; "ua" = user+assistant.

| Flag / alias | Param | Purpose & behavior | Notes / Examples |
|---|---|---|---|
| `--pin` | `STR` (text) | Add a pin with **defaults** (role=`system`, method=`concat`). | `z --pin "You are terse and precise."` |
| `--pins-file` | `PATH` (file) | Load pins from a file. **Autodetects** JSON vs pipes. Supports explicit `json:path` / `txt:path`. | Pipes: one pin per line; `user|||assistant` pairs supported. JSON: array of objects. Examples below. |
| `--pin-sys` | `STR` | Add a **system** pin. Method forced to `concat` (pins are concatenated into the system message). | `z --pin-sys "Never reveal internal notes."` |
| `--pin-user` | `STR` | Add a **user** pin as an individual message (`method=msg`). | `z --pin-user "Assume examples use Perl."` |
| `--pin-ast` | `STR` | Add an **assistant** pin as an individual message (`method=msg`). | `z --pin-ast "I will annotate code."` |
| `--pin-ua-pipe` | `STR` `'user|||assistant'` | Add a paired example: first goes in as `user`, second as `assistant` (both `method=msg`). | `z --pin-ua-pipe 'How to regex digits?|||Use \\d+ with anchors.'` |
| `--pin-ua-json` | `JSON` `{"user":"..","assistant":".."}` | Same as above but JSON. Good for complex quoting/escaping. | `z --pin-ua-json '{"user":"Q","assistant":"A"}'` |
| `--pins-list` | — | List all pins with index, role, method. | Useful before `--pin-write` / `--pin-rm`. |
| `--pins-sum` | — | One-line summaries (truncated). | |
| `--pins-cnt` | — | Output total count of all pins. | |
| `--pin-sum-len` | `N` | Max length for `--pins-sum` lines. | `z --pins-sum --pin-sum-len 120` |
| `--pin-write` | `IDX=NEW` | Replace pin **at index** with new content (keeps role/method). | `z --pin-write '0=Updated content'` |
| `--pin-rm` | `IDX...` | Remove one or more pins by index (space-separate, supports multiple uses). | `z --pin-rm 3 --pin-rm 1 2` |
| `--pins-clear` | — | Clear **all** pins. | |
| `--pins-clear-sys` | — | Clear only **system** pins. | |
| `--pins-clear-user` | — | Clear only **user** pins. | |
| `--pins-clear-ast` | — | Clear only **assistant** pins. | |
| `--pins-sys-max` | `N` | Cap system pins (keeps **newest** up to N; enforced before send). | Default 50. |
| `--pins-user-max` | `N` | Cap user pins (same policy). | Default 50. |
| `--pins-ast-max` | `N` | Cap assistant pins (same policy). | Default 50. |
| `--pin-shim` | `STR` | Append a shim to **user/assistant** pinned messages when building the request (e.g., `<pin-shim/>`). | To **persist** the shim default, combine with `-S` (store user) or `--ss` (store session). |
| `--pin-tpl-user` | `STR` | Template for user pins when using `vars`/`varsfirst` mode. | Store with `--ss`/`--su`. See template examples below. |
| `--pin-tpl-ast` | `STR` | Template for assistant pins when using `vars`/`varsfirst` mode. | Store with `--ss`/`--su`. See template examples below. |
| `--pin-mode-sys` | `vars|concat|both` | How system pins are included in the system prompt. `vars` (default) exposes pins as Xslate vars only; `concat` auto-appends a concatenated system-pin block; `both` does both. | Example: `z --pin-sys "A" --pin-sys "B" --pin-mode-sys vars --system 'Base <: $pins_str :>'` |
| `--pin-mode-user` | `vars|varsfirst|concat` | How user pins are processed. `concat` (default) uses traditional concatenation; `vars` processes template for each pin; `varsfirst` processes template once for first pin only. | Requires `--pin-tpl-user` for `vars`/`varsfirst` modes. |
| `--pin-mode-ast` | `vars|varsfirst|concat` | How assistant pins are processed. Same options as user mode. | Requires `--pin-tpl-ast` for `vars`/`varsfirst` modes. |
| `--help-pins` | — | Dump this file. | `z --help-pins` |

**Pipes format (txt):**  
- Each non-empty, non-comment line is one item.  
- `user|||assistant` creates two pins (paired).  
- A single field line creates a user pin.  
- Escapes supported in fields: `\|` for literal `|`, `\\` for `\`, `\n` for newline.  
- BOM/CRLF handled; lines starting with `#` ignored.

**JSON format:**  
- Array of objects. Two accepted shapes:  
  1) `{ "role": "system|user|assistant", "content": "..." , "method": "concat|msg" }`  
  2) `{ "user": "...", "assistant": "..." }` (paired example)  
- Example:  
  ```json
  [
    {"role":"system","content":"Be terse.","method":"concat"},
    {"user":"Show map of X","assistant":"Here is X"}
  ]
````

---

## Pin Modes and Templates

### System Pin Modes

**`--pin-mode-sys vars` (default)**: System pins are exposed as template variables (`$pins`, `$pins_str`) in your system prompt. No automatic concatenation.

**`--pin-mode-sys concat`**: System pins are automatically concatenated and appended to your system prompt.

**`--pin-mode-sys both`**: Both template variables AND automatic concatenation.

### User/Assistant Pin Modes

**`concat` (default)**: Traditional behavior - pins are concatenated into messages with optional shims.

**`vars`**: Each pinned message is processed through the stored template. Template receives pin data and `pin_idx` (0, 1, 2...).

**`varsfirst`**: Template is processed only for the first pinned message. Subsequent pinned messages are suppressed (empty content).

### Template Variables

When using template modes, these variables are available:

- `$pins` - Array of all pin content for this role
- `$pins_str` - All pins joined with newlines  
- `$pin_cnt` - Total number of pins
- `$pin_idx` - Index of current pin (0-based)

---

## Template Examples

### System Prompt Templates

**Simplest form** - Use `--pin-mode-sys concat` and reference pins in your system prompt:

```
You are a helpful AI assistant.
# Pinned content follows
<: $pins_str :>
```

**Conditional header** - Only show header if pins exist:

```
You are a helpful AI assistant.
: if $pin_cnt > 0 {
# Pinned content follows
<: $pins_str :>
: }
```

**Custom formatting** - Loop through individual pins:

```
You are a helpful AI assistant.
: if $pin_cnt > 0 {
# Here are your guidelines:
:   for $pins -> $pin {
- <: $pin :>
:   }
: }
```

### User Pin Templates

**Set up a user template for `varsfirst` mode:**

```bash
# Store the template
z --pin-tpl-user ': if $pin_idx == 0 && $pin_cnt > 0 {
## Reference Information
<: $pins_str :>
: }' --pin-mode-user varsfirst --ss

# Add your pin data
z --pin-user "Use Perl best practices"
z --pin-user "Prefer modern syntax (v5.34+)"
z --pin-user "Use strict and warnings"

# Now queries get ONE user message with formatted reference info
z "How should I structure a Perl module?"
```

**Custom formatting with loops:**

```bash
z --pin-tpl-user ': if $pin_idx == 0 && $pin_cnt > 0 {
## Context Notes
:   for $pins -> $note {
• <: $note :>
:   }
: }' --pin-mode-user varsfirst --ss
```

**Template with `vars` mode** - processes for each pin:

```bash
# Template that shows pin index
z --pin-tpl-user 'Reference <: $pin_idx + 1 :>: <: $pins[$pin_idx] :>' --pin-mode-user vars --ss
```

### Assistant Pin Templates

Same pattern as user templates:

```bash
z --pin-tpl-ast ': if $pin_idx == 0 && $pin_cnt > 0 {
I have these example responses to guide me:
<: $pins_str :>
: }' --pin-mode-ast varsfirst --ss
```

---

## How pins are sent (assembly order)

1. **System**: preset/system file/CLI system prompt. If `pin_mode_sys` ∈ {`concat`,`both`} a concatenated **system-pin block** is appended; regardless of mode, system pins are exposed as Xslate vars (`$pins`, `$pins_str`) when rendering the system text (default `pin_mode_sys=vars`, i.e., no auto-append).
2. **Assistant pins**: processed according to `pin_mode_ast` - either concatenated blocks, template-processed messages, or template-processed first message only.
3. **User pins**: processed according to `pin_mode_user` - same options as assistant pins.
4. **History**: prior turns (unless disabled).
5. **Current** user input.

**Limits** (`--pins-*-max`) are enforced **per role** before assembly (keep newest).
**Shim** (`--pin-shim`) is appended to user/assistant **pinned** messages at build time (not to live turns).

**Templating:** System prompts and pin templates support Xslate vars:  
`$datenow_ymd`, `$datenow_iso`, `$datenow_local`, `$modelname`,  
`$pins` (ARRAY of pins for this role), `$pins_str` (pins joined with `\n`), `$pin_cnt`, `$pin_idx`.

---

## Quick recipes (CLI first, API second)

### 1) "Be terse and precise" (behavior pin)

When: casual Q\&A, you want consistent tone.
Result: persistent system behavior for the **session**.

**CLI**

```bash
z -n demo/session --pin-sys "You are terse and precise." --pins-list
```

**API**

```perl
my $z = ZChat->new(session => 'demo/session');
$z->pin("You are terse and precise.", role=>'system', method=>'concat');
```

---

### 2) Add a one-off example (paired user|||assistant)

When: nudge the model with a concrete example; easy to type.
Result: two pinned messages (user & assistant), used before your current query.

**CLI**

```bash
z --pin-ua-pipe 'How to match digits?|||Use \d+ with anchors.'
```

**API**

```perl
$z->pin("How to match digits?", role=>'user', method=>'msg');
$z->pin("Use \\d+ with anchors.", role=>'assistant', method=>'msg');
```

### 2.5) Use system pins as template vars (no auto-concat)

When: you want full control over where/how system pins appear in your system prompt.
Result: system text renders with `$pins_str` while pins are not auto-appended.

**CLI**

```bash
z --pin-sys "Alpha rule" --pin-sys "Beta rule" \
  --pin-mode-sys vars \
  --system 'Base policy. Active rules:\n<: $pins_str :>'
```

**API**
```perl
my $z = ZChat->new(
  session       => 'demo/session',
  system_prompt => "Base policy.\nActive rules:\n<: \$pins_str :>",
  pin_mode_sys  => 'vars',
);
$z->pin("Alpha rule", role=>'system', method=>'concat');
$z->pin("Beta rule",  role=>'system', method=>'concat');
```

---

### 3) Use template for formatted user reference (varsfirst)

When: you want one clean reference section from multiple user pins.
Result: first user pin becomes formatted template output; subsequent pins suppressed.

**CLI**

```bash
# Set up template and mode
z --pin-tpl-user ': if $pin_idx == 0 && $pin_cnt > 0 {
## Reference Material
<: $pins_str :>
: }' --pin-mode-user varsfirst --ss

# Add reference data
z --pin-user "Use modern Perl (v5.34+)"
z --pin-user "Always use strict and warnings"
z --pin-user "Prefer Moo over raw bless"

# Query uses template once
z "How should I write a Perl class?"
```

**API**

```perl
my $z = ZChat->new(
    session => 'demo/session',
    pin_tpl_user => ': if $pin_idx == 0 && $pin_cnt > 0 {
## Reference Material
<: $pins_str :>
: }',
    pin_mode_user => 'varsfirst',
);
$z->pin("Use modern Perl (v5.34+)", role=>'user', method=>'msg');
$z->pin("Always use strict and warnings", role=>'user', method=>'msg');
```

---

### 4) Keep a small playbook (pipes file)

When: you've got many pairs and want to edit in a text file.
Result: bulk pins; easiest to maintain by hand.

**pins.txt**

```
# simple pairs
Sort array|||Use sort { $a <=> $b } @arr
Perl version|||Check $]
```

**CLI**

```bash
z --pins-file pins.txt --pins-list
```

**API**

```perl
my $items = read_pipes_file('pins.txt');     # Utils
for my $it (@$items) {
    $z->pin($it->{user}, role=>'user', method=>'msg')           if $it->{user};
    $z->pin($it->{assistant}, role=>'assistant', method=>'msg') if $it->{assistant};
}
```

---

### 5) Structured pins (JSON file)

When: you need roles/methods explicitly; safer for complex content.
Result: exactly what you specify, no ambiguity.

**pins.json**

```json
[
  {"role":"system","content":"Prefer modern Perl.","method":"concat"},
  {"role":"user","content":"Assume inputs are UTF-8","method":"msg"},
  {"user":"What is Moo?","assistant":"A lightweight OO system."}
]
```

**CLI**

```bash
z --pins-file json:pins.json
```

**API**

```perl
for my $it (@{ read_json_file('pins.json') }) {
    if (exists $it->{role}) {
        $z->pin($it->{content}, role=>$it->{role}, method=>($it->{method}//'msg'));
    } else {
        $z->pin($it->{user}, role=>'user', method=>'msg')           if $it->{user};
        $z->pin($it->{assistant}, role=>'assistant', method=>'msg') if $it->{assistant};
    }
}
```

---

### 6) Swap styles quickly (clear by role)

When: change just system tone; preserve examples.
Result: only system pins are replaced.

**CLI**

```bash
z --pins-clear-sys --pin-sys "Be concise; show code only when asked."
```

**API**

```perl
$z->{pin_mgr}->clear_pins_by_role('system');
$z->pin("Be concise; show code only when asked.", role=>'system', method=>'concat');
```

---

### 7) Use a shim to delineate pinned content

When: you generate or parse responses with markers.
Result: shim appended to user/assistant **pinned** messages at send-time.

**CLI**

```bash
z --pin-shim '<pin-shim/>' --pin-user "Assume inputs are Perl."
# persist as default for this user or session
z -S --pin-shim '<pin-shim/>'      # user default
z --ss --pin-shim '<pin-shim/>'    # session default
```

**API**

```perl
my $z = ZChat->new(session=>'demo', pin_shims=>{ user=>'<pin-shim/>', assistant=>'<pin-shim/>' });
$z->pin("Assume inputs are Perl.", role=>'user', method=>'msg');
```

---

### 8) Keep pins under control (caps)

When: you bulk-add frequently.
Result: newest pins are kept up to role caps; older ones trimmed before send.

**CLI**

```bash
z --pins-user-max 10 --pins-ast-max 5 --pins-sys-max 5 --pins-list
```

**API**

```perl
$z->{pin_mgr}->enforce_pin_limits({ user=>10, assistant=>5, system=>5 });
```

---

### 9) Edit or surgically remove

When: quick fix after listing.

**CLI**

```bash
z --pins-list
z --pin-write '0=Updated content'
z --pin-rm 3 5
```

**API**

```perl
my $pins = $z->list_pins();
$z->remove_pin(3);
$z->pin("Updated content", role=>$pins->[0]{role}, method=>$pins->[0]{method});
```

---

## Template Mode Behavior Summary

| Mode | User Pins | Assistant Pins | System Pins |
|------|-----------|----------------|-------------|
| `concat` | Traditional concatenation + shims | Traditional concatenation + shims | Auto-appended to system prompt |
| `vars` | Template processed for each pin message | Template processed for each pin message | Available as template vars only |
| `varsfirst` | Template processed once (first pin), others suppressed | Template processed once (first pin), others suppressed | N/A |
| `both` | N/A | N/A | Template vars AND auto-append |

**Key insight**: `varsfirst` is perfect for "one formatted reference section" from multiple data pins. `vars` is for per-pin processing with templates. `both`? I don't know what use this is.

---

## Storage & internals

* Pins are stored per session at:
  `~/.config/zchat/sessions/<session>/pins.yaml`
* Pin templates stored in session/user config:
  `~/.config/zchat/sessions/<session>/session.yaml` or `~/.config/zchat/user.yaml`
* Format (simplified):

  ```yaml
  pins:
    - { role: system,    method: concat, content: "text...", timestamp: 1710000000 }
    - { role: assistant, method: msg,    content: "text...", timestamp: 1710000100 }
    - { role: user,      method: msg,    content: "text...", timestamp: 1710000200 }
  created: 1710000000
  
  # Templates and modes in session.yaml
  pin_tpl_user: ": if $pin_idx == 0 { Reference: <: $pins_str :> : }"
  pin_mode_user: "varsfirst"
  ```

* Assembly order and shims as described above.
* **Limits** are enforced before request build.
* **System templating** (Xslate) supports: `$datenow_ymd`, `$datenow_iso`, `$datenow_local`, `$modelname`.

---

## Troubleshooting

* **Pipes vs JSON:** autodetect uses first non-space char; force with `json:path` or `txt:path`.
* **Escaping pipes:** use `\|` for literal pipe, `\\` for backslash, `\n` for newline; or use JSON.
* **JSON parse errors:** the error will include line/column; prefer JSON when content has many `|` or quotes.
* **Template syntax errors:** Xslate will warn about template processing failures; check your `<: :>` syntax.
* **Empty template output:** For `varsfirst` mode, only the first pin processes the template; subsequent pins are empty.
* **Nothing seems to change:** check session name (`-n`), `--pins-list` to verify, or clear role-specific pins.

---

## Mini script (runnable)

```perl
#!/usr/bin/env perl
use v5.34;
use utf8;
use lib 'lib';
use ZChat;
use ZChat::Utils ':all';

# 1) Create session with templates and modes
my $z = ZChat->new(
    session   => 'demo/pins',
    pin_shims => { user => '<pin-shim/>', assistant => '<pin-shim/>' },
    pin_tpl_user => ': if $pin_idx == 0 && $pin_cnt > 0 {
## Reference Material
<: $pins_str :>
: }',
    pin_mode_user => 'varsfirst',
);

# 2) Add pins (system + ua pair + user references)
$z->pin("You are terse and precise.", role=>'system', method=>'concat');
$z->pin("How to match digits?", role=>'user', method=>'msg');
$z->pin("Use \\d+ with anchors.", role=>'assistant', method=>'msg');
$z->pin("Use modern Perl (v5.34+)", role=>'user', method=>'msg');
$z->pin("Always use strict and warnings", role=>'user', method=>'msg');

# 3) Cap per-role counts
$z->{pin_mgr}->enforce_pin_limits({ system=>5, user=>10, assistant=>5 });

# 4) Ask a question (template processes user pins into one formatted message)
my $answer = $z->query("Give a short example of a regex for integers.");
say "\n---\n$answer\n";

# 5) Inspect
my $pins = $z->list_pins();
say "Pins:\n", dumps($pins);
```

Run:

```bash
perl examples/demo_pins.pl
```

---

## Roadmap / notes

* TTL/expiry and `--pin-opts` (JSON/KV bundles) are on the roadmap; today's CLI covers the 90% with explicit flags plus files.
* Future roles (e.g., tool results) will be mapped provider-specifically; stick to `system|user|assistant` for portability.
* Template support may expand to include more template engines beyond Xslate.

---

Copyright © 2025 jaggz.h {who is at} gmail.com. All rights reserved. See LICENSE.
