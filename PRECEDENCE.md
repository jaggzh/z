# Configuration Precedence System

**Warning:** This whole project is a rewrite of my `z` script as a full module *and* script. **I don't guarantee anything.**

ZChat uses a sophisticated precedence system that allows settings to override each other in a predictable, intuitive way while providing separate storage scopes for different use cases.

## Loading Precedence Chain

Configuration values are resolved in this order (later values override earlier ones):

```
System Defaults → User Global → Session Specific → CLI Runtime
```

## Terminology:

**Session / Session-name:** *Note:* You might see documents say 'project'
instead of 'session'. Internally they're called "session" or "session name",
but in practice you might use a session for storing settings for a project --
try not to be confused by mixed terminology.  For example, you might make a
session `-n my-project` or you might use it for a hierarchy, like `-n
my-project/docs`, where you have a system prompt set for working on your
documentation, or `-n my-project/coding`, or `-n my-project/runtime`. Maybe in
the last one your project, when running, stores its own system prompt, and
maybe pins messages, etc.

**Each of those sessions is considered unique and even maintains its own
conversation history.**

### Source of System-Prompt - Precedence

At each scope (system → user → session → CLI), ZChat selects **one** system-prompt source:

- If multiple system-prompt sources exist at the **same scope**, the intra-scope priority is:
  1) `system_file`
  2) `system_str` (literal string)
  3) `system_persona`
  4) `system` (auto-resolve by name: file first, then persona)
- A higher scope completely replaces lower scopes. No fallback to a lower scope if the chosen source fails to resolve; failure is **an error**.

**Practical flow:** you can set a user-default system string or file (with `--su`), then for a particular session store a different file or string (with `--ss`). CLI flags for the current run override everything.

### Example: Storing and Using a Session System Prompt

You can use `z --su --system-str "You are a helpful AI assistant"` to set a user-global default.

Then create/select a session:
```
z --su -n my-agent
```
Now, store a session-specific prompt:
```
z --system-str "You are an unhelpful AI assistant" --ss
```
Because the session `my-agent` is your default, a bare call:
```
z -- "Help me with my coding."
````
will use the **session** system prompt (the "unhelpful AI assistant" one) rather than the user default.

## **Defaults Priority (Precedence):** Let's get into the nitty-gritty...

### 1. System Defaults
**Location**: Hard-coded in `ZChat::Config::_get_system_defaults()`
**Purpose**: Sensible fallbacks that generally always work
**Examples**:
- `session: ''`
- `pin_limits: { system: 50, user: 50, assistant: 50 }`

### 2. User Global Config
**Location**: `~/.config/zchat/user.yaml`
**Purpose**: User's personal preferences that apply across all sessions
**Typical contents**:
```yaml
session: "work/current-project"
system_str: "Welcome to my world"   # or system_file: "/abs/or/relative/path"
# or system_persona: "my-favorite"
````

### 3. Session Specific Config

**Location**: `~/.config/zchat/sessions/{session_name}/session.yaml`
**Purpose**: Settings specific to a particular session/context
**Typical contents**: Again, note that a higher-precedence system prompt overrides earlier, regardless of whether it was a stored string or a path (--system-file)

```yaml
created: 1703123456
system_file: "/path/to/session-specific-prompt.md"
# or:
# system_str: "Focus on Python best practices"
# or:
# system_persona: "api-reviewer"
```

### 4. CLI Runtime

**Source**: Command-line flags like `-n`, `--system-file`, `--system-str`, `--system-persona`, `--system`
**Purpose**: Immediate overrides for current execution only
**Behavior**: Never persisted automatically

## Saving Logic

ZChat provides two storage scopes, providing explicit control over where settings are saved upon saving.

**WARNING:** `--ss` never changes your *default session*. To make a session the
default for future runs, you must use `--su -n session_name`.

### `--store-user` (alias `-S` or `--su`)

Stores settings in your user-account's **global config**. They apply
everywhere unless overridden by a session or CLI.

### `--store-session` (alias `--ss`)

Saves settings to **current session config**. The setting applies **only
when using this specific session.**

## Storage Destination Logic

The key insight: **which CLI flags are present with the storage flag determines the scope**.

### User Global Storage (`--su` / `-S`): (I use `-S` usually, but `--su` is more clear for this doc)

```bash
z --system-file prompts/base.md --su
z --system-str  "Be terse"       --su
z --system-persona architect     --su
z -n project/backend             --su     # store default session
```

### Session-Specific Storage (`--ss`)

```bash
z -n project/api --system-file prompts/api.md --ss
z --system-str "Prefer REST; avoid RPC"    --ss
z --system-persona api-reviewer            --ss
```

The presence of `-n session_name` with `--su` determines whether session name gets stored globally vs just used for current run.

## Resolution Examples

### Example 1: Basic System-Prompt Source Precedence

**User config**:

```yaml
system_str: "Welcome to my world"
```

**Session config**:

```yaml
system_file: "prompts/api.md"
```

**CLI**: (none)

**Result**:

* **System source**: session `system_file` (wins over user `system_str`)
* **Debug**:

  ```
  Selected system source: SESSION system_file=prompts/api.md
  Resolved system_file => /home/you/.config/zchat/sessions/work/project/prompts/api.md
  ```

### Example 2: Session Defaulting

**User config**:

```yaml
session: "work/main"
```

**CLI**: No `-n` (ie. we didn't override the session)

**Result**: Loads `work/main` session automatically.

### Example 3: Overrides Taking Over (CLI wins)

**User config**:

```yaml
system_persona: helpful
```

**Session config**:

```yaml
system_file: "prompts/coding.md"
```

**CLI**:

```bash
z --system-file ./prompts/debugging.md -n work/project
```

**Resolution (final effective config)**:

* **Session name**: `work/project` (from CLI `-n`)
* **System source**: CLI `system_file=./prompts/debugging.md` (wins over session file and user persona)
* **Debug**:

  ```
  Selected system source: CLI system_file=./prompts/debugging.md
  Resolved system_file => /abs/path/prompts/debugging.md
  Final system content length: 1234
  ```

## Common Workflows

### Setting User Defaults

```bash
# Make a user-global file prompt the default everywhere
z --system-file ~/.config/zchat/prompts/helpful.md --su

# Make "work/current" your default session
z -n work/current --su

# Set both as defaults
z --system-persona architect -n work/current --su
```

### Project-Specific Setup

```bash
# Set up a new session with a specific file prompt
z -n project/api --system-file prompts/api.md --ss

# Later, just use the session
z -n project/api "How do I handle errors?"
# Uses prompts/api.md automatically
```

### Temporary Overrides

```bash
# Override prompt just for this query
z -n project/api --system-str "Be concise; prefer examples" "Why is this failing?"
# Uses the string prompt but doesn't save it
```

### Session Switching

```bash
# Switch between contexts
z -n work/frontend  "I have a React question"   # Uses 'frontend' session for query
z -n work/backend   "Need database design help" # Uses 'backend' session
z -n personal/learn "Explain concepts xyz"      # Uses 'learning' session
```

## Storage File Locations

### User Global

```
~/.config/zchat/user.yaml
```

Contains settings that apply to all sessions unless overridden.

### Session Specific

```
~/.config/zchat/sessions/{session_path}/session.yaml
```

Session paths support hierarchy: `work/project1`, `personal/learning`, etc.

## Advanced Patterns

### Temporary Project Work

```bash
# Work on an urgent bug without changing defaults
z -n urgent/hotfix --system-str "Focus on quick diagnosis"
z -n urgent/hotfix "Check memory leaks"
z -n urgent/hotfix "Performance profiling"
# No changes persisted unless you add --ss/--su
```

### Pinning (*also see `help/pins.md` which you can display with `--help-pins`*)

`pin_shims` and `pin_sys_mode` follow the same precedence chain:
System Defaults → User Global → Session Specific → CLI

### Global vs Session Sources

```bash
# Use the same user-global file everywhere (unless you override it with a session or CLI)
z --system-file ~/.config/zchat/prompts/helpful.md --su

# Customize per-session prompts (save them to the session):
z -n session/api       --system-str  "Focus on REST API design" --ss
z -n session/frontend  --system-file prompts/frontend.md        --ss

# This bare call uses whichever session is your default
z -- "This is my query"

# Make session/frontend your default session
z -n session/frontend --su

z -- "This is my query"   # Now uses session/frontend’s prompt
```

**Note:** `--ss` stores the prompt **in the session settings** but does **not** make that session your default. Use `--su -n <session>` to change your default session.

## Design Rationale

### Why This Precedence Order?

1. **System defaults**: Ensure system always works
2. **User global**: Personal preferences should generally apply. This lets you go about using `z` or the `ZChat` module without other setup; for example, you just leave your user-stored system prompt as a generic "You are a helpful AI assistant." (It can be set to come from a file, string, or persona)
3. **Session specific**: Session needs override personal preferences. This is important so different projects and runs can quickly use a separate conversation history, set their own system-prompts, (AND, for those rare cases, even pin their own content.) They can effectively serve as unique chat histories, but let you store other persistent settings as well.
4. **CLI runtime**: Immediate need overrides everything, but temporarily

### Why Explicit Storage Commands?

* **Predictable**: You explicitly choose where settings are saved
* **Flexible**: Save to user global or session scope as needed
* **Safe**: No accidental overwrites of carefully configured setups

### Why Session Name Resolution?

The session name itself follows the precedence chain:

1. CLI `-n session_name` (immediate override; either one-time (but the chat history will be saved to disk), or you can use --su to make it persist until you change it).
2. Constructor `session => 'name'` (programmatic use)
3. User config `session: 'name'` (personal default)
4. System default `'default'` (fallback)

This allows workflows like:

```bash
z -n work/urgent -S      # Sets work/urgent as your default session
z "What should I do?"    # Uses work/urgent automatically from now on
```

## Debugging Configuration

Use multiple `-v` flags to see precedence resolution:

```bash
z --system-file prompts/coding.md -n session -vv "test"
```

Output should show the **source and kind** selected:

```
Using session 'session'
Selected system source: SESSION system_file=prompts/coding.md
Resolved system_file => /home/you/.config/zchat/sessions/session/prompts/coding.md
Final system content length: 2148
```

This reveals exactly which settings came from where and in what order they were applied.
