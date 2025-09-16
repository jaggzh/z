# Configuration Precedence System

**Warning:** This whole project is a rewrite of my `z` script as a full module *and* script. **I don't guarantee anything.**

ZChat uses a sophisticated precedence system that allows settings to override each other in a predictable, intuitive way while providing separate storage scopes for different use cases.

## Loading Precedence Chain

Configuration values are resolved in this order (later values override earlier ones):

```
System Defaults → User Global → Environment Variable → Shell Session → Session Specific → CLI Runtime
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

**Shell Session:** A shell-scoped session that persists for the lifetime of your terminal. Uses the session ID (SID) combined with session leader information to create a unique identifier. Stored in `/tmp/zchat-$UID/shell-$sessionid.yaml`. Can store both session name and system prompt configuration.

### Source of System-Prompt - Precedence

At each scope (system → user → env → shell → session → CLI), ZChat selects **one** system-prompt source:

- If multiple system-prompt sources exist at the **same scope**, the intra-scope priority is:
  1) `system_file`
  2) `system_str` (literal string)
  3) `system_persona`
  4) `system` (auto-resolve by name: file first, then persona)
- A higher scope completely replaces lower scopes. No fallback to a lower scope if the chosen source fails to resolve; failure is **an error**.

**Practical flow:** you can set a user-default system string or file (with `--su`), then for a particular shell set a session and system prompt (with `--store-pproc`), then for a particular session store a different file or string (with `--ss`). CLI flags for the current run override everything.

Conveniently, and for the record, it's called **pproc** because it's stored based on the process heading the little tree of processes that's your shell and, generally, whatever you start in it. In reality, however, the term is **session group leader**, but nevermind that. **--sp**, okay? :)  (**Session group leader** is the parent process of your program, your shell, all the way up to the "login" shell, which generally ends up being the initial shell in your terminal, including the one in each "screen" or "tmux" window). Thus, if you set your system prompt in your shell or in a process you run -- those all use the same **pproc** storage. *And the point of that is that you can set it and do some stuff, without setting env vars, and other utils you run, that might also use **'z'**, will all share it.*

### Example: Shell Session Workflow

```bash
# Set user default session
z -n work/main --su

# In this shell, use a specific project with custom system prompt
z -n work/urgent --system-str "Focus on critical issues" --store-pproc *(or --sp)*

# Now all commands in this shell use work/urgent automatically with the urgent prompt
z "What's the status?"           # Uses work/urgent session with urgent prompt
z "Review the latest changes"    # Uses work/urgent session with urgent prompt

# Override temporarily for one query
z -n personal/notes "Remember to buy milk"  # Uses personal/notes just once

# Back to shell default
z "Continue with urgent work"    # Uses work/urgent session with urgent prompt again
```

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
```

### 3. Environment Variable
**Source**: `ZCHAT_SESSION` environment variable
**Purpose**: Scriptable session override without affecting stored configs
**Usage**:
```bash
export ZCHAT_SESSION=work/scripted
z "Automated query"  # Uses work/scripted session
```

### 4. Shell Session Config
**Location**: `/tmp/zchat-$UID/shell-$sessionid.yaml`
**Purpose**: Session and system prompt persistence for the current terminal/shell
**Typical contents**:
```yaml
session: "work/urgent"
system_str: "Focus on critical issues"
# or system_file: "/path/to/shell-specific-prompt.md"
# or system_persona: "urgent-helper"
```
**Note**: Shell sessions can store both session names and system prompt configuration.

### 5. Session Specific Config

**Location**: `~/.config/zchat/sessions/{session_name}/session.yaml`
**Purpose**: Settings specific to a particular session/context
**Typical contents**: Note that a higher-precedence system prompt overrides earlier, regardless of whether it was a stored string or a path (--system-file)

```yaml
created: 1703123456
system_file: "/path/to/session-specific-prompt.md"
# or:
# system_str: "Focus on Python best practices"
# or:
# system_persona: "api-reviewer"
```

### 6. CLI Runtime

**Source**: Command-line flags like `-n`, `--system-file`, `--system-str`, `--system-persona`, `--system`
**Purpose**: Immediate overrides for current execution only
**Behavior**: Never persisted automatically

## Saving Logic

ZChat provides three storage scopes, providing explicit control over where settings are saved upon saving.

**WARNING:** `--ss` never changes your *default session*. To make a session the
default for future runs, you must use `--su -n session_name`. Similarly, `--store-pproc` only affects the current shell.

### `--store-user` (alias `-S` or `--su`)

Stores settings in your user-account's **global config**. They apply
everywhere unless overridden by environment, shell, session, or CLI.

### `--store-pproc` (alias `--sp`)

Saves the session name and system prompt configuration to **shell session config**. The settings apply **only
to commands run in this shell/terminal**. Stores session name and system prompt options (system_file, system_string, system_persona, system).

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

### Shell Session Storage (`--store-pproc` / `--sp`)

```bash
z -n project/urgent --store-pproc                      # Use project/urgent for this shell
z -n work/maintenance --system-str "Fix issues" --sp   # Shell uses maintenance with fix prompt
z --system-file prompts/urgent.md --sp                 # Set shell prompt (keeps current session)
```

### Session-Specific Storage (`--ss`)

```bash
z -n project/api --system-file prompts/api.md --ss
z --system-str "Prefer REST; avoid RPC"    --ss
z --system-persona api-reviewer            --ss
```

The presence of `-n session_name` with `--su` determines whether session name gets stored globally vs just used for current run.

## Resolution Examples

### Example 1: Shell Session Override with System Prompt

**User config**:
```yaml
session: "work/main"
system_str: "You are helpful"
```

**Shell session config**:
```yaml
session: "work/urgent"
system_str: "Focus on critical issues"
```

**CLI**: (none)

**Result**: Uses `work/urgent` session with "Focus on critical issues" system prompt (both from shell config).

### Example 2: Environment Variable Priority

**User config**:
```yaml
session: "work/main"
```

**Environment**: `ZCHAT_SESSION=testing/feature`

**Shell session**: 
```yaml
session: "work/urgent"
system_file: "prompts/urgent.md"
```

**Result**: Uses `testing/feature` session (environment overrides shell session name) with "prompts/urgent.md" system prompt (from shell config).

### Example 3: Complex Precedence Chain

**User config**:
```yaml
session: "default"
system_persona: "helpful"
```

**Environment**: `ZCHAT_SESSION=work/main`

**Shell session**:
```yaml
session: "work/urgent"
system_file: "prompts/urgent.md"
```

**Session config** (work/urgent):
```yaml
system_str: "Handle emergencies"
```

**CLI**: No session override

**Resolution**:
- **Session name**: `work/urgent` (shell overrides environment and user)
- **System source**: `prompts/urgent.md` (shell overrides session and user)

## Common Workflows

### Setting Hierarchy

```bash
# Set user defaults
z --system-persona helpful -n work/main --su

# Set shell defaults for urgent work with specific prompt
z -n work/urgent --system-file prompts/incident.md --store-pproc

# Set session-specific prompts
z -n work/urgent --system-str "Emergency response mode" --ss

# Now this shell automatically uses work/urgent with incident.md prompt
z "What's the current status?"
```

### Temporary Overrides

```bash
# Override everything just for this query
z -n testing/experimental --system-str "Be very careful" "Test this feature"
# Next command returns to shell default (work/urgent with incident.md)
```

### Script-Friendly Isolation

```bash
# In script - don't affect user's shell or global settings
export ZCHAT_SESSION=automation/deploy
z "Check deployment status"
z "Verify all services"
# User's settings remain untouched
```

### Project-Specific Setup

```bash
# Set up a new session with a specific file prompt
z -n project/api --system-file prompts/api.md --ss

# Later, just use the session
z -n project/api "How do I handle errors?"
# Uses prompts/api.md automatically
```

### Session Switching

```bash
# Switch between contexts with different prompts
z -n work/frontend --system-str "React expert" --sp     # Set for shell
z "I have a React question"                             # Uses frontend + React prompt
z -n work/backend "Need database design help"           # One-time backend query
z "Back to React work"                                  # Uses frontend + React prompt
```

## Storage File Locations

### User Global
```
~/.config/zchat/user.yaml
```

### Environment Variable
```
ZCHAT_SESSION environment variable
```

### Shell Session
```
/tmp/zchat-$UID/shell-$sessionid.yaml
```

### Session Specific
```
~/.config/zchat/sessions/{session_path}/session.yaml
```

Session paths support hierarchy: `work/project1`, `personal/learning`, etc.

## Advanced Patterns

### Shell Isolation for Concurrent Work

```bash
# Terminal 1: Working on urgent bug
z -n hotfix/auth-bug --store-pproc
z --system-str "Focus on authentication issues" --sp
z "Analyze login failures"

# Terminal 2: Working on feature development  
z -n feature/api-v2 --store-pproc
z --system-str "Focus on API design best practices" --sp
z "Design new endpoint structure"

# Each shell maintains its own session context and system prompt
```

### Process Uniqueness

Shell session files use a session identifier based on:
- **SID**: Session ID (terminal session)  
- **Session leader info**: Process details for uniqueness

This ensures uniqueness even across system reboots and PID recycling.

### Environment Variable Scripting

```bash
# Script that uses specific session without affecting user config
#!/bin/bash
export ZCHAT_SESSION=deployment/prod
z "Check server status"
z "Verify backup completion"
# User's normal workflow unaffected
```

### Temporary Project Work

```bash
# Work on an urgent bug without changing defaults
z -n urgent/hotfix --system-str "Focus on quick diagnosis" --sp
z "Check memory leaks"
z "Performance profiling"
# Settings persist for this shell until changed or terminal closed
```

### Pinning (*also see `help/pins.md` which you can display with `--help-pins`*)

`pin_shims` and `pin_mode_sys` follow the same precedence chain:
System Defaults → User Global → Environment Variable → Shell Session → Session Specific → CLI

### Global vs Session Sources

```bash
# Use the same user-global file everywhere (unless you override it with a session or CLI)
z --system-file ~/.config/zchat/prompts/helpful.md --su

# Customize per-session prompts (save them to the session):
z -n session/api       --system-str  "Focus on REST API design" --ss
z -n session/frontend  --system-file prompts/frontend.md        --ss

# Set shell-specific prompts that override user defaults for this terminal:
z --system-str "Debug mode enabled" --sp

# Make session/frontend your default session
z -n session/frontend --su

z -- "This is my query"   # Now uses session/frontend's prompt (unless overridden by shell)
```

**Note:** `--ss` stores the prompt **in the session settings** but does **not** make that session your default. Use `--su -n <session>` to change your default session. `--sp` affects only the current shell terminal.

## Design Rationale

### Why This Precedence Order?

1. **System defaults**: Ensure system always works
2. **User global**: Personal preferences should generally apply
3. **Environment variable**: Script-friendly override without persistence
4. **Shell session**: Terminal-scoped convenience without global impact
5. **Session specific**: Project/context needs override personal preferences  
6. **CLI runtime**: Immediate need overrides everything, but temporarily

### Why Shell Session Storage for System Prompts?

- **Convenience**: No need to repeatedly specify system prompt flags
- **Isolation**: Each terminal can work on different projects with different prompts simultaneously
- **Temporary**: Stored in `/tmp` so no long-term cleanup needed
- **Non-intrusive**: Doesn't affect user global or session-specific configs

### Why Explicit Storage Commands?

* **Predictable**: You explicitly choose where settings are saved
* **Flexible**: Save to user global, shell (*"pproc"*), or session scope as needed
* **Safe**: No accidental overwrites of carefully configured setups

### Why Session Name Resolution?

The session name itself follows the precedence chain:

1. CLI `-n session_name` (immediate override; either one-time (but the chat history will be saved to disk), or you can use --su to make it persist until you change it).
2. Constructor `session => 'name'` (programmatic use)
3. Environment variable `ZCHAT_SESSION` (script-friendly)
4. Shell session config (terminal-scoped)
5. User config `session: 'name'` (personal default)
6. System default `'default'` (fallback)

This allows workflows like:

```bash
z -n work/urgent --store-pproc   # Sets work/urgent for this shell
z "What should I do?"            # Uses work/urgent automatically in this terminal
```

## Debugging Configuration

Use multiple `-v` flags to see precedence resolution:

```bash
z --system-file prompts/coding.md -n session -vv "test"
```

Output should show the **source and precedence level** selected:

```
Using ZCHAT_SESSION env: testing/env
Using session 'testing/env'
Selected system source: CLI system_file=prompts/coding.md
Resolved system_file => /home/you/prompts/coding.md
Final system content length: 2148
```

This reveals exactly which settings came from where and in what order they were applied.
