# ZChat - Modular LLM Interface with Session Management

<!--
<div align="center">
  <em>Main interface showing interactive mode with pinned messages</em><br>
  <img src="ss/main_interface.png" alt="ZChat main interface in action"><br>
</div>
-->

A sophisticated command-line LLM interface written in Perl that treats the CLI convenience, so no matter where you are in the world, as a term user, `z` is right there.

Designed as a tool to wrap your LLM server, it manages sessions/conversations, which are taken as a first-class architectural concern. It provides:

* **Session management:** Convenient through CLI or API calls
* **Persistent message pinning:** With an assortment of approaches, with defaults handled for you
* **Preset system prompts:** Easily placed as plain text files (with template variable support), or directories with metadata for other settings, if you need that.
* **A clean modular design:** That separates CLI convenience from programmatic access.

## Why Perl? (A Brief Defense)

Before diving in, let's address the elephant in the room. Yes, this is written in Perl in 2025. No, that's not a mistake or nostalgia - it's a deliberate educated and highly-experienced choice, for several reasons:

1. **Performance**: Perl remains one of the fastest scripting languages. Startup-time? Python is bloat. Runtime? Perl still excels. Text-processing and I/O operations? Perl was designed back when people wanted to squeeze every ounce of efficiency out of their systems -- and they balanced it with the ability to code like the wind (maybe a whirlwind).
2. **Expressiveness**: Complex text transformations that require 20 lines in Python often need just 3-4 in Perl (and, yes, you can do it in one).
3. **CPAN**: The original comprehensive package ecosystem (before npm was even a concept).
4. **Regex Integration**: First-class regex support built into the language syntax.
5. **Mature Stability**: While others chase the latest framework du jour, Perl just works.

Python developers discovering a typo crashed their program after an hour of processing will appreciate Perl's compile-time checking. The language has a learning curve, but the payoff in maintainable, performant code is substantial. (Okay, well, maybe someone else's code is slop, but it need not be).

<!--
<div align="center">
  <em>Pin management system showing hierarchical organization</em><br>
  <img src="ss/pin_management.png" alt="Pin management interface"><br>
</div>
-->

## Architecture Overview

```
zchat/
├── bin/
│   └── z                    # CLI wrapper with all user-facing features
├── lib/
│   ├── ZChat.pm            # Main orchestration layer
│   └── ZChat/
│       ├── Core.pm         # LLM API communication (streaming/sync)
│       ├── Config.pm       # Configuration precedence chain
│       ├── Storage.pm      # File I/O with secure permissions
│       ├── Pin.pm          # Persistent message management
│       └── Preset.pm       # System prompt resolution
├── data/
│   └── sys/                # Built-in system prompt presets
│       ├── default         # Simple file-based preset
│       └── complex/        # Directory-based preset example
│           ├── prompt      #   Main system prompt
│           └── meta.yaml   #   Metadata (voice, etc.)
└── ss/                     # Screenshots for documentation
```

The design philosophy centers on **separation of concerns**: the CLI provides convenience features while the core modules offer clean programmatic interfaces. External applications can import `ZChat` directly without inheriting CLI baggage.

## Core Principles

### Configuration Precedence Chain

One of ZChat's most sophisticated features is its carefully designed configuration precedence system:

```
System Defaults → User Global → Session Specific → CLI Runtime
```

This creates intuitive behavior where:
- System defaults provide sensible fallbacks
- User settings persist across sessions
- Session settings override user defaults when working on specific projects  
- CLI flags provide immediate runtime overrides without affecting stored config

<div align="center">
  <em>Configuration precedence visualization</em><br>
  <img src="ss/config_precedence.png" alt="Configuration precedence diagram"><br>
</div>

### Storage Strategy

**Separate Concerns, Separate Files**: Rather than cramming everything into monolithic config files, ZChat uses targeted storage:

```bash
~/.config/zchat/
├── user.yaml                    # Global user preferences
└── sessions/
    └── project/analysis/        # Hierarchical session organization
        ├── session.yaml         # Session-specific config
        ├── pins.yaml           # Pinned messages (separate for easy removal)
        └── history.json        # Conversation history
```

This approach prevents unnecessary file rewrites (looking at you, "last_used" timestamps that dirty configs) and allows granular management of different data types.

### Pin Management System

The pin system implements a **hard-coded message ordering** that reflects practical LLM usage patterns:

1. **System pins** (always concatenated)
2. **Assistant pins** (concatenated)  
3. **User pins** (concatenated)
4. **Individual assistant messages**
5. **Individual user messages**
6. **Conversation history** (truncated to fit context)

This ordering ensures system-level instructions take precedence, while allowing for nuanced conversation framing through assistant and user pins.

<div align="center">
  <em>Pin ordering and message flow visualization</em><br>
  <img src="ss/pin_ordering.png" alt="Pin message ordering system"><br>
</div>

## Unique Features

### Streaming Response Processing

The streaming implementation handles partial JSON chunks gracefully while providing live output:

```perl
# Real-time processing of Server-Sent Events
$tx->res->content->on(read => sub {
    my ($content, $bytes) = @_;
    $buffer .= $bytes;
    
    while ($buffer =~ s/^(.*?\n)//) {
        my $line = $1;
        # Parse SSE format and extract deltas...
    }
});
```

### Context-Aware History Truncation

Instead of dumb "last N messages" truncation, ZChat preserves pinned content and system prompts while intelligently trimming conversation history to fit model context windows.

### Template Processing

System prompts support Xslate templating with useful variables:
- `<: $datenow :>` - Current timestamp
- `<: $modelname :>` - Running model name  

### Thought Removal Pattern

For reasoning models, ZChat can automatically strip `<think>...</think>` sections unless explicitly requested:

```bash
z --thought "Complex reasoning task"  # Keep reasoning visible
z "Simple task"                      # Auto-remove reasoning sections
```

### Multi-Modal Support

Images are seamlessly integrated with base64 encoding and proper API formatting:

```bash
z --img photo.jpg "What's in this image?"
z --clipboard      # Automatically detects image vs text clipboard content
```

## Usage Examples

### Basic Completion

```bash
# Simple query
z "Write a Perl function to parse CSV"

# With specific preset
z -p coding "Optimize this algorithm for performance"
```

### Session Management

```bash
# Create hierarchical sessions
z -n project/backend/api "Design the user authentication system"
z -n project/frontend "What UI framework should we use?"

# Store current settings
z -p coding -n myproject --store-session  # coding preset becomes default for myproject
z -p helpful --store-user                 # helpful becomes user's global default
```

### Pin Management

<div align="center">
  <em>Interactive pin management workflow</em><br>
  <img src="ss/pin_workflow.png" alt="Pin management workflow"><br>
</div>

```bash
# Add persistent context
z --pin "You are an expert Perl developer with 20 years experience"
z --pin "The project uses modern Perl practices: signatures, postderef"
z --pin "Focus on performance and maintainability"

# Review pins
z --pin-sum                    # One-line summaries
z --pin-list                   # Full content

# Manage pins  
z --pin-rm 0                   # Remove first pin
z --pin-write 1="Updated content"  # Replace pin content
z --pin-clear                  # Start fresh
```

### Interactive Mode

```bash
z -i  # Enter interactive mode
>> Tell me about Perl's postderef feature
[Response appears here]
>> Can you show an example?
[Response with code examples]
>> q  # Quit
```

### Advanced Features

```bash
# Token analysis
z -T "How many tokens is this text?"
z --tokens-full "Detailed tokenization breakdown"

# Model information  
z --ctx        # Context window size
z --metadata   # Full model metadata

# History management
z --wipe       # Clear conversation history
z -E           # Edit history in $EDITOR
z -H           # Disable history entirely
z -I           # Read-only history mode
```

## Programmatic Interface

For applications that need LLM capabilities without CLI overhead:

```perl
use ZChat;

# Basic usage
my $z = ZChat->new();
my $response = $z->complete("Generate a haiku about programming");

# With session and configuration
my $z = ZChat->new(
    session => "automated-reports",
    preset => "business-writing",
    system_prompt => "You write executive summaries"
);

# Pin management
$z->pin("All responses should be under 100 words");
$z->pin("Use bullet points for key findings", role => 'user');

# Multiple completions in same context
for my $data_file (@files) {
    my $analysis = $z->complete("Analyze this data: $data_file");
    save_report($data_file, $analysis);
}
```

<div align="center">
  <em>Session hierarchy and organization</em><br>
  <img src="ss/session_hierarchy.png" alt="Session organization structure"><br>
</div>

## Installation & Setup

ZChat is designed for **distribution without installation**. The `FindBin` approach means you can:

```bash
git clone https://github.com/yourname/zchat
cd zchat
./bin/z "Hello world"  # Just works
```

Dependencies are standard CPAN modules that most Perl installations include. For missing modules:

```bash
cpan install Mojo::UserAgent JSON::XS YAML::XS Text::Xslate Image::Magick
```

### Configuration

Create initial user config:
```bash
z --list-presets                    # See available presets
z -p helpful --store-user          # Set global default
z -n work/project1 --store-session # Create work session
```

## Technical Implementation Details (For LLMs)

### Message Flow Architecture

The system processes messages through several discrete phases:

1. **Configuration Resolution**: The precedence chain loads effective config
2. **Pin Processing**: Pins are loaded and ordered according to hard-coded rules  
3. **History Loading**: Conversation history loaded from session storage
4. **Message Array Construction**: All components combined into API-ready format
5. **Context Management**: Token estimation and history truncation if needed
6. **API Communication**: Streaming or synchronous completion request
7. **Response Processing**: Thought removal, formatting, and output
8. **Storage Update**: New conversation saved to session history

### Storage Format Specifications

**User Config** (`~/.config/zchat/user.yaml`):
```yaml
preset: "default"
session: "current/session/name"
```

**Session Config** (`sessions/.../session.yaml`):
```yaml  
preset: "specialized-preset"
created: 1703123456
system_prompt: "Additional system context"
system_file: "/path/to/prompt.txt"
```

**Pin Storage** (`sessions/.../pins.yaml`):
```yaml
created: 1703123456
pins:
  - content: "System-level instruction"
    role: "system"  
    method: "concat"
    timestamp: 1703123456
  - content: "User context"
    role: "user"
    method: "concat" 
    timestamp: 1703123457
```

**History Format** (`sessions/.../history.json`):
```json
[
  {
    "user": "User message content",
    "assistant": "Assistant response content"
  }
]
```

### Pin Ordering Algorithm

The pin system uses deterministic ordering to ensure consistent message arrays:

```perl
# Hard-coded precedence (from ZChat::Pin)
1. System pins (all concatenated with \n)
2. Assistant pins (concatenated)  
3. User pins (concatenated)
4. Individual assistant pins (separate messages)
5. Individual user pins (separate messages)

# Within each category, pins maintain insertion timestamp order
```

### Context Window Management  

Context management uses a multi-stage approach:

1. **Token Estimation**: Rough calculation based on character count
2. **Pin Preservation**: Pinned messages always included in context
3. **History Truncation**: Remove oldest conversation pairs first
4. **Safety Margin**: Keep total tokens at ~80% of model context limit

### Error Handling Philosophy

ZChat follows Perl's "no news is good news" philosophy while providing meaningful error messages when things go wrong. Failed operations log warnings but don't crash the system unless the failure is truly catastrophic.

### Performance Characteristics

- **Startup Time**: < 100ms for most operations
- **Memory Usage**: Minimal - only loads required modules
- **File I/O**: Optimized for frequent small reads/writes
- **Network**: Streaming responses provide immediate feedback
- **Concurrency**: Single-threaded by design (simpler, more predictable)

<div align="center">
  <em>Performance metrics dashboard</em><br>
  <img src="ss/performance_metrics.png" alt="Performance characteristics"><br>
</div>

## Advanced Configuration Examples

### Complex Pin Workflows

```bash
# Set up a code review session
z -n reviews/backend --pin "You are a senior software engineer reviewing code"
z --pin "Focus on: security, performance, maintainability"
z --pin "Provide specific suggestions with examples"
z --store-session

# Later, use the configured session
z -n reviews/backend "Review this authentication middleware"
```

### Multi-Modal Analysis Pipeline

```bash
# Analyze a series of images
for img in screenshots/*.png; do
    z --img "$img" "What UI improvements do you suggest?" >> analysis.txt
done
```

### Automated Report Generation

```perl
# Perl script using ZChat programmatically
use ZChat;

my $z = ZChat->new(session => "monthly-reports");
$z->pin("Generate executive summaries in business format");
$z->pin("Include key metrics and recommendations");

for my $department (@departments) {
    my $data = load_department_data($department);
    my $report = $z->complete("Analyze this department data: $data");
    save_report($department, $report);
}
```

## Contributing & Extension

The modular architecture makes ZChat highly extensible. Want to add support for a different LLM API? Implement a new `ZChat::Core` subclass. Need custom storage backends? Extend `ZChat::Storage`. The separation of concerns means changes in one area don't ripple through the entire codebase.

Key extension points:
- **Storage backends**: Database, cloud storage, etc.
- **LLM providers**: OpenAI, Anthropic, local models
- **Pin processors**: Custom ordering, filtering, templating  
- **Output formatters**: Markdown, HTML, custom formats
- **Authentication**: API keys, OAuth, etc.

---

*ZChat: Because sometimes the best way forward is to build exactly what you need, in a language that doesn't apologize for being powerful.*
