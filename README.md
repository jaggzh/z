# z / ZChat - Modular LLM Interface with Session Management

**Warning:** This whole project is a rewrite of my `z` script as a full module *and* script. **I don't guarantee anything.**

<!--
<div align="center">
  <em>Main interface showing interactive mode with pinned messages</em><br>
  <img src="ss/main_interface.png" alt="ZChat main interface in action"><br>
</div>
-->

A sophisticated command-line LLM interface for **extremely-efficient and powerful** CLI and script-use of your favorite LLM.

This was developed over multiple years of time, but it's now provided as a core module/API **and** the CLI tool.
(For what it's worth, I designed this originally for use with my llama.cpp server, but it might work with OpenAI now, as it uses the OpenAI /v1 endpoint. And model info offers ollama support (not tested).

* It includes an `-i` interactive mode.
* Store your interactions, history, and pins, in a new named session as easy as `-n session-name`.
* Message pinning, primarily for use when creating AI agents, allows pinning in the system prompt, or in different forms in messages, including combined in an initial message (as either the Assistant or the User), or multiple leading messages in the chat history.
* History editing.
* Tools important for AI Agent design.
* Designed for freedom **and** consistency. You can work from whatever language you want, be it Bash, Python, Perl, or anything else, and then do tests directly from command-line.

All the power is provided through the module, but the main CLI script, `z`, provides basically **all** the functionality.
Thus, it's usable for AI agent use whether you work in Python, Bash, Perl, or anything else.

Session/conversation management is treated as a first-class architectural concern. Effectively a "wrapper" around your LLM server, it provides robust powerful abilities, like:

* **Session management:** Convenient through CLI or API calls
* **Persistent message pinning:** With an assortment of approaches, with defaults handled for you
* **Preset system prompts:** Easily placed as plain text files (with template variable support), or directories with metadata for other settings, if you need that.
* **A clean modular design:** That separates CLI convenience from programmatic access.

## Some easy use.

Set your backend URL in an env var (I'm unfamiliar with these, but they're in here; feel free to PR).
Defaults to 127.0.0.1 port 8080.

```
Pick your favorite:
LLAMA_URL LLAMA_API_URL LLAMACPP_SERVER LLAMA_CPP_SERVER LLM_API_URL
OPENAI_BASE_URL OPENAI_API_BASE OPENAI_URL

Optional key:
OPENAI_API_KEY LLAMA_API_KEY AZURE_OPENAI_API_KEY
```

Most commands can be combined. You can change settings, and they'll be available immediately, with a query done right there inline or piped in.

```bash
# Each of these are valid lines, some performing queries.

$ z hello
$ echo "hello" | z -
$ z -n new-chat -- "This has its own isolated history, and I'm saying this to my LLM."
$ z -n new-chat --sp  # I just set 'new-chat' in my shell and all the programs I call here
$ z -w  # Wipe the conversation
$ z -w I just wiped my session. What do you think?
$ z -H -- "No history read nor written, but at least my query is now safer."
$ z -I -- "This is Input-Only history."
$ cat some-stuff.txt | z -
$ z --system-string "You are a helpful AI assistant." --ss  "I just stored that system prompt for my session."
$ z --sstr "Shorthand system prompt string."
$ z --system my-sys-prompt.txt --ss   # Stored this file path as my session's system prompt
$ z --system temporary-sys-prompt.txt --sp  # This is only tied to my shell and everything running in it.
$ z --system my-main-user-prompt.txt --su # Stored global for my user.
$ z --pin "Pinned content. Remember this in this session."
```

# And so much more.

## Why Perl? (A Brief Defense)

Before diving in, let's address the elephant in the room. Yes, this is written in Perl in 2025. No, that's not a mistake or nostalgia - it's a deliberate educated and highly-experienced choice, for several reasons.

But let's make something clear: **I regularly code in Python -- on a daily basis.**  I've coded in Python for over 15 years. I've done hundreds if not thousands of projects in Python, including neural nets, other machine-learning projects, simulation systems, and even Blender extensions.

...but... perl? Why again?

1. **Performance**: Perl remains one of the fastest scripting languages. Startup-time? Python is bloat. Runtime? Perl still excels. Text-processing and I/O operations? Perl was designed back when people wanted to squeeze every ounce of efficiency out of their systems -- and they balanced it with the ability to code like the wind (maybe a whirlwind). For my projects, I wanted low-latency, and easy coding; Perl seemed like the best balance.
2. **Expressiveness**: Complex text transformations that require 20 lines in Python often need just 3-4 in Perl (and, yes, you can do it in one).
3. **CPAN**: The original comprehensive package ecosystem (before npm was even a concept).
4. **Mature Stability**: While others chase the latest framework du jour, Perl just works. Also, Perl's modules tend to stay stable and be backwards compatible. I don't think I've **ever**, in 30 years, had to change to a different "perl environment" due to module-incompatibility.

Python developers discovering a typo crashed their program after an hour of processing will appreciate Perl's compile-time checking. The language has a learning curve, but the payoff in maintainable, performant code is substantial. (Okay, well, maybe someone else's code is slop, but it need not be).

## So, here's `z -h`:

```
z [-EegHhIiLnPrSsTvw] [long options...] [prompt]
    --help (or -h)           This beautiful help
    --verbose (or -v)        Increase verbosity
    --verbose-resp           Verbose response data
                             aka --vr
    --image[=STR...]         Provide images (use [img] or
                             [img-1]..[img-N] in prompt) (This is old and
                             needs updating)
                             aka --img
    --clipboard              Use clipboard content as Query
                             aka --cb
    --interactive (or -i)    Interactive mode (query on CLI can be
                             included as first message)
                             aka --int
    --echo1 (or -e)          Echo back initial prompt
    --echo-delineated        Echo with <echo></echo> and <reply></reply>
                             tags
                             aka --echod, --ee
    --raw (or -r)            Raw output (no processing)
    --tokens-full            Output tokens of input text
    --token-count (or -T)    Count tokens in input text
    --ctx                    Get running model n_ctx
    --metadata               Get running model metadata
    --n_predict INT (or -P)  Limit prediction length to N tokens
    --play-user              Play user text with TTS
                             aka --pu
    --play-resp              Play response text with TTS
                             aka --pr
    --probs                  Return probabilities for top N tokens
    --no-color               Disable color in interactive mode
                             aka --nc
    --grammar STR (or -g)    Force a grammar
    --thought                Do not remove reasoning sections
                             aka --think
    --thought-re STR         Specify a regex for stripping reasoning
                             aka --tre

    Storage options and Session management:
    --session STR (or -n)    Session name (slash-separated path)

    --store-user (or -S)     Store session in user global config
                             aka --su
    --store-session          Store in current session config
                             aka --ss
    --store-pproc            Save session name and system-prompt settings
                             tied to your current shell. This uses
                             SID+PPID in POSIX systems (and uses the
                             /proc/ file system to obtain the group
                             leader)
                             aka --store-shell, --sp
    --set-pproc INT          Override parent ID for --store-pproc/--sp,
                             if you think you know better, but when our
                             SID+PPID fail to match you only have
                             yourself to blame.

    System Prompt:         
    --system-string STR      Set system prompt as a literal string
                             (highest explicit source after file)
                             aka --system-str, --sstr
    --system-file STR        Set system prompt from a file (relative
                             paths allowed)
                             aka --sfile
    --system-persona STR     Set system prompt by persona name (resolved
                             by persona tool)
                             aka --spersona, --persona
    --system STR (or -s)     Auto-resolve through -file then -persona
                             (but does NOT accept a string)
                             aka --sys

    History:               
    --wipe (or -w)           Wipe conversation history
    --wipeold STR            Wipe/expire msgs older than {FLOAT
                             TIME}[smhdwMyY] (e.g. 1.5h)
                             aka --wipeexp, --we, --wo
    --no-history (or -H)     Do not use history (no load, no store)
    --input-only (or -I)     Use history BUT do not write to it
    --edit-hist (or -E)      Edit history in vim
                             aka --eh
    --owrite-last STR        Overwrite last history message for role
                             (u|user|a|assistant) with current prompt
    --conv-last STR          Write last message content: '-' => stdout,
                             '-PATH' or 'PATH' => write to file
                             aka --cl
    --output-last            Write last message to STDOUT (same as
                             '--conv-last -')
                             aka --ol

    Utility:               
    --list-sys (or -L)       List available file and 'persona'-based
                             system prompts.
                             aka --sys-list
    --fallbacks-ok           OK to use fallbacks if things fail
    --status                 Show current configuration status and
                             precedence
                             aka --stat

    Message pinning (see --help-pins):
    --pin STR...             Add pinned message(s)
    --pins-file STR...       Add pinned message(s) from file(s)
    --pins-list              List all pinned messages (their lines will
                             wrap)
    --pins-sum               List pinned messages (one-line summary)
    --pins-cnt               Output total count of all pins of all pin
                             types
    --pin-sum-len INT        Max length for pin summary lines
    --pin-write STR          Overwrite pin by index: --pin-write '0=new
                             content'
    --pins-clear             Clear all pinned messages
    --pin-rm INT...          Remove pin(s) by index
    --pins-sys-max INT       Max system pins
    --pins-user-max INT      Max user pins
    --pins-ast-max INT       Max assistant pins
    --pin-sys STR...         Add system pin(s)
    --pin-user STR...        Add user pin(s)
    --pin-ast STR...         Add assistant pin(s) (shorthand: ast)
    --pin-ua-pipe STR...     Add paired user|||assistant pin(s)
    --pin-ua-json STR...     Add paired pins from JSON object(s) with
                             {user,assistant}
    --pins-clear-user        Clear user pins only
    --pins-clear-ast         Clear assistant pins only
    --pins-clear-sys         Clear system pins only
    --pin-shim STR           Set shim appended to user/assistant pinned
                             messages
    --pin-tpl-user STR       Template for user pins when using
                             vars/varsfirst mode
    --pin-tpl-ast STR        Template for assistant pins when using
                             vars/varsfirst mode
    --pin-mode-sys STR       How to include system pins: vars|concat|both
                             (default: vars)
    --pin-mode-user STR      How to include user pins:
                             vars|varsfirst|concat (default: concat)
    --pin-mode-ast STR       How to include assistant pins:
                             vars|varsfirst|concat (default: concat)
    Help:                  
    --help-sys-pin-vars      Show quick example of template vars to use
                             for system pins
    --help-pins              Show detailed help for pinning
    --help-cli               CLI use - Basic
    --help-cli-adv           cli use - Advanced

Basic usage:

Select or create 'myprj' session, store it active in the
 current shell session group, and perform a query, which will
 be stored in 'myprj' chat history.
$ z -n myprj --sp -- "What's a SID and Session Group Leader?"

Same, but subdirs can be used
$ z -n myprj/subprj --sp -- "Help me"
$ z -n myprj -- "One-time use of myprj, not saved."

Store 'default' as user global session (to be used when session
 is not specified or not set with --sp in the current shell.
$ z -n default --su # Store 'default' as user global session

$ z I can query unsafely too.
$ cat q.txt | z -

System prompt name (from system files or through 'persona' bin)
 Here I'm specifying cat-talk as my session, and storing (-ss)
 its active system prompt name as 'my-cat'
$ z --system my-cat --ss -n cat-talk -- "I stored my-cat in my 'session')

Provide a path to the system prompt, and store it default in
 the 'cat-talk' session.
$ z --system-file here/sys.txt --ss -n cat-talk -- "And a query."
```


<!--
<div align="center">
  <em>Pin management system showing hierarchical organization</em><br>
  <img src="ss/pin_management.png" alt="Pin management interface"><br>
</div>
-->

## Architecture Overview (this is a bit old)

```
zchat/
├── z                       # CLI wrapper with all user-facing features
├── lib/
│   ├── ZChat.pm            # Main orchestration layer
│   └── ZChat/
│       ├── Core.pm         # LLM API communication (streaming/sync)
│       ├── Config.pm       # Configuration precedence chain
│       ├── History.pm      # Management of history/conversations
│       ├── Storage.pm      # File I/O with secure permissions
│       ├── SystemPrompt.pm # Handling of System prompts, files, etc.
│       ├── ParentID.pm     # Platform-independent Shell-tied session IDs
│       ├── Pin.pm          # Persistent message management
│       ├── Preset.pm       # System prompt resolution
│       ├── Utils.pm        # General global utils
│       └── ansi.pm         # Convenience routines/vars for term colors
├── data/                   # These don't actually exist right now; sorry.
│   └── sys/                # Built-in system prompt presets
│       ├── default         # Simple file-based preset
│       └── complex/        # Directory-based preset example
│           ├── prompt      #   Main system prompt
│           └── meta.yaml   #   Metadata (voice, etc.) (Mostly unused)
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
- Storing sessions temporarily in files ID'ed by the current shell allows rapid work
- CLI flags provide immediate runtime overrides without affecting stored config

### Storage Strategy

**Separate Concerns, Separate Files**: Rather than cramming everything into monolithic config files, ZChat uses targeted storage:

```
~/.config/zchat/
├── user.yaml                # Global user preferences
└── sessions/
    ├── project/analysis/    # Hierarchical session organization
    │   ├── session.yaml     # Session-specific config
    │   ├── pins.yaml        # Pinned messages (separate for easy removal)
    │   └── history.json     # Conversation history
    └── pets/fluffy/
        ├── session.yaml
        ├── ...
```

This approach prevents unnecessary file rewrites, and enables a robust, powerful precedence system that defaults to.. just working. (YAML is convenient when you want to examine or edit by hand.)

### Pin Management System

The pin system implements a **hard-coded message ordering** that reflects practical LLM usage patterns:

1. **System pins** (always concatenated)
2. **Assistant pins** (concatenated)  
3. **User pins** (concatenated)
4. **Individual assistant messages**
5. **Individual user messages**
6. **Conversation history** (truncated to fit context)

This ordering ensures system-level instructions take precedence, while allowing for nuanced conversation framing through assistant and user pins.

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

For reasoning models, ZChat can automatically strip `<think>...</think>` sections unless explicitly requested; and this is customizable, so you can do compelled-reasoning in your non-reasoning models, and it can just be stripped with a regex.

```bash
$ z --thought "Complex reasoning task"  # Keep reasoning visible
$ z "Simple task"                       # Auto-remove reasoning sections
```

### Multi-Modal Support

Images are seamlessly integrated with base64 encoding and proper API formatting. (I've not tested images since separating functionality into the module).

```bash
$ z --img photo.jpg "What's in this image?"
$ z --clipboard      # Automatically detects image vs text clipboard content
```

## Usage Examples

### Basic Completion

```bash
# Simple query
$ z "Write a Perl function to parse CSV"
$ z "How about with CSV::XS?"

# With specific preset system prompt file
$ z -s coding "Optimize this algorithm for performance"
```

### Session Management

```bash
# Create hierarchical sessions
$ z -n project/backend/api "Design the user authentication system"
$ z -n project/frontend "What UI framework should we use?"

# Store current settings
$ z -s coding -n myproject --store-session  # coding preset becomes default for myproject
$ z -s helpful --store-user                 # helpful becomes user's global default
```

### Pin Management

<div align="center">
  <em>Interactive pin management workflow</em><br>
  <img src="ss/pin_workflow.png" alt="Pin management workflow"><br>
</div>

```bash
# Add persistent context
$ z --pin "You are an expert Perl developer with 20 years experience"
$ z --pin "The project uses modern Perl practices: signatures, postderef"
$ z --pin "Focus on performance and maintainability"

# Review pins
$ z --pin-sum                    # One-line summaries
$ z --pin-list                   # Full content

# Manage pins  
$ z --pin-rm 0                   # Remove first pin
$ z --pin-write 1="Updated content"  # Replace pin content
$ z --pin-clear                  # Start fresh
```

### Interactive Mode

```bash
$ z -i  # Enter interactive mode
>> Tell me about Perl's postderef feature
[Response appears here]
>> Can you show an example?
[Response with code examples]
>> ^D or ^C  # Quit
```

### Advanced Features

```bash
# Token analysis
$ z -T "How many tokens is this text?"
man grep | z -T -
$ z --tokens-full "Detailed tokenization breakdown"

# Model information  
$ z --ctx        # Context window size
$ z --metadata   # Full model metadata

# History management
$ z --wipe       # Clear conversation history
$ z -E           # Edit history in $EDITOR
$ z -H           # Disable history entirely
$ z -I           # Read-only history mode
```

## Programmatic Interface

For applications that need LLM capabilities without CLI overhead:

```perl
use ZChat;

# Basic usage
my $z = ZChat->new();
my $response = $z->query("Generate a haiku about programming");

# With session and configuration
my $z = ZChat->new(
    session => "automated-reports",
    system_string => "You write executive summaries"
);

# Pin management
$z->pin("All responses should be under 100 words");
$z->pin("Use bullet points for key findings", role => 'user');

# Multiple completions in same context
for my $data_file (@files) {
    my $analysis = $z->query("Analyze this data: $data_file");
    save_report($data_file, $analysis);
}
```

<!--
<div align="center">
  <em>Session hierarchy and organization</em><br>
  <img src="ss/session_hierarchy.png" alt="Session organization structure"><br>
</div>
-->

## Installation & Setup

ZChat is designed for **distribution without installation**. The `FindBin` approach means you can:

```bash
$ git clone https://github.com/jaggzh/z zchat
$ cd zchat
$ ./z "Hello world"  # Just works (maybe)
```

Unless you have a Perl installation, you will also need to install dependencies. 

For Arch:

```bash
sudo pacman -S perl-string-shellquote perl-json-xs perl-yaml-libyaml imagemagick perl-module-install perl-file-slurper perl-term-readline-gnu
sudo yay -S perl-mojolicious perl-text-xslate perl-term-size perl-getopt-long-descriptive perl-clipboard
```

(Sorry, I've not fleshed out what they are on other distros for you to install them.)
For missing modules:

```bash
$ cpan install Mojo::UserAgent JSON::XS YAML::XS Text::Xslate Image::Magick
```

### Configuration

Create initial user config:
```bash
$ z --list-sys                       # See available system prompts
$ z -s helpful --store-user          # Set global default
$ z -n work/project1 --store-session # Create work session
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

1. **Token Estimation**: Rough calculation based on character count without hitting the server (I've not tested this since porting to the module).
2. **Pin Preservation**: Pinned messages always included in context
3. **History Truncation**: Remove oldest conversation pairs first
4. **Safety Margin**: Keep total tokens at ~80% of model context limit

### Error Handling Philosophy

ZChat follows what Claude deems as Perl's "no news is good news philosophy" while providing meaningful error messages when things go wrong. Failed operations log warnings but don't crash the system unless the failure is truly catastrophic.

### Performance Characteristics

- **Startup Time**: Probably about <200ms minimum (`z -h >/dev/null` takes that long on my system)
- **Memory Usage**: Minimal - only loads required modules
- **File I/O**: Optimized for frequent small reads/writes only where needed
- **Network**: Default streaming responses provide immediate feedback (unless reasoning is being stripped)
- **Concurrency**: Single-threaded by design (simpler, easier-to-follow code, and more predictable)

## Advanced Configuration Examples

### Complex Pin Workflows

```bash
# Set up a code review session, stored persistently, and enabled for the current shell session:
$ z -n reviews/backend --pin "You are a senior software engineer reviewing code" --sp
$ z --pin "Focus on: security, performance, maintainability"
$ z --pin "Provide specific suggestions with examples"

# Combining and Chaining:
$ z -n reviews/backend --pin "The first pin" --pin "Another" --sp
# I just set the session acive in my shell, and added two pins
$ z --pin "Focus on: security, performance, maintainability"
$ z --pin "Provide specific suggestions with examples"

# Perform a query:
$ z "Review this authentication middleware"

# Or if you changed shells you can pick the session for a one-off:
$ z -n reviews/backend "Review this authentication middleware"
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
    my $report = $z->query("Analyze this department data: $data");
    save_report($department, $report); # <-- That's your own routine
}
```

## Contributing & Extension

The modular architecture makes ZChat highly extensible. Want to add support for a different LLM API? Implement a new `ZChat::Core` subclass. Need custom storage backends? Extend `ZChat::Storage`. The separation of concerns means changes in one area don't ripple through the entire codebase.

Key extension points:
- **Storage backends**: Database, cloud storage, etc.
- **LLM providers**: OpenAI, Anthropic, local models (I haven't added other than OpenAI yet)
- **Pin processors**: Custom ordering, filtering, templating  
- **Output formatters**: Markdown, HTML, custom formats
- **Authentication**: API keys, OAuth, etc.

---

*ZChat: Because sometimes the best way forward is to build exactly what you need, in a language that doesn't apologize for being powerful.*
