# 🧠 `z` – A Fast, Flexible, Perl-Powered CLI for Local LLMs

Forget Python bloat. `z` is a lightweight, blazing-fast CLI wrapper for interacting with LLMs over a local `llama.cpp` HTTP server. Built in Perl for speed, sanity, and simplicity — with features that rival most Python agent toolkits.

## ⚡ Why Perl?

Because startup time matters:

```text
bash -c loop, of 1000 executions:

bash:    1.70s
perl:    3.07s
python: 25.38s
```

This CLI is built to feel **instant**, even when calling local models 1000 times in a row. No interpreter bloat, no overhead, just results.

---

## 🧰 Features

✅ Fast, JIT-style prompt rendering  
✅ Structured templates per model (DeepSeek, Qwen2, Gemma, LLaMA, Phi-4, etc.)  
✅ Token-aware history with pruning  
✅ Reasoning toggle (`--think`) with live streaming  
✅ On-the-fly template detection by model name  
✅ Image support for multimodal models  
✅ Persona support with per-task system prompts  
✅ Full token dumps, top-K probabilities, grammar constraint support  
✅ Clipboard integration, file-backed history, dry-run inspect mode  
✅ Bash-style REPL usability with insane ergonomics

---

## 📦 Files

- `bin/z` – The CLI script. Your LLM interface.
- `configs/z-llm.json` – The config: model matching rules, prompt templates, and task specs.
- `~/.config/z-llm.json` – Auto-loaded config file (you can symlink or override it).
- `persona` (optional) – If installed, pulls persona files for task-specific system prompts.
- I've only used this with llama.cpp's `llama-server`

---

## 🚀 Basic Usage

```bash
# Fast queries:
z "What's the capital of France?"

# Piped in:
echo "and Romania?" | z -

# Ignore history for a one-time llm call:
echo "How do I write a hello world perl script?" | z - -H

# Continue with the capitals history:
z "and Brazil?"
```

With a task:

```bash
z -t haiku "Code is complex; make it serene."
```

Streaming output with full reasoning-model output shown:

```bash
z --think "Plan how to rename a folder across OSes"
```

List available task types:

```bash
z -L
```

---

## 🧠 Prompt Templates

Each model uses a template defined in `configs/z-llm.json`, matched via regex. Example for DeepSeek Coder:

```json
{
  "inst": "<｜User｜><: $user :>",
  "resp": "<｜Assistant｜><: $response :><｜end▁of▁sentence｜>",
  "main": "<｜begin▁of▁sentence｜><: $system :><: $history :><｜Assistant｜><think>",
  "rm_re": "(?:<think>)?.*</think>\\s*"
}
```

This template engine allows history injection, if you're into that, as well as reasoning cleanup, and dynamic task prompts.

---

## 🧪 General benchmarks (not of `z`).. just between perl and python:

```text
perl -e 'say "Hello World"' x 1000:     3.07s
python -c 'print("Hello World")' x 1000: 25.38s
```

Streaming LLMs 1000 times?  
You’ll feel that 22-second gap real quick. Perl keeps your tooling **hot**.

---

## 🧩 Extending

- Add new models to `models` in `z-llm.json` with regex matches. If your models use the same template, the regex is sufficient for `z` to choose the right template.
- Define per-model prompt templates in `templates`
- Create task definitions in `tasks`, or use a `persona` tool to load dynamic ones

---

## 📎 Clipboard + Images

Input from clipboard:
```bash
z --cb
```

Attach images: (This currently is not tested except with qwen vl)
```bash
z --img path/to/img.png "Describe this chart"
```

Supports formats like Qwen2 and Gemma 3 (not really; Gemma3 isn't supported in my llama.cpp as of the time of this writing).

---

## 🧠 Memory & History

History is stored in:
```
/tmp/llamachat_history-<user>_<task>.json
```

You can:

- `--wipe` it
- `--no-history` to disable
- `--input-only` to use but not update
- `--edit-hist` to open in `vim`

---

## 🤖 Task Customization

Tasks define system prompts (and optional grammars):

```json
"utils": {
  "system": "You are an AI command generator...",
  "grammar": "root ::= \"units \" anything\nanything ::= char*\nchar ::= [ -~]"
}
```

---

## 🎛 Flags Galore

| Flag              | Description                            |
|-------------------|----------------------------------------|
| `--think`         | Show model's internal reasoning        |
| `--ctx`           | Get model context length               |
| `--metadata`      | Print model metadata from API          |
| `--tokens_full`   | Dump token info for input              |
| `--clipboard`     | Use clipboard content as prompt        |
| `--dry_run`       | Show the prompt, don’t send it         |
| `--play_resp`     | Speak output via `vpi`                 |
| `--grammar`       | Attach a grammar to constrain output   |

…and dozens more. Run `z --help` to explore.

---

## 🧠 Philosophy

This tool isn’t trying to be a new framework. It’s built for:
- **Speed**
- **Transparency**
- **Convenience**
- **Power users**
- **Those who want to make LLMs feel like Unix commands**

No hidden Python. No megabytes of dependency hell. Just you, a prompt, and raw model power.

---

## 🛠️ Installation

Clone it:

```bash
git clone https://github.com/jaggzh/z
cd z-llm
```

Set up your `~/.config/z-llm.json` from the example.

Make `bin/z` executable:

```bash
chmod +x bin/z
```

Add to your `PATH`, or to a dir in your path, or symlink to `/usr/local/bin/z`.

---

## 💬 Want Help?

- Me too. Submit a PR. :)
- But seriously, I'm happy to answer questions when I can.

Ping me, open an issue, or just say hi in the repo! It's unlikely I'll be handling many coding requests however.

---

GPL3 licensed. Built with love for perl's dependency stability, and a love for fast shells.
