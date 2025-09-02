# Configuration Precedence System

ZChat uses a sophisticated precedence system that allows settings to override each other in a predictable, intuitive way while providing separate storage scopes for different use cases.

## Loading Precedence Chain

Configuration values are resolved in this order (later values override earlier ones):

```
System Defaults → User Global → Session Specific → CLI Runtime
```

### 1. System Defaults
**Location**: Hard-coded in `ZChat::Config::_get_system_defaults()`
**Purpose**: Sensible fallbacks that always work
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
**Purpose**: Settings specific to a particular project/context
**Typical contents**:
```yaml
preset: "coding-assistant"
created: 1703123456
system_prompt: "Focus on Python best practices"
system_file: "/path/to/project-specific-prompt.txt"
```

### 4. CLI Runtime
**Source**: Command-line flags like `-p`, `-n`, `--system`
**Purpose**: Immediate overrides for current execution only
**Behavior**: Never persisted automatically

## Saving Logic

ZChat provides two storage scopes with explicit control over where settings are saved:

### `--store-user` (alias `-S`)
Saves settings to **user global config**. The setting becomes your personal default across all sessions unless overridden.

### `--store-session` (alias `--ss`)
Saves settings to **current session config**. The setting applies only when using this specific session.

## Storage Destination Logic

The key insight: **which CLI flags are present with the storage flag determines the scope**.

### User Global Storage (`-S`)
```bash
z -p coding -S                    # coding preset becomes user global default
z -n project/backend -S           # project/backend becomes user's default session
z -p coding -n project/api -S     # BOTH become user global defaults
```

### Session-Specific Storage (`--ss`)
```bash
z -n project/api -p coding --ss   # coding preset stored in project/api session
z -p debugging --ss               # debugging preset stored in current session
```

The presence of `-n session_name` with `-S` determines whether session name gets stored globally vs just used for current run.

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

### Example 3: Mixed Overrides
**System**: `preset: "default"`
**User**: `preset: "helpful", session: "work/project"`
**Session work/project**: `preset: "coding"`
**CLI**: `-p debugging -n work/project`

**Resolution**:
- Session: `work/project` (from CLI `-n`)
- Preset: `debugging` (from CLI `-p`)
- Other settings: Inherited from session config, then user config, then system defaults

## Common Workflows

### Setting User Defaults
```bash
# Make "helpful" your default preset everywhere
z -p helpful -S

# Make "work/current" your default session
z -n work/current -S

# Set both as defaults
z -p helpful -n work/current -S
```

### Project-Specific Setup
```bash
# Set up a new project with specific preset
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

### Global Preset, Session-Specific Prompts
```bash
# Use same preset everywhere but customize system prompts per project
z -p helpful -S                                    # Global preset
z -n project/api --system "Focus on REST API design" --ss
z -n project/frontend --system "Focus on React patterns" --ss
```

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
z -p coding -n project -vv "test"
```

Output shows:
```
Setting preset 'default' from system defaults
Setting preset 'helpful' from user config  
Setting preset 'coding-assistant' from session config
Setting preset 'coding' from CLI options
Using session 'project'
```

This reveals exactly which settings came from where and in what order they were applied.