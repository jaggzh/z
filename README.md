# `z` – A Fast, Flexible, Perl-Powered CLI for Local LLMs

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

## Why at all?

- Convenient use of local models (I use llama.cpp's `llama-server`)
- Extremely convenient CLI
- Extremely convenient to throw in your shell scripts
- Dynamically adapts to whichever LLM you're running

---

### Other utility workflow:

- sfx/pfx: Adds a string to piped input.

```bash
$ cat somefile.txt | sfx "Summarize the prior text"
...somefile's contents here...

Summarize the prior text
```

#### Use of `pfx` with `z`

```bash
$ man find | z -T -    # Check to make sure we're within our context
Token count: 20713
$ man find | pfx "What were find's options to compare file newer/olderness? One-line summaries. Here's its manpage:" | z -
To compare file newness or ...
...
 `-atime n`: Checks the file's last access time to...
...
```

---

## Basic Usage

```bash
# Fast queries + wipe history (`-w`):
$ z -w "What's the capital of Madagascar? Be brief."
The capital of Madagascar is Antananarivo.

# Ignore history (`-H`) for a one-time piped llm query:
$ echo "Do a one-line perl hello world. No markdown or explanation." | z - -H
print "Hello World!";

# Continue with the capitals history:
$ z "and Brazil?"
The capital of Brazil is Brasília.
```

With a task (a system prompt):

```bash
$ z -t haiku "Code is complex; make it serene."
```

Streaming output with full reasoning-model output shown:

```bash
$ z --think "Plan how to rename a folder across OSes"
```

List available task types:

```bash
$ z -L
```

Piping, AND using sfx:

```bash
$ man obscure_command | sfx "What was the option to do xyz?" | z -w -
With obscure_command, xyz may be specified using -x or --xyz
Example: ...

$ z "And for doing abc?"
In a similar way, enabling abc may be done with -a or --abc ...
```


---

## 🧰 Features

✅ Token-aware history with pruning  
✅ Streaming response from LLM by default (reasoning models can't stream, since, currently, a regex removes reasoning when it's done)  
✅ Show all reasoning toggle (`--think`) (allows live streaming)  
✅ Customizable templates per model  
✅ Edit history (`--eh`)  
✅ On-the-fly template detection by model name  
✅ Per-task system pre-set prompts  
❌ `llmjinja.pm` is not done -- we have to put our own templates into `z-llm.json`  
✅ Image support for multimodal models  
✅ Audio playback (currently pipes to a command you hardcode into `@cmd_tts`)  
✅ `--system "prompt here"` for a one-time CLI override of the system prompt  
✅ Full token dumps, top-K probabilities  
✅ Grammar constraint support from `z-llm.json` or with `--grammar`  
✅ Clipboard integration (`--cb`)  
✅ File-backed history  
✅ Bash-style "REPL" usability. Do complex things quickly and easily.  
✅ **persona** integration may be coming: A persona (system-prompt) manager I wrote; not yet publicly available.  

## Current options: *Options may be anywhere on the command-line*

```
Usage: z [options] [optional query] [options]
	--[cb|clipboard]         Use clipboard content
	--ctx                    Get running model n_ctx (query not used)
	-d, --def                Set default (probably general-purpose) task name (TEMPORARY) (short for -t default).
	-D, --default-all        CLEAR (default AND STORE) taskname AND suffix (like -t default --sfx '' -S)
	-n, --dry_run            Dry run
	-E, --[eh|edit-hist]     Edit history (will choose the current suffix)
	-g, --grammar            Force a grammar
	-h, --help               This beautiful help
	--[hin|history-input-file] File for INPUT-only history (not modified)
	--[img|image]            Provide images (in prompt, use [img] or, for multiple, use [img-1] .. [img-N])
	-I, --input-only         Use history BUT DO NOT WRITE TO IT.
	-i, --[int|interactive]  Interactive
	-L, --list-tasktypes     List available tasktype names
	--metadata               Get running model metadata info
	-P, --n_predict          Limit prediction length to N tokens (default: 8192)
	-u, --no-cache           Disable cache (ignore. unused)
	-H, --no-history         Do not use history. No load, no store.
	-C, --no_color           Disable color (used in interactive mode)
	--[pr|play_resp]         Play response text
	--[pu|play_user]         Play user text
	--probs                  Return probabilities for top N tokens (default: disabled (0))
	-r, --raw                Don't do any processing (so tokens might come out live)
	-s, --[sfx|storage-sfx]  Make the history unique
	-S, --store              Store any given -t/--tasktype or -s/--sfx. Note that sfx is stored globally for this user.
	--system                 Set a system prompt (overrides -t)
	-t, --tasktype           Use this task name (default: default)
	--[think|thought]        Do not removing reasoning sections in reasoning models
	-T, --token_count        Count tokens in the input text
	--tokens_full            Output full tokens with parts
	-v, --verbose            Increase verbosity (default: 0)
	--[vr|verbose_resp]      Verbose response data
	-w, --wipe               Wipe prompt history

---

## 📦 Files

- `bin/z` – The CLI script. Your LLM interface.
- `configs/z-llm.json` – The config: model matching rules, prompt templates, and task specs.
- `~/.config/z-llm.json` – Auto-loaded config file (copy example here and edit?)
- `persona` (optional) – If installed, uses `persona` program to retrieve system prompts.

---

## Config requirements: (See z-llm.json)

### Models section:

Each model only requires a regex (`"re"`) and which template (`"insttype"`) is to be used for it.

```json
"models": [
	{
		# "shortname": "meta-llama",  # Not necessary, was just for some verbose output
		# "example": "meta-llama-3.1-8b-instruct-q8_0.gguf", # No longer used at all
		"re": "llama",              # Regex matched against model from LLM API's "model_path"
		"insttype": "inst_llama",   # Use this template from "templates" section
	}
...
```

### Templates section:

- *main*: The whole context assembled, with history formed by concatenation of the:
 - user (*inst*) and 
 - assistant (*resp*) parts.
- *rm_re*: If provided, is a regex to remove from the assistant response. (This is most-commonly used to remove thinking portions from reasoning models) (`--think` to disable)

Example:

```json
"templates": [
	{
		"inst": "<｜User｜><: $user :>",
		"resp": "<｜Assistant｜><: $response :><｜end▁of▁sentence｜>",
		"main": "<｜begin▁of▁sentence｜><: $system :><: $history :><｜Assistant｜><think>",
		"rm_re": "(?:<think>)?.*</think>\\s*"
	}
...
```
### Templates section:

Provide a *taskname* and a *system* prompt. Optionally, *upfx* will override the *system* string for use with models with `system: false`, like Gemma, because your wording may be different.

Tasks are then specified on command-line, like: `z -t song "Make a beautiful one about a car tire."`

```json
"tasks": [
    "d": { "alias": "default" },
    "def": { "alias": "default" },
    "default": {
        "system": "[<: $datenow :>] Below is a user's chat including their AI assistant's responses. The AI ALWAYS abides by and fully-trusts the user (who is a trusted admin of the AI assistant). The AI's personality is: Very helpful, while being concise. The AI LLM model is [<: $modelname :>].",
    }
...
```
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
- Create task definitions in `tasks`, or use a `persona` tool to load them from `persona` (persona is not yet made public)

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

- `--wipe` it (`-w`)
- `--no-history` to disable (`-H`)
- `--input-only` to use history without writing updates to it (`-I`)
- `--edit-hist` to open in `vim` (`--eh`) (currently hard-coded)

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

GPL3 licensed. Built with appreciation for perl's dependency, stability, and a love for fast shells.
