# Development Notes - ZChat Modularization

## Architecture Decisions

### Modular Separation Success
- **Before**: 1000+ line monolithic script with scattered logic
- **After**: Clean module separation with single responsibilities
- **Key**: `FindBin` + `use lib` allows distribution without CPAN installation
- **Pattern**: CLI convenience layer + clean programmatic API underneath

### Configuration Precedence Chain
```
System Defaults → User Global → Session Specific → CLI Runtime
```
- **Critical insight**: Each level can override previous, but CLI never persists
- **Storage logic**: `-S` destination determined by CLI flags present (elegant!)
- **Session defaulting**: Must happen in Config module, not scattered in CLI

## Major Perl Gotchas Discovered

### Hash Constructor Precedence ⚠️
```perl
# WRONG - comma binds tighter than ||
{ key => $opts{key} || die "required" }

# CORRECT - parenthesize the ||
{ key => ($opts{key} || die "required") }
```
**Impact**: Caused entire hash construction to fail silently

### eval{} Return Values Don't Propagate ⚠️
```perl
# WRONG - return inside eval doesn't work
eval { return $value; };  # Function continues, returns undef

# CORRECT - assign to variable inside eval
my $result;
eval { $result = $value; };
return $result;
```

### Use // Not || for Undefined Handling
```perl
# BETTER - handles undef vs empty string correctly  
$opts{value} // 'default'
```

## Storage Strategy Insights

### Separate Files for Separate Concerns
- `session.yaml` - Configuration only, no frequent rewrites
- `pins.yaml` - Separate so can be easily removed/managed  
- `history.json` - Lenient JSON parsing for user editing
- **Lesson**: Avoid "last_used" timestamps that dirty configs unnecessarily

### Session Hierarchy
- Slash-separated paths: `project/subproject/analysis`
- User controls organization, no forced project/session split
- Default session: `'default'` not empty string (empty fails storage checks)

## Pin System Design

### Hard-coded Message Ordering (Intentional)
1. System pins (always concat)
2. Assistant pins (concat) 
3. User pins (concat)
4. Individual assistant messages
5. Individual user messages
6. Conversation history (truncated)

**Rationale**: Reflects practical LLM usage - system instructions highest priority

### Pin Storage Format
- YAML for human editability
- Timestamp for future expiration features
- Method field (concat/msg) for flexibility
- Created timestamp on pin file (not individual pins)

## Debugging Strategy

### Layered Verbosity System
- `-v` basic operation info
- `-vv` configuration precedence tracing  
- `-vvv` message construction details
- `-vvvv` full API payload dumps

### Standardized Debug Functions (Utils.pm)
- `sel(level, msg)` - verbosity-filtered stderr
- `sel_opt_retrieve(level, setting, opts)` - config tracing
- Consistent format makes debugging systematic

## API Design Patterns

### Delegation for Clean APIs
```perl
# ZChat.pm delegates to Config.pm  
sub get_preset { return $self->{config}->get_preset(); }
```
**Benefit**: External code gets clean interface, internals stay encapsulated

### Effective Config as Single Source of Truth
- All precedence resolution goes into `effective_config` hash
- All getters read from `effective_config`, not separate state
- **Mistake avoided**: Having multiple config representations

## Command Execution Security

### Shell Injection Prevention
```perl
use String::ShellQuote;
my @cmd = ($bin, '--path', 'find', $preset);
my $cmd = shell_quote(@cmd);
my $result = `$cmd 2>/dev/null`;
```
**Critical**: Never pass user strings directly to system/backticks

## Context Management Strategy

### Pin-Aware History Truncation
- Always preserve: system prompts + pinned messages
- Truncate oldest conversation pairs first
- Keep ~80% of context window for safety margin
- **Future**: Token-based truncation vs character estimation

## Testing Insights

### Session Name Resolution Bug Pattern
- Empty string vs undefined handling throughout codebase
- Storage methods reject empty strings but Config returns them
- **Solution**: Consistent defaulting in Config module only

### Template Rendering Edge Cases
- Handle undefined template content gracefully
- Template variables (datenow, modelname) need fallbacks
- XSlate template errors shouldn't crash system

## Future Extension Points

### Clean Module Interfaces Enable
- Multiple LLM providers (Core.pm swap)
- Custom storage backends (Storage.pm extend)  
- Pin processing customization (Pin.pm extend)
- Output formatters (new modules)

**Design success**: Changes in one area don't ripple through codebase

## Performance Characteristics

### Startup Time Optimization
- Only load required modules
- Lazy initialization where possible
- Streaming responses provide immediate feedback
- **Trade-off**: Functionality over micro-optimizations

## Key Implementation Files

- `ZChat.pm` - Orchestration layer
- `ZChat::Config` - Precedence chain logic
- `ZChat::Storage` - File I/O with secure permissions  
- `ZChat::Pin` - Message ordering and management
- `ZChat::Preset` - Multi-source prompt resolution
- `ZChat::Core` - LLM API communication
- `ZChat::Utils` - Shared utilities and debug functions

## Migration Notes

### From Monolithic to Modular
- Preserved all original CLI functionality
- Added programmatic API without breaking existing usage
- Utils.pm centralizes previously scattered helper functions
- **Success metric**: Existing shell scripts continue working