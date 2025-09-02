##### File: help/pins.md

# Pinning

Pins are small snippets you always inject into a chat—great for stable behavior (“be terse”), recurring context (project notes), or lightweight few-shot examples (user|||assistant). They reduce boilerplate, make CLI sessions predictable, and keep your model grounded without rewriting prompts each time. You can add pins ad-hoc from the CLI, load them from files (pipes or JSON), or manage them via the Perl API. By default, pins persist per **session**; you control what’s active by listing, editing, or clearing.

Below is everything you need: options (complete), quick recipes for common needs, multiple ways to do the same thing (and why you’d choose one), plus a runnable mini-script at the end to copy-paste and go.

---

## Options (complete)

> Tip: “ast” = assistant; “ua” = user+assistant.

| Flag / alias | Param | Purpose & behavior | Notes / Examples |
|---|---|---|---|
| `--pin` | `STR` (text) | Add a pin with **defaults** (role=`system`, method=`concat`). | `z --pin "You are terse and precise."` |
| `--pin-file` | `PATH` (file) | Load pins from a file. **Autodetects** JSON vs pipes. Supports explicit `json:path` / `txt:path`. | Pipes: one pin per line; `user|||assistant` pairs supported. JSON: array of objects. Examples below. |
| `--pin-sys` | `STR` | Add a **system** pin. Method forced to `concat` (pins are concatenated into the system message). | `z --pin-sys "Never reveal internal notes."` |
| `--pin-user` | `STR` | Add a **user** pin as an individual message (`method=msg`). | `z --pin-user "Assume examples use Perl."` |
| `--pin-ast` | `STR` | Add an **assistant** pin as an individual message (`method=msg`). | `z --pin-ast "I will annotate code."` |
| `--pin-ua-pipe` | `STR` `'user|||assistant'` | Add a paired example: first goes in as `user`, second as `assistant` (both `method=msg`). | `z --pin-ua-pipe 'How to regex digits?|||Use \\d+ with anchors.'` |
| `--pin-ua-json` | `JSON` `{"user":"..","assistant":".."}` | Same as above but JSON. Good for complex quoting/escaping. | `z --pin-ua-json '{"user":"Q","assistant":"A"}'` |
| `--pin-list` | — | List all pins with index, role, method. | Useful before `--pin-write` / `--pin-rm`. |
| `--pin-sum` | — | One-line summaries (truncated). | |
| `--pin-sum-len` | `N` | Max length for `--pin-sum` lines. | `z --pin-sum --pin-sum-len 120` |
| `--pin-write` | `IDX=NEW` | Replace pin **at index** with new content (keeps role/method). | `z --pin-write '0=Updated content'` |
| `--pin-rm` | `IDX...` | Remove one or more pins by index (space-separate, supports multiple uses). | `z --pin-rm 3 --pin-rm 1 2` |
| `--pin-clear` | — | Clear **all** pins. | |
| `--pins-clear-sys` | — | Clear only **system** pins. | |
| `--pins-clear-user` | — | Clear only **user** pins. | |
| `--pins-clear-ast` | — | Clear only **assistant** pins. | |
| `--pins-sys-max` | `N` | Cap system pins (keeps **newest** up to N; enforced before send). | Default 50. |
| `--pins-user-max` | `N` | Cap user pins (same policy). | Default 50. |
| `--pins-ast-max` | `N` | Cap assistant pins (same policy). | Default 50. |
| `--pin-shim` | `STR` | Append a shim to **user/assistant** pinned messages when building the request (e.g., `<pin-shim/>`). | To **persist** the shim default, combine with `-S` (store user) or `--ss` (store session). |
| `--pin-sys-mode` | `vars|concat|both` | How system pins are included in the system prompt. `vars` (default) exposes pins as Xslate vars only; `concat` auto-appends a concatenated system-pin block; `both` does both. | Example: `z --pin-sys "A" --pin-sys "B" --pin-sys-mode vars --system 'Base <: $pins_str :>'` |
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

## How pins are sent (assembly order)

1. **System**: preset/system file/CLI system prompt. If `pin_sys_mode` ∈ {`concat`,`both`} a concatenated **system-pin block** is appended; regardless of mode, system pins are exposed as Xslate vars (`$pins`, `$pins_str`) when rendering the system text (default `pin_sys_mode=vars`, i.e., no auto-append).
2. **Assistant pins**: first a concatenated block (if any), then individual assistant pin messages (`method=msg`).
3. **User pins**: concatenated block (if any), then individual user pin messages (`method=msg`).
4. **History**: prior turns (unless disabled).
5. **Current** user input.

**Limits** (`--pins-*-max`) are enforced **per role** before assembly (keep newest).
**Shim** (`--pin-shim`) is appended to user/assistant **pinned** messages at build time (not to live turns).

**Templating (system only):** Presets/system text support Xslate vars:  
`$datenow_ymd`, `$datenow_iso`, `$datenow_local`, `$modelname`,  
`$pins` (ARRAY of system pins), `$pins_str` (system pins joined with `\n`).  
Use `--pin-sys-mode vars|both` to make use of `$pins`/`$pins_str` without (or alongside) auto-concatenation.

---

## Quick recipes (CLI first, API second)

### 1) “Be terse and precise” (behavior pin)

When: casual Q\&A, you want consistent tone.
Result: persistent system behavior for the **session**.

**CLI**

```bash
z -n demo/session --pin-sys "You are terse and precise." --pin-list
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
  --pin-sys-mode vars \
  --system 'Base policy. Active rules:\n<: $pins_str :>'
```

**API**
```perl
my $z = ZChat->new(
  session       => 'demo/session',
  system_prompt => "Base policy.\nActive rules:\n<: \$pins_str :>",
  pin_sys_mode  => 'vars',
);
$z->pin("Alpha rule", role=>'system', method=>'concat');
$z->pin("Beta rule",  role=>'system', method=>'concat');
```

---

### 3) Keep a small playbook (pipes file)

When: you’ve got many pairs and want to edit in a text file.
Result: bulk pins; easiest to maintain by hand.

**pins.txt**

```
# simple pairs
Sort array|||Use sort { $a <=> $b } @arr
Perl version|||Check $]
```

**CLI**

```bash
z --pin-file pins.txt --pin-list
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

### 4) Structured pins (JSON file)

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
z --pin-file json:pins.json
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

### 5) Swap styles quickly (clear by role)

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

### 6) Use a shim to delineate pinned content

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

### 7) Keep pins under control (caps)

When: you bulk-add frequently.
Result: newest pins are kept up to role caps; older ones trimmed before send.

**CLI**

```bash
z --pins-user-max 10 --pins-ast-max 5 --pins-sys-max 5 --pin-list
```

**API**

```perl
$z->{pin_mgr}->enforce_pin_limits({ user=>10, assistant=>5, system=>5 });
```

---

### 8) Edit or surgically remove

When: quick fix after listing.

**CLI**

```bash
z --pin-list
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

## Storage & internals

* Pins are stored per session at:
  `~/.config/zchat/sessions/<session>/pins.yaml`
* Format (simplified):

  ```yaml
  pins:
    - { role: system,    method: concat, content: "text...", timestamp: 1710000000 }
    - { role: assistant, method: msg,    content: "text...", timestamp: 1710000100 }
    - { role: user,      method: msg,    content: "text...", timestamp: 1710000200 }
  created: 1710000000
  ```
* Assembly order and shims as described above.
* **Limits** are enforced before request build.
* **System templating** (Xslate) supports: `$datenow_ymd`, `$datenow_iso`, `$datenow_local`, `$modelname`.

---

## Troubleshooting

* **Pipes vs JSON:** autodetect uses first non-space char; force with `json:path` or `txt:path`.
* **Escaping pipes:** use `\|` for literal pipe, `\\` for backslash, `\n` for newline; or use JSON.
* **JSON parse errors:** the error will include line/column; prefer JSON when content has many `|` or quotes.
* **Nothing seems to change:** check session name (`-n`), `--pin-list` to verify, or clear role-specific pins.

---

## Mini script (runnable)

```perl
#!/usr/bin/env perl
use v5.34;
use utf8;
use lib 'lib';
use ZChat;
use ZChat::Utils ':all';

# 1) Create session and set a shim at runtime
my $z = ZChat->new(
    session   => 'demo/pins',
    pin_shims => { user => '<pin-shim/>', assistant => '<pin-shim/>' },
);

# 2) Add pins (system + ua pair + a user hint)
$z->pin("You are terse and precise.", role=>'system', method=>'concat');
$z->pin("How to match digits?", role=>'user', method=>'msg');
$z->pin("Use \\d+ with anchors.", role=>'assistant', method=>'msg');
$z->pin("Assume inputs are Perl.", role=>'user', method=>'msg');

# 3) Cap per-role counts
$z->{pin_mgr}->enforce_pin_limits({ system=>5, user=>10, assistant=>5 });

# 4) Ask a question (pins + history + this input)
my $answer = $z->complete("Give a short example of a regex for integers.");
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

* TTL/expiry and `--pin-opts` (JSON/KV bundles) are on the roadmap; today’s CLI covers the 90% with explicit flags plus files.
* Future roles (e.g., tool results) will be mapped provider-specifically; stick to `system|user|assistant` for portability.

---

Copyright © 2025 jaggz.h {who is at} gmail.com. All rights reserved. See LICENSE.
