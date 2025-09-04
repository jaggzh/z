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

### Example: System Prompt and File Precedence

At each scope (system → user → session → CLI), only one of `system_prompt` or `system_file` is honored:
- If both exist at the same scope, `system_file` takes priority.
- Higher scopes completely replace lower ones—no concatenation occurs.

**Say what?** It means we have our system defaults so `z` / `ZChat` works without
any config. But you can then use `z --su --system "You are a helpful AI assistant"`
and now that is your default.

*...and then...*, when you make a "session-name",
like `z --su -n my-agent`, you've now stored (--su) that "session-name"
('my-agent') as your default for future calls to `z` (or the API).

So, **because 'my-agent'** is now active for your user account, if you
call `z --system "You are an unhelpful AI assistant" --ss` (option order doesn't matter),
that system prompt will be stored in the `my-agent` session file,
AND because that session-name is your default, your next call to `z` will use it.

So if you now type: `z -- "Help me with my coding."`, this unhelpful agent might not help you.

## **Defaults Priority (Precedence):** Let's get into the nitty-gritty...

### 1. System Defaults
**Location**: Hard-coded in `ZChat::Config::_get_system_defaults()`
**Purpose**: Sensible fallbacks that generally always work
**Examples**:
- `preset: 'default'`
- `session: ''`
- `pin_limits: { system: 50, user: 50, assistant: 50 }`

### 2. User Global Config
**Location**: `~/.config/zchat/user.yaml`
**Purpose**: User's personal preferences that apply across all sessions
**Typical contents**:
```yaml
preset: "helpful"
session: "work/current-project"
```

### 3. Session Specific Config
**Location**: `~/.config/zchat/sessions/{session_name}/session.yaml`
**Purpose**: Settings specific to a particular session/context
**Typical contents**: Note that a higher-precedence system prompt overrides earlier, regardless of whether it was a stored string or a path (--system-file)
```yaml
preset: "coding-assistant"
created: 1703123456
system_prompt: "Focus on Python best practices"
```
  **or**
```yaml
system_file: "/path/to/session-specific-prompt.txt"
```

### 4. CLI Runtime
**Source**: Command-line flags like `-p`, `-n`, `--system`
**Purpose**: Immediate overrides for current execution only
**Behavior**: Never persisted automatically

## Saving Logic

ZChat provides two storage scopes, providing explicit control over where settings are saved upon saving.

WARNING: `--ss` never changes your *default session*. To make a session the
default for future runs, you must use `--su -n session_name`.

### `--store-user` (alias `-S` or `--su`)
This stores settings in your user-account's **global config**. They apply
everywhere unless overridden by a session or CLI.

### `--store-session` (alias `--ss`)
This saves settings to **current session config**. The setting applies **only
when using this specific session.**

## Storage Destination Logic

The key insight: **which CLI flags are present with the storage flag determines the scope**.

### User Global Storage (`--su` / `-S`): (I use `-S` usually, but `--su` is more clear for this doc)
```bash
z -p coding --su                  # coding preset becomes user global default
  # (Note: 'coding' must be a stored file preset or, if you are using my `persona`
  # CLI tool to manage system prompts, it will check with `persona` as well)
z -n project/backend --su         # project/backend becomes user's default session
z -p coding -n project/api --su   # BOTH become user global defaults
```

### Session-Specific Storage (`--ss`)
```bash
z -n project/api -p coding --ss   # coding preset stored in project/api session
z -p debugging --ss               # debugging preset stored in current session
```

The presence of `-n session_name` with `--su` determines whether session name gets stored globally vs just used for current run.

## Resolution Examples

### Example 1: Basic Precedence
**User config**: `preset: "helpful"`
**Session config**: `preset: "coding"`  
**CLI**: `-p debugging`

**Result**: `preset: "debugging"` (CLI wins, but not saved)

### Example 2: Session Defaulting
**User config**: `session: "work/main"`
**CLI**: No `-n` flag

**Result**: Loads `work/main` session automatically

### Example 3: Overrides taking over

You might be using a session, but in it you didn't set something (like a preset),
so the session has its own conversation history and pins, but your system prompt
comes from your preset.

Here's an example showing the results of settings percolating through:

**System defaults**: The default system prompt and storage comes from here.
```yaml
preset: "default"
````

**User config (`~/.config/zchat/user.yaml`)**: EXCEPT, you set a preset and a session in your user settings (with --su). So now your preset is always "helpful" (some file you created as a system prompt or a `persona`-CLI system prompt). And you also stored your session name ("work/project") as default for your user, so it can override things if you store settings in it (e.g. with `--ss`).

```yaml
preset: "helpful"
session: "work/project"
```

**Session config (`~/.config/zchat/sessions/work/project/session.yaml`)**: Looks like you overrode all prior presets in your session.

```yaml
preset: "coding"
```

**CLI invocation**: Well, this final one-time run overrode your preset *and* [unnecessarily] set 'work/project' as your session. BUT, note that your CLI use of `-p debugging` overrides what's in the session `work/project`.

```bash
z -p debugging -n work/project
```

---

**Resolution (final effective config)**:

* **Session name**: `work/project`
  → From CLI `-n`, which overrides user default (`work/project`) and system default (empty).
* **Preset**: `debugging`
  → From CLI `-p`, which overrides session preset (`coding`), which overrides user preset (`helpful`), which overrides system default (`default`).
* **Other settings**:
  → Taken from the session config (`work/project`), falling back to user config, then system defaults if not defined.

---

**Debug output (with `-vv`) would show**:

```
Setting preset 'default' from system defaults
Setting preset 'helpful' from user config
Using session 'work/project' (from CLI -n)
Setting preset 'coding' from session config
Setting preset 'debugging' from CLI options
```

**Key takeaway**:
CLI always wins for the current run, session config overrides user config, and user config overrides system defaults.

```

---

Want me to extend this example to also show what happens if both `system_prompt` and `system_file` are set at different levels (so the precedence is explicit for prompts too)?
```










## Common Workflows

### Setting User Defaults
```bash
# Make "helpful" your default preset everywhere
z -p helpful --su

# Make "work/current" your default session
z -n work/current --su

# Set both as defaults
z -p helpful -n work/current --su
```

### Project-Specific Setup
```bash
# Set up a new session with specific preset
z -n project/api -p rest-coding --ss

# Later, just use the session
z -n project/api "How do I handle errors?"
# Uses rest-coding preset automatically
```

### Temporary Overrides
```bash
# Override preset just for this query
z -n project/api -p debugging "Why is this failing?"
# Uses debugging preset but doesn't save it
```

### Session Switching
```bash
# Switch between contexts
z -n work/frontend "React question"        # Uses frontend session
z -n work/backend "Database design help"   # Uses backend session  
z -n personal/learning "Explain concepts"  # Uses learning session
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
# Work on urgent bug without changing defaults
z -n urgent/hotfix -p debugging
z -n urgent/hotfix "Check memory leaks"
z -n urgent/hotfix "Performance profiling"
# When done, return to normal workflow without any saved state
```

### Context Switching with Presets
```bash
# Set up different contexts
z -n reviews/backend -p senior-engineer --ss
z -n reviews/frontend -p ui-specialist --ss  
z -n planning/architecture -p system-designer --ss

# Switch contexts instantly
z -n reviews/backend "Review this auth code"
z -n planning/architecture "Design user service"
```

### Pinning (*also see `help/pins.md` which you can display with `--help-pins`)
`pin_shims` and `pin_sys_mode` follow the same precedence chain:
System Defaults → User Global → Session Specific → CLI

### Global Preset, Session-Specific Prompts, and CLI
```bash
# Use same preset everywhere but customize system prompts per session
z -p helpful --su  # Global (user-account) preset

                   # Session-stored system prompt overrides user-default
z -n session/api --system "Focus on REST API design" --ss

                   # Same, but stored (--ss) in session `session/frontend`
                   # It will be used, without --system being specified,
                   # **ONLY while `session/frontend` is used**
z -n session/frontend --system "Focus on React patterns" --ss

                   # This uses the preset `helpful`!!! See **'WARNING'** below
z -- "query" 

                   # Store session/frontend as your user-global,
                   # so it will be your default
z -n session/frontend --su

z -- "query"       # This now *does* use session `session/frontend`
```

**WARNING: There's something unintuitive here:**

In the last examples above, `--ss` stored your system prompt *in your
session settings*, but it did not set the session name (`session/frontend`)
as your default when running `z`.

**Until `--su` was used with `-n something` on the line, whatever the
current global session is set to will be used. In this case, you might
not have it set at all, and the `helpful` preset (system prompt) will be
active.

I am not sure if we should change this functionality but for now, **if you want
to set your session (-n) as your default for the next call use `--su`**.  (Note
that order does not matter, so `--su -n prj` is the same as `-n prj --su`, (and
both will have made `prj` your default session name for a run without arguments
overriding it.

## Design Rationale

### Why This Precedence Order?
1. **System defaults**: Ensure system always works
2. **User global**: Personal preferences should generally apply
3. **Session specific**: Project needs override personal preferences  
4. **CLI runtime**: Immediate need overrides everything, but temporarily

### Why Explicit Storage Commands?
- **Predictable**: User explicitly chooses where settings are saved
- **Flexible**: Can save to user global or session scope as needed
- **Safe**: No accidental overwrites of carefully configured setups

### Why Session Name Resolution?
The session name itself follows the precedence chain:
1. CLI `-n session_name` (immediate override)
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
z -p coding -n session -vv "test"
```

Output *should* show one of:
```
Setting preset 'default' from system defaults
Setting preset 'helpful' from user config  
Setting preset 'coding-assistant' from session config
Setting preset 'coding' from CLI options
Using session 'session'
```

This reveals exactly which settings came from where, although I can't guarantee it.
