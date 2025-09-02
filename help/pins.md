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
