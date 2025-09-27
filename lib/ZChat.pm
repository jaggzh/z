package ZChat;
use v5.26.3;
use feature 'say';
use experimental 'signatures';
use strict;
use warnings;

use utf8;
use File::Spec;
use String::ShellQuote;
use Capture::Tiny ':all';
use Text::Xslate;
use POSIX;
use Cwd qw(abs_path);
use File::Basename qw(dirname);

use ZChat::Core;
use ZChat::Config;
use ZChat::Storage;
use ZChat::Pin;
use ZChat::Utils ':all';
use ZChat::History;
use ZChat::SystemPrompt;
use ZChat::ansi;

our $VERSION = '1.1.0';

my $def_thought_re = qr{(?:<think>)?.*?<\/think>\s*}s;
my $bin_persona = 'persona';

sub new {
    my ($class, %opts) = @_;

    my $self = {
        session_name => ($opts{session} // ''),
        system       => $opts{system},
        system_prompt=> $opts{system_prompt},
        system_file  => $opts{system_file},
        system_string=> $opts{system_string},
        pin_shims    => $opts{pin_shims},
        override_pproc=> $opts{override_pproc},
        config       => undef,
        core         => undef,
        storage      => undef,
        pin_mgr      => undef,
        history      => undef,
        _thought     => { mode => 'auto', pattern => undef }, # mode: auto|disabled|enabled
        _fallbacks_ok => 0,
        _print_target    => undef,   # undef (silent) | *FH
        _on_chunk        => undef,   # optional streaming callback
    };

    bless $self, $class;

    $self->{storage} = ZChat::Storage->new();
    $self->{config}  = ZChat::Config->new(
        storage => $self->{storage},
        session_name => $self->{session_name},
        override_pproc => $self->{override_pproc},
    );

    # Load effective configuration
    $self->_load_config(\%opts);
    $self->{session_name} = $self->{config}->get_session_name();

    $self->{pin_mgr} = ZChat::Pin->new(
        storage => $self->{storage},
        session_name => $self->{session_name}
    );

    $self->{history} = ZChat::History->new(
        storage => $self->{storage},
        session => $self->{session_name},
        mode    => 'rw',
    );

    $self->{system_prompt} = ZChat::SystemPrompt->new(
        config => $self->{config}
    );

    $self->{core} = ZChat::Core->new();

    return $self;
}

sub store_shell_config {
    my ($self, $optshr) = @_;
    return $self->{config}->store_shell_config($optshr);
}

# sub switch_session {
#     my ($self, $target, %opts) = @_;
#     # %opts: create_if_missing=>0/1, dry_run=>0/1, allowlist=>[...], source=>"cli|agent|api"

#     _validate_session_name($target, \%opts);       # sanitize & policy checks
#     return { ok=>1, would=>_diff_for($target) } if $opts{dry_run};

#     $self->_flush_all_pending();                   # pins/history/etc for current
#     my $guard = $self->{storage}->acquire_global_lock(); # prevent races

#     my $exists = $self->{storage}->session_exists($target);
#     if (!$exists) {
#         die "No such session" unless $opts{create_if_missing};
#         $self->{storage}->init_session($target);   # mkdirs, seed files atomically
#     }

#     $self->{config}->set_override(session_name => $target);
#     $self->_load_config();                         # recompute effective config

#     # propagate to dependents (single source of truth = get_session_name)
#     my $sn = $self->{config}->get_session_name();
#     $self->{pin_mgr}->set_session_name($sn);
#     $self->{preset_mgr}->set_session_name($sn);
#     # storage APIs should take session as an arg, but also record current for convenience
#     $self->{storage}->set_current_session($sn);

#     $guard->release();
#     return { ok=>1, session=>$sn };
# }

sub _load_config($self, $optshro=undef) {
    $optshro ||= {};

    # Resolve and narrow CLI system prompt options before passing to config
    my %resolved_cli = %$optshro;

    if (defined $optshro->{system}) {
        my $resolved = $self->_resolve_and_narrow_system($optshro->{system}, 'CLI');
        if ($resolved) {
            if ($resolved->{type} eq 'string') {
                $resolved_cli{system_string} = $resolved->{value};
                delete $resolved_cli{system};
                sel(1, "CLI --system resolved to system_string: $resolved->{value}");
			} elsif ($resolved->{type} eq 'file') {
                $resolved_cli{system_file} = $resolved->{value};
                delete $resolved_cli{system};
                sel(1, "CLI --system resolved to system_file: $resolved->{value}");
            } elsif ($resolved->{type} eq 'persona') {
                $resolved_cli{system_persona} = $resolved->{value};
                delete $resolved_cli{system};
                sel(1, "CLI --system resolved to system_persona: $resolved->{value}");
            }
        } else {
            # Resolution failed
            if ($self->{_fallbacks_ok}) {
                swarn "System '$optshro->{system}' could not be auto-resolved, removing from CLI options and checking stored precedences.";
                delete $resolved_cli{system};
            } else {
                die "System '$optshro->{system}' could not be resolved\n";
            }
        }
    }

    if (defined $optshro->{system_file}) {
        my $resolved = $self->_resolve_system_file_with_fallback($optshro->{system_file});
        if ($resolved) {
            $resolved_cli{system_file} = $resolved;
            sel(1, "CLI --system-file resolved to: $resolved");
        } else {
            if ($self->{_fallbacks_ok}) {
                swarn "System file '$optshro->{system_file}' could not be resolved, removing from CLI options";
                delete $resolved_cli{system_file};
            } else {
                die "System file '$optshro->{system_file}' could not be resolved\n";
            }
        }
    }

    # Store resolved options for later retrieval by storage operations
    $self->{_resolved_cli_options} = \%resolved_cli;
    my $config = $self->{config}->load_effective_config(\%resolved_cli);
}

sub _resolve_and_narrow_system {
    my ($self, $name, $source) = @_;

    sel(1, "Resolving --system '$name' from $source");

	# Auto-detect assumes spaces mean it's a string.
    if ($name =~ /\S\s\S/) {
        sel(1, "System auto-detected: Has spaces. Is system-string.");
        return { type => 'string', value => $name };
	}

    # Check if it's obviously intended as a path (absolute or contains "..")
    my $is_obvious_path = ($name =~ m#^/# || $name =~ m#/\.\.|\.\./#);

    if ($is_obvious_path) {
        sel(2, "Treating '$name' as path only (absolute or contains ..)");
        my $resolved_path = $self->_resolve_system_file_with_fallback($name);
        return $resolved_path ? { type => 'file', value => $resolved_path } : undef;
    }

    # Try as file first
    sel(2, "Trying '$name' as system file");
    my $file_path = $self->_resolve_system_file_with_fallback($name, { no_error => 1 });
    if ($file_path) {
        sel(2, "Resolved '$name' as file: $file_path");
        return { type => 'file', value => $file_path };
    }

    # Try as persona
    sel(2, "Trying '$name' as persona");
    my $persona_path = $self->_resolve_persona_path($name);
    if ($persona_path) {
        sel(2, "Resolved '$name' as persona");
        return { type => 'persona', value => $name };  # Store original name, not path
    }

    sel(1, "Could not resolve '$name' as file or persona");
    return undef;
}

sub _resolve_system_file_with_fallback {
    my ($self, $path, $opts) = @_;
    $opts ||= {};

    sel(2, "Resolving system file: '$path'");

    # 1. Try relative/absolute paths first
    my $resolved = $self->_try_resolve_path($path);
    return $resolved if $resolved;

    # 2. If not found and doesn't contain .. (security check), try system directory
    if ($path !~ m#\.\.#) {
        my $system_dir = $self->_get_system_prompts_dir();
        my $system_path = File::Spec->catfile($system_dir, $path);
        sel(2, "Trying system directory: $system_path");

        $resolved = $self->_try_resolve_path($system_path);
        return $resolved if $resolved;
    } else {
        sel(2, "Skipping system directory check (path contains ..)");
    }

    # Not found
    unless ($opts->{no_error}) {
        my @searched = ($path);
        push @searched, File::Spec->catfile($self->_get_system_prompts_dir(), $path) if $path !~ m#\.\.#;
        my $searched_str = join(", ", @searched);

        if ($self->{_fallbacks_ok}) {
            swarn "System file not found: '$path' (searched: $searched_str)";
        } else {
            die "System file not found: '$path' (searched: $searched_str)\n";
        }
    }

    return undef;
}

sub _try_resolve_path {
    my ($self, $path) = @_;

    # Handle broken symlinks as errors (they're obviously intended paths)
    if (-l $path && !-e $path) {
        swarn "Broken symlink detected: $path";
        return undef unless $self->{_fallbacks_ok};
    }

    # Check if it's a file
    if (-f $path) {
        my $abs_path = abs_path($path);
        sel(2, "Found file: $path -> $abs_path");
        return $abs_path;
    }

    # Check if it's a directory with system file
    if (-d $path) {
        my $system_file = File::Spec->catfile($path, 'system');
        if (-f $system_file) {
            my $abs_path = abs_path($system_file);
            sel(2, "Found system directory: $path/system -> $abs_path");
            return $abs_path;
        } else {
            # Directory exists but no system file - configuration error
            swarn "Directory '$path' exists but contains no 'system' file";
            return undef;
        }
    }

    return undef;
}

sub _get_system_prompts_dir {
    my ($self) = @_;
    my $home = $ENV{HOME} || die "HOME environment variable not set";
    return File::Spec->catdir($home, '.config', 'zchat', 'system');
}

sub _load_meta_yaml {
    my ($self, $system_file_path) = @_;

    my $dir = dirname($system_file_path);
    my $meta_file = File::Spec->catfile($dir, 'meta.yaml');

    return {} unless -f $meta_file;

    sel(2, "Loading meta.yaml: $meta_file");
    my $meta = $self->{storage}->load_yaml($meta_file);
    return $meta || {};
}

sub _resolve_system_file {
    my ($self, $path) = @_;
    return $path if File::Spec->file_name_is_absolute($path) && -f $path;

    my @roots;
    my $session_dir = eval { $self->{storage}->get_session_dir($self->{config}->get_effective_config->{session}) };
    push @roots, $session_dir if $session_dir && -d $session_dir;

    my $user_dir = $self->{config}->_get_config_dir;
    push @roots, $user_dir if $user_dir && -d $user_dir;

    push @roots, Cwd::getcwd(); # optional third root

    for my $root (@roots) {
        my $candidate = File::Spec->catfile($root, $path);
        return $candidate if -f $candidate;
    }

    my $roots_str = join(", ", @roots);
    die "system-file not found: '$path' (searched: $roots_str)\n";
}

sub _resolve_persona_path {
    my ($self, $name) = @_;
    my $msgpfx = "RESOLVE system prompt -- 'persona'";

    unless (defined $bin_persona) {
        sel 1, "No \$bin_persona path is defined in ZChat.pm\n";
        return undef;
    }

    my @cmd = ($bin_persona, '--path', 'find', $name);
    my $cmd_str = shell_quote(@cmd);
    sel(1, "$msgpfx -- Executing cmd: `$cmd_str`");

    my ($stdout, $stderr, $exit) = capture { system(@cmd); };

    if ($exit != 0) {
        my $msg = "$msgpfx -- Command failed (exit: $exit)";
        $msg .= ": $stderr" if $stderr;
        sel(1, $msg);
        return undef;
    }
    chomp $stdout if defined $stdout;
    sel(3, "$msgpfx => output: {{$stdout}}");

    # Check if command succeeded and found files
    if (!defined $stdout || $stdout =~ /^\s*$/) {
        my $msg = "$msgpfx returned no results for '$name'";
        sel(1, $msg);
        return undef;
    }

    my @files = split /\n/, $stdout;
    return undef unless @files;

    my $persona_file;
    if (@files > 1) {
        die "  REFUSING: Multiple persona files found for '$name':"
            if ! $self->{_fallbacks_ok};
        sel(1, "  Multiple persona files found for '$name':");
        sel(2, "    $_") for @files;
        sel(1, "  Using first: $files[0]");
    } else {
        sel(2, "$msgpfx -- file found: $files[0]");
    }

    $persona_file = $files[0];
    unless (-e $persona_file && -r $persona_file) {
        my $msg = "$msgpfx -- Provided file not accessible: $persona_file";
        sel(0, $msg);
        die "$msg\n";
    }

    my ($persona_name) = ($persona_file =~ m|/([^/]+)$|);
    sel(2, "$msgpfx -- Persona name: $persona_name") if $persona_name;

    return $persona_file;
}

sub _get_system_content {
    my ($self) = @_;

    my $resolved = $self->{system_prompt}->resolve();

    if (!$resolved) {
        sel(2, "No system source selected; using system default");
        # Use system default
        my $default = $self->{config}->get_effective_config()->{system_string};
        return $default if $default;
        return undef;
    }

    my $source = $resolved->{source};
    my $value = $resolved->{value};
    my $provenance = $resolved->{provenance};

    sel(1, sprintf "Selected system source: %s %s=%s", $provenance, $source, $value);

    my $content;
    my $meta = {};

    if ($source eq 'file') {
        # Value should already be absolute path from resolution
        my $abs_path = $value;
        sel(2, "Using resolved system file: $abs_path");
        $content = read_file($abs_path);
        die "system-file '$abs_path' unreadable or empty\n" unless defined $content && $content ne '';
        sel(2, "Loaded system file length: " . length($content));

        # Load meta.yaml if it exists
        $meta = $self->_load_meta_yaml($abs_path);
    }
    elsif ($source eq 'str') {
        my $len = defined($value) ? length($value) : 0;
        sel(2, sprintf "Using system_string (len=%d)", $len);
        $content = $value // '';
        die "empty system string provided\n" if $content eq '';
    }
    elsif ($source eq 'persona') {
        my $ppath = $self->_resolve_persona_path($value);
        if (!defined $ppath) {
            if ($self->{_fallbacks_ok}) {
                swarnl 2, "persona '$value' was NOT resolved to a path, using fallback";
                return $self->_get_fallback_system_content();
            } else {
                die "persona '$value' not found (command failed or returned no results)\n";
            }
        } else {
            sel(2, "persona resolved => $ppath");
            $content = read_file($ppath);
            die "persona file '$ppath' unreadable or empty\n" unless defined $content && $content ne '';
            sel(2, "Loaded persona content length: " . length($content));

            # Load meta.yaml if it exists
            $meta = $self->_load_meta_yaml($ppath);
        }
    }

    # Apply thought pattern from meta.yaml if present
    if ($meta->{thought_re} && $self->{_thought}{mode} eq 'auto') {
        eval {
            my $pattern = qr/$meta->{thought_re}/s;
            $self->{_thought}{pattern} = $pattern;
            sel(1, "Applied thought pattern from meta.yaml: $meta->{thought_re}");
        };
        if ($@) {
            warn "Invalid regex in meta.yaml thought_re '$meta->{thought_re}': $@\n";
        }
    }

    # Render Xslate variables if present
    if ($content) {
        # Collect system pins as template vars
        my $sys_pins_ar = $self->{pin_mgr}->get_system_pins();
        my $pins_str    = join("\n", @$sys_pins_ar);
        my $tpl = Text::Xslate->new(type=>'text', verbose=>0);
        my $modelname = $self->{core}->get_model_info()->{name} // 'unknown-model';
        my $now = time;
        my $pin_cnt = $self->{pin_mgr}->get_pin_count("system");
        my $vars = {
            datenow_ymd   => POSIX::strftime("%Y-%m-%d", localtime($now)),
            datenow_iso   => POSIX::strftime("%Y-%m-%dT%H:%M:%S%z", localtime($now)),
            datenow_local => scalar localtime($now),
            modelname     => $modelname,
            pins          => $sys_pins_ar,   # array of system pin strings
            pins_str      => $pins_str,      # "\n" joined system pins
            pin_cnt       => $pin_cnt,
        };
        $content = $tpl->render_string($content, $vars);
    }

    sel(2, "Final system content length: " . length($content)) if defined $content;
    return $content;
}

sub _get_fallback_system_content {
    my ($self) = @_;
    sel(1, "Using system fallback content");
    return $self->{config}->get_effective_config()->{system_string};
}

sub _manage_context {
    my ($self, $messages, $max_tokens) = @_;

    # Simple token estimation (improve this later)
    my $total_tokens = 0;
    for my $msg (@$messages) {
        $total_tokens += length($msg->{content}) / 3; # rough estimate
    }

    # If under limit, return as-is
    return $messages if $total_tokens <= ($max_tokens * 0.8);

    # Otherwise, truncate history (keep system + pins + recent messages)
    my @result;
    my $keep_recent = 10; # Keep last 10 messages

    # Keep system message and pins
    for my $msg (@$messages) {
        if ($msg->{role} eq 'system' || $msg->{is_pinned}) {
            push @result, $msg;
        }
    }

    # Add recent history
    my @non_system = grep { $_->{role} ne 'system' && !$_->{is_pinned} } @$messages;
    my $start_idx = @non_system > $keep_recent ? @non_system - $keep_recent : 0;
    push @result, @non_system[$start_idx..$#non_system];

    return \@result;
}

# Pin management methods
sub pin($self, $content, $optshro=undef) {
    $optshro ||= {};
    sel 3, "Z->pin(): Adding pin";
    return $self->{pin_mgr}->add_pin($content, $optshro);
}

sub list_pins {
    my ($self) = @_;
    return $self->{pin_mgr}->list_pins();
}

sub clear_pins {
    my ($self) = @_;
    return $self->{pin_mgr}->clear_pins();
}

sub remove_pin {
    my ($self, $index) = @_;
    return $self->{pin_mgr}->remove_pin($index);
}

sub validate_pin_indices {
    my ($self, @indices) = @_;
    return $self->{pin_mgr}->validate_pin_indices(@indices);
}

sub update_pin {
    my ($self, $index, $content) = @_;
    return $self->{pin_mgr}->update_pin($index, $content);
}

# Configuration management
sub get_preset {
    my ($self) = @_;
    return $self->{config}->get_preset();
}

sub get_session_name {
    my ($self) = @_;
    return $self->{config}->get_session_name();
}

sub store_user_config($self, $optshr) {
    return $self->{config}->store_user_config($optshr);
}

sub store_session_config {
    my ($self, $optshr) = @_;
    return $self->{config}->store_session_config($optshr);
}

sub history { $_[0]{history} }

sub system  { $_[0]{system_prompt} }

sub set_thought($self, $optshr) {
    # Handle conflicts first
    if (defined $optshr->{mode} && defined $optshr->{pattern}) {
        if ($optshr->{mode} eq 'disabled' && $optshr->{pattern}) {
            die "Cannot disable thought filtering while also providing a pattern\n";
        }
    }

    if (defined $optshr->{mode}) {
        if ($optshr->{mode} eq 'disabled') {
            $self->{_thought}{mode} = 'disabled';
            $self->{_thought}{pattern} = undef;
            sel 1, "Thought filtering DISABLED - all reasoning will be shown";
        }
        elsif ($optshr->{mode} eq 'enabled') {
            $self->{_thought}{mode} = 'enabled';
            if (defined $optshr->{pattern}) {
                $self->{_thought}{pattern} = $optshr->{pattern};
                sel 1, "Thought filtering ENABLED with custom pattern";
            } else {
                $self->{_thought}{pattern} = $def_thought_re;
                sel 1, "Thought filtering ENABLED with default pattern";
            }
        }
        elsif ($optshr->{mode} eq 'auto') {
            $self->{_thought}{mode} = 'auto';
            $self->{_thought}{pattern} = undef;
            sel 1, "Thought filtering set to AUTO-DETECT from system prompt";
        }
        else {
            die "Invalid thought mode '$$optshr{mode}' - must be 'auto', 'enabled', or 'disabled'\n";
        }
    } elsif (defined $optshr->{pattern}) {
        # Pattern provided without mode - assume enabled
        if (($optshr->{pattern} // '') =~ /^\s*$/) {
            warn "Empty or whitespace-only thought pattern provided - thought filtering disabled\n";
            $self->{_thought}{mode} = 'disabled';
            $self->{_thought}{pattern} = undef;
        } else {
            $self->{_thought}{mode} = 'enabled';
            $self->{_thought}{pattern} = $optshr->{pattern};
            sel 1, "Thought filtering ENABLED with provided pattern";
        }
    }

    return $self;
}

sub _auto_detect_thought_pattern {
    my ($self, $system_content) = @_;

    return unless $self->{_thought}{mode} eq 'auto';
    return unless defined $system_content && length $system_content;

    # Look for ==== z think <pattern>
    if ($system_content =~ /^==== *z *think\s+(.+)$/m) {
        my $pattern_str = $1;
        chomp $pattern_str;
        eval {
            my $pattern = qr/$pattern_str/s;
            $self->{_thought}{pattern} = $pattern;
            sel 1, "Auto-detected thought pattern from system prompt: $pattern_str";
        };
        if ($@) {
            warn "Invalid regex in system prompt thought pattern '$pattern_str': $@\n";
        }
    }
    # Look for ==== z think (no pattern = use default)
    elsif ($system_content =~ /^==== *z *think\s*$/m) {
        $self->{_thought}{pattern} = $def_thought_re;
        sel 1, "Auto-detected default thought pattern from system prompt";
    }
}

sub _should_filter_thoughts {
    my ($self) = @_;

    return 0 if $self->{_thought}{mode} eq 'disabled';
    return 1 if $self->{_thought}{mode} eq 'enabled' && defined $self->{_thought}{pattern};
    return 1 if $self->{_thought}{mode} eq 'auto' && defined $self->{_thought}{pattern};
    return 0;
}

sub _should_stream {
    my ($self, $optshr) = @_;

    # If user explicitly requests no streaming, honor it
    return 0 if exists $optshr->{stream} && !$optshr->{stream};

    # If thought filtering is active, force non-streaming so regex can work on complete text
    return 0 if $self->_should_filter_thoughts();

    # Default to streaming
    return 1;
}

sub _apply_thought_filter {
    my ($self, $text) = @_;

    return $text unless $self->_should_filter_thoughts();

    my $pattern = $self->{_thought}{pattern};
    return $text unless defined $pattern;

    my $original_length = length($text);
    $text =~ s/$pattern//gs;
    my $filtered_length = length($text);

    if ($original_length != $filtered_length) {
        sel 2, "Filtered " . ($original_length - $filtered_length) . " characters of reasoning content";
    }

    return $text;
}

sub query($self, $user_text, $optshro=undef) {
    $optshro ||= {};
    my $print_fh;
    if (exists $optshro->{print}) {
        $print_fh = _validate_print_opt($optshro->{print});
    } elsif ($self->{_print_target}) {
        $print_fh = $self->{_print_target};
    }
    my $on_chunk = exists $optshro->{on_chunk} ? $optshro->{on_chunk} : $self->{_on_chunk};

    $self->{history}->load();

    # Get system content and auto-detect thought patterns
    my $system_content = $self->_get_system_content();
    if ($system_content) {
        sokl 2, "Adding system message, length: " . length($system_content);
        sel 3, "System content: $system_content";
    } else {
        swarnl 2, "No system content found";
    }
    $self->_auto_detect_thought_pattern($system_content);

    # Decide streaming based on thought filtering
    my $should_stream = $self->_should_stream($optshro);

    if (!$should_stream && $self->_should_filter_thoughts()) {
        sel 2, "Forcing non-streaming mode for reasoning pattern filtering";
    }

    # Build messages using the complete template functionality
    my $shims = $self->{config}->get_pin_shims();
    my $pins_msgs = $self->{pin_mgr}->build_message_array_with_shims(
        $shims,
    	{
    		sys_mode => ($self->{config}->get_pin_mode_sys() // 'vars'),
    		user_mode => ($self->{config}->get_pin_mode_user() // 'concat'),
    		ast_mode => ($self->{config}->get_pin_mode_ast() // 'concat'),
    		user_template => $self->{config}->get_pin_tpl_user(),
    		ast_template => $self->{config}->get_pin_tpl_ast(),
    	},
    );

    my @context   = @{ $self->{history}->messages() // [] };

    # Add tool results to context if provided
    if ($optshro->{tool_results}) {
        for my $tool_result (@{$optshro->{tool_results}}) {
            my $meta = { tool_name => $tool_result->{name} };
            $meta->{tool_call_id} = $tool_result->{id} if defined $tool_result->{id};
            
            push @context, {
                role => 'tool',
                content => $tool_result->{data},
                meta => $meta,
                ts => time,
                id => (@context ? ($context[-1]{id} || 0) + 1 : 1),
            };
        }
    }
    
    # Build message array - handle tool-only vs user query cases
    my @messages = (@$pins_msgs, @context);
    
    # Add user message only if we have user text
    if (defined $user_text && $user_text ne '') {
        push @messages, { role => 'user', content => $user_text };
    }

    # Add system message if we have content
    if ($system_content) {
        unshift @messages, { role => 'system', content => $system_content };
    }

    my $response_text = '';
    my $response_metadata = {};

    if ($should_stream) {
        my $cb = sub ($piece) {
            $response_text .= $piece;
            if ($on_chunk) {
                $on_chunk->($piece);
            } elsif ($print_fh) {
                print $print_fh $piece;
            }
        };
        my $result = $self->{core}->complete_request(\@messages, {
            stream => 1,
            on_chunk => $cb,
            fallbacks_ok => $self->{_fallbacks_ok},
            append_tool_calls => $optshro->{append_tool_calls}
        });

        # Extract content and metadata from result
        $response_text = $result->{content} if ref($result) eq 'HASH';
        $response_metadata = $result->{metadata} || {} if ref($result) eq 'HASH';

        # If old API (just returns string), handle gracefully
        if (ref($result) ne 'HASH') {
            $response_text = $result;
            $response_metadata = {};
        }
    } else {
        my $result = $self->{core}->complete_request(\@messages, {
            stream => 0,
            fallbacks_ok => $self->{_fallbacks_ok},
            append_tool_calls => $optshro->{append_tool_calls}
        });

        # Extract content and metadata
        if (ref($result) eq 'HASH') {
            $response_text = $result->{content};
            $response_metadata = $result->{metadata} || {};
        } else {
            # Old API compatibility
            $response_text = $result;
            $response_metadata = {};
        }

        # Apply thought filtering to complete response
        my $filtered_response = $self->_apply_thought_filter($response_text);

        # Output the filtered result
        if ($print_fh && !$on_chunk) {
            print $print_fh $filtered_response;
        }
        if ($on_chunk) {
            $on_chunk->($filtered_response);
        }

        # Use filtered version for return and storage
        $response_text = $filtered_response;
    }

    if ($response_text !~ /\n$/) {
        print $print_fh "\n";
    }

    # Store in history with metadata
    $self->{history}->append('user', $user_text, {
        request_time => $response_metadata->{request_time} || time,
    });
    $self->{history}->append('assistant', $response_text, $response_metadata);
    $self->{history}->save();

    return $response_text;
}

sub set_allow_fallbacks {
    my ($self, $v) = @_;
    $self->{_fallbacks_ok} = $v ? 1 : 0;
    return $self;
}

sub set_print($self, $target) {
    my $accept_msg = "We accept 0 (disable), 1 (*STDOUT), or a valid open file handle.";
    my $print_fh = _validate_print_opt($target);
    $self->{_print_target} = $print_fh;
    return $self;
}

sub on_chunk_set {
    my ($self, $cb) = @_;
    $self->{_on_chunk} = $cb;
    return $self;
}

sub pins_add   { $_[0]{pin_mgr}->add_pin($_[1], %{ $_[2] || {} }) }
sub pins_list  { $_[0]{pin_mgr}->list_pins() }
sub pins_wipe  { $_[0]{pin_mgr}->clear_pins() }

sub list_system_prompts {
    my ($self) = @_;
    my @files;
    my $sys_dir;
    if (exists $ENV{ZCHAT_DATADIR}) {
        my $maybe = File::Spec->catdir($ENV{ZCHAT_DATADIR}, 'sys');
        $sys_dir = $maybe if -d $maybe;
    }
    if ($sys_dir) {
        opendir(my $dh, $sys_dir);
        @files = sort grep { $_ !~ /^\./ && -f File::Spec->catfile($sys_dir, $_) } readdir($dh);
        closedir $dh;
    }
    my @personas;
    my $plist = `persona --list 2>/dev/null`;
    if ($? == 0 && defined $plist) {
        @personas = grep { length } map { chomp; $_ } split(/\n/, $plist);
    }
    return { files => \@files, personas => \@personas, dir => $sys_dir };
}

sub _validate_print_opt($target) {
    # Target: 0(silent), 1(*STDOUT), or an open GLOB/IO handle
    my $accept_msg = "We accept 0 (disable), 1 (*STDOUT), or a valid open file handle.";
    my $print_fh;
    die "Undefined target passed to set_print(). $accept_msg" if !defined $target;
    if ($target eq 1) {
        $print_fh = *STDOUT;
    } elsif ($target eq 0) {
        $print_fh = undef; # Silent
    } elsif (!openhandle $target) {
        die "Unexpected value passed as target of set_print() '$target'. $accept_msg";
    } else { $print_fh = $target;   # GLOB/IO handle
    }
    return $print_fh;
}

sub history_owrite_last($self, $payload, $optshro=undef) {
    $self->{history}->owrite_last($payload, $optshro); # Pass $optshro without ||= {}
    $self->{history}->save();
    return $self;
}

sub show_status {
    my ($self, $verbose_level) = @_;
    $verbose_level //= 0;

    my $def_abbr_sysstr = 30;

    # Load the configuration if not already loaded
    $self->{config}->load_effective_config($self->{_resolved_cli_options});

    my $status_info = eval { $self->{config}->get_status_info() };
    if ($@) {
        serr "Failed to collect status information: $@";
        return;
    }

    # Header
    say "${a_stat_actline}ZChat Configuration Status$rst";
    say "Session: " . $self->get_session_name();
    say "";

    say "${a_stat_actline}* Precedence:$rst";

    # System prompt precedence
    $self->_show_precedence_section("System prompt", 
        $status_info->{precedence}{system_prompt}, $verbose_level, $def_abbr_sysstr);

    # Session precedence
    $self->_show_precedence_section("Session",
        $status_info->{precedence}{session}, $verbose_level, $def_abbr_sysstr);

    say "${a_stat_actline}* Sources:$rst";

    # Sources view
    for my $source_name (qw(CLI SHELL SESSION USER SYSTEM)) {
        my $source_data = $status_info->{sources}{$source_name};
        next unless $source_data && keys %$source_data;

        my $location = $status_info->{file_locations}{$source_name} || '';
        say "  - $source_name" . ($location ? ": $location" : "");

        # Show file existence status for file-based sources
        if ($source_name =~ /^(SESSION|USER|SHELL)$/ && $location && $location ne 'system defaults') {
            my $exists = -e $location ? "${a_stat_exists}[exists]$rst" : "${a_stat_undeftag}[missing]$rst";
            say "    File: $exists";
        }

        for my $key (sort keys %$source_data) {
            my $value = $source_data->{$key};

            # Truncate long values unless -vv
            if (($key eq 'system_string' || length($value) > 50) && $verbose_level < 2) {
                $value = substr($value, 0, $def_abbr_sysstr) . ".." if length($value) > $def_abbr_sysstr;
            }

            # Determine if this setting is actually being used
            my $is_used = $self->{config}->_is_setting_used($source_name, $key, $status_info);
            my $usage_tag = $is_used ? "${a_stat_acttag}[used]$rst" : "${a_stat_undeftag}[unused]$rst";

            say "    $key: '$value' $usage_tag";
        }
        say "";
    }
}

sub _show_precedence_section {
    my ($self, $section_name, $precedence_items, $verbose_level, $def_abbr_sysstr) = @_;

    return unless $precedence_items && @$precedence_items;

    say "  - $section_name";
    my $indent = "   ";

    for my $item (@$precedence_items) {
        my $active_marker = $item->{active} ? 
            "${a_stat_acttag}[active]$rst" : "${a_stat_undeftag}[unused]$rst";
        my $value = $item->{value} // 'undef';

        # Truncate system strings unless -vv
        if ($item->{type} eq 'system_string' && $verbose_level < 2) {
            $value = substr($value, 0, $def_abbr_sysstr) . ".." if length($value) > $def_abbr_sysstr;
        }

        # Format the line based on whether it's active
        my $arrow = $item->{active} ? "<-" : " <-";
        my $source_info = "$item->{source}";
        $source_info .= "($item->{type})" if $item->{type} ne 'session';

        if ($item->{active}) {
            say "${indent}$arrow $source_info = \"${a_stat_actval}${value}$rst\" $active_marker";
        } else {
            say "${indent}$arrow $source_info = '$value' $active_marker";
        }

        # Show location for non-CLI sources
        if ($item->{location} && $item->{location} ne 'command line' && $item->{location} ne 'system defaults') {
            say "${indent}    Loc: $item->{location}";
        }

        $indent .= " ";
    }
    say "";
}

sub validate_status_display {
    my ($self) = @_;

    # Check if session directory exists
    my $session_dir = $self->_get_session_dir();
    my $session_exists = $session_dir && -d $session_dir;

    # Check if required config files are readable
    my $user_config_readable = -r $self->_get_user_config_path();

    return {
        session_dir_exists => $session_exists,
        user_config_readable => $user_config_readable,
        current_session => $self->get_session_name(),
    };
}

sub clear_user_system {
    my ($self) = @_;
    my $config = $self->{config}->_load_user_config() || {};
    delete $config->{system_string};
    delete $config->{system_file};
    delete $config->{system_persona};
    delete $config->{system};
    return $self->{config}->store_user_config($config, { owrite => 1 } );
}

sub clear_session_system {
    my ($self) = @_;
    my $config = $self->{config}->_load_session_config() || {};
    delete $config->{system_string};
    delete $config->{system_file};
    delete $config->{system_persona};
    delete $config->{system};
    return $self->{config}->store_session_config($config, { owrite => 1 } );
}
sub clear_session_user {
    my ($self) = @_;
    my $config = $self->{config}->_load_user_config() || {};
    delete $config->{session};
    return $self->{config}->store_user_config($config, { owrite => 1 } );
}

sub clear_shell_session {
    my ($self) = @_;
    my $config = $self->{config}->_load_shell_config() || {};
    delete $config->{session};
    return $self->{config}->store_shell_config($config, { owrite => 1 } );
}
sub clear_shell_system {
    my ($self) = @_;
    my $config = $self->{config}->_load_shell_config() || {};
    delete $config->{system_string};
    delete $config->{system_file};
    delete $config->{system_persona};
    delete $config->{system};
    return $self->{config}->store_shell_config($config, { owrite => 1 } );
}


sub del_user_config {
    my $config_file = ZChat::Config::get_user_config_path();
    if (-f $config_file) {
        return unlink($config_file);
    }
    return 1;
}

sub del_session_config {
    my ($session_name) = @_;
    my $session_dir = ZChat::Config::get_session_dir($session_name);
    if (-d $session_dir) {
        return File::Path::remove_tree($session_dir);
    }
    return 1;
}

sub del_shell_config {
    my ($override_pproc) = @_;
    my $shell_file = ZChat::Config::get_shell_config_file($override_pproc);
    if (-f $shell_file) {
        return unlink($shell_file);
    }
    return 1;
}

sub wipe_session_history {
    my ($session_name) = @_;
    
    return 0 unless $session_name;
    
    # Create minimal storage object just for this operation
    my $storage = ZChat::Storage->new();
    return $storage->wipe_history($session_name);
}

sub get_resolved_cli_options {
    my ($self) = @_;

    # Return the resolved CLI options that were processed in _load_config
    return $self->{_resolved_cli_options} || {};
}

1;

__END__

=head1 NAME

ZChat - Perl interface to LLM chat completions with session management

=head1 SYNOPSIS

    use ZChat;

    # Simple usage
    my $z = ZChat->new();
    my $response = $z->complete_request("Hello, how are you?");

    # With session and preset
    my $z = ZChat->new(
        session => "myproject/analysis",
        preset => "helpful-assistant"
    );

    # Pin management
    $z->pin("You are an expert in Perl programming.");
    $z->pin("Use code blocks for examples.", role => 'user');
    my $pins = $z->list_pins();

    # Configuration storage. old.. needs updating
    $z->store_user_config({ preset => "default" });
    $z->store_session_config({preset => "coding-assistant"});

=head1 DESCRIPTION

ZChat provides a clean interface to LLM APIs with session management,
conversation history, pinned messages, and preset system prompts.

=cut
