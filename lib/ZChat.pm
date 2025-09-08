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

use ZChat::Core;
use ZChat::Config;
use ZChat::Storage;
use ZChat::Pin;
use ZChat::Utils ':all';
use ZChat::History;
use ZChat::SystemPrompt;

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
    $self->_load_config(%opts);
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
    my ($self, %opts) = @_;
    return $self->{config}->store_shell_config(%opts);
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

sub _load_config {
    my ($self, %opts) = @_;

    my $config = $self->{config}->load_effective_config( {
        preset => $opts{preset},
        system_prompt => $opts{system_prompt},
        system_file => $opts{system_file},
        pin_shims => $opts{pin_shims},
        pin_sys_mode => $opts{pin_sys_mode},
	} );
}

# This is old. I'm including it only because we had some more messages
# in it good for diags but i need to maybe get those into ->query()
sub _build_messages($self, $user_input, $opts=undef) {
    $opts ||= {};

    my @messages;

    # 1. System message from preset/config
    my $system_content = $self->_get_system_content();
    if ($system_content) {
        sel(2, "Adding system message, length: " . length($system_content));
        sel(3, "System content: $system_content");
        push @messages, {
            role => 'system',
            content => $system_content
        };
    } else {
        sel(2, "No system content found");
    }

    # 2. Enforce pin limits then add pinned messages (with shims and templates)
    my $limits = $self->{config}->get_pin_limits();
    $self->{pin_mgr}->enforce_pin_limits($limits);
    my $shims  = $self->{config}->get_pin_shims();
    my $pinned_messages = $self->{pin_mgr}->build_message_array_with_shims(
        $shims,
		{
			sys_mode => ($self->{config}->get_pin_mode_sys() // 'vars'),
			user_mode => ($self->{config}->get_pin_mode_user() // 'concat'),
			ast_mode => ($self->{config}->get_pin_mode_ast() // 'concat'),
			user_template => $self->{config}->get_pin_tpl_user(),
			ast_template => $self->{config}->get_pin_tpl_ast(),
		},
    );
    if (@$pinned_messages) {
        sel(2, "Adding " . @$pinned_messages . " pinned messages");
        push @messages, @$pinned_messages;
    }

    # 3. Add conversation history
    my $history = $self->{storage}->load_history($self->{session_name});
    if ($history && @$history) {
        sel(2, "Adding " . @$history . " history messages");
        push @messages, @$history;
    } else {
        sel(2, "No conversation history found");
    }

    # 4. Add current user input
    sel(2, "Adding user input: $user_input");
    push @messages, {
        role => 'user',
        content => $user_input
    };

    sel(2, "Built message array with " . @messages . " total messages");

    return \@messages;
}

sub _select_system_source {
    my ($self) = @_;
    my $cfg = $self->{config}->get_effective_config();

    # Determine source precedence across scopes: CLI > session > user
    # Intra-scope priority: file > str > persona
    my @levels = (
        { lvl => 'CLI',     file => $cfg->{_cli_system_file},     str => $cfg->{_cli_system_str},     persona => $cfg->{_cli_system_persona} },
        { lvl => 'SESSION', file => $cfg->{system_file_session},  str => $cfg->{system_prompt_session}, persona => $cfg->{system_persona_session} },
        { lvl => 'USER',    file => $cfg->{system_file_user},     str => $cfg->{system_prompt_user},  persona => $cfg->{system_persona_user} },
    );

    for my $L (@levels) {
        if ($L->{file})    { return ($L->{lvl}, file    => $L->{file}); }
        if ($L->{str})     { return ($L->{lvl}, str     => $L->{str}); }
        if ($L->{persona}) { return ($L->{lvl}, persona => $L->{persona}); }
    }
    return ('NONE');
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

# sub _BAD_REMOVE_ME_resolve_persona_path {
#     my ($self, $name) = @_;
#     my @cmd = ($bin_persona, '--path', 'find', $name);
#     my $cmd = shell_quote(@cmd);
#     sel 1, "RESOLVE system prompt -- ATTEMPT with persona. Cmd: `$cmd`";
#     my $path = `$cmd`;
#     chomp $path if defined $path;
#     die "persona '$name' not found (command: $cmd)\n" unless defined $path && $path ne '' && -f $path;
#     return $path;
# }

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

# sub trying_to_make_new_resolve_persona_path {
#     my ($self, $name);
#     if (!defined $bin_persona) {
#         sel 1, "No \$bin_persona path is defined in ZChat.pm\n";
#         return undef;
#     }
#     my @cmd = ($bin_persona, '--path', 'find', $name);
#     my $cmd = shell_quote(@cmd);
#     sel 1, "RESOLVE system prompt -- ATTEMPT with 'persona'. Cmd: `$cmd`";
#     sel(1, "  Command: $cmd");
#     my $paths;
#     eval { $paths =`$cmd`; }; # No, let's use Capture::Tiny
#     ..... you can ignore all the specifics of variable names and make it consistent with our current project code, message style, sel levels, etc. But clean it up and make it better. If we have access to 'fallbacks_ok' we should use the first line (the first persona path)!



#     chomp $paths if defined $paths;
#     sel(1, "Loading Persona from disk with persona command");
#     if ($? != 0) {
#         sel(1, "'persona' bin ($bin_persona) wasn't found or command errored");
#         return undef;

#     }
#     sel(3, "  persona provided:");
#     sel(3, "    {{$output}}");
#     # Check if command succeeded and found files
#     return undef if !defined $output || $output eq '';
#     my @files = split /\n/, $output;
#     return undef unless @files;
#     if (@files > 1) {
#         sel(1, "Multiple persona files found for '$preset_name':");
#         sel(1, "  $_") for @files;
#         sel(1, "Using first: $files[0]");
#     }
#     my $persona_file = $files[0];
#     return undef unless -e $persona_file && -r $persona_file;
#     sel(1, "Preset (persona file) found: $persona_file");
#     my ($persona_name) = $persona_file =~ m|/([^/]+)$|;
#     sel(1, "Preset persona name: $persona_name");
#     my $content = $self->_load_file_preset($persona_file);
#     sel(2, "Preset persona content length: " . length($content)) if defined $content;
#     return $content;
# }


sub _get_system_content {
    my ($self) = @_;

    my $resolved = $self->{system_prompt}->resolve();

    if (!$resolved) {
        sel(2, "No system source selected; system message will be empty");
        return undef;
    }

    my $source = $resolved->{source};
    my $value = $resolved->{value};
    my $provenance = $resolved->{provenance};

    sel(1, sprintf "Selected system source: %s %s=%s", $provenance, $source, $value);

    my $content;

    if ($source eq 'file') {
        my $abs = $self->_resolve_system_file($value);
        sel(2, "Resolved system_file => $abs");
        $content = read_file($abs);
        die "system-file '$abs' unreadable or empty\n" unless defined $content && $content ne '';
        sel(2, "Loaded system file length: " . length($content));
    }
    elsif ($source eq 'str') {
        my $len = defined($value) ? length($value) : 0;
        sel(2, sprintf "Using system_str (len=%d)", $len);
        $content = $value // '';
        die "empty system string provided\n" if $content eq '';
    }
    elsif ($source eq 'persona') {
        my $ppath = $self->_resolve_persona_path($value);
        sel(2, "persona resolved => $ppath");
        $content = read_file($ppath);
        die "persona file '$ppath' unreadable or empty\n" unless defined $content && $content ne '';
        sel(2, "Loaded persona content length: " . length($content));
    }

    # Render Xslate variables if present (no concatenation)
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
sub pin($self, $content, $opts=undef) {
    $opts ||= {};
    sel 3, "Z->pin(): Adding pin";
    return $self->{pin_mgr}->add_pin($content, $opts);
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

# Configuration management
sub get_preset {
    my ($self) = @_;
    return $self->{config}->get_preset();
}

sub get_session_name {
    my ($self) = @_;
    return $self->{config}->get_session_name();
}


sub store_user_config {
    my ($self, %opts) = @_;
    return $self->{config}->store_user_config(%opts);
}

sub store_session_config {
    my ($self, %opts) = @_;
    return $self->{config}->store_session_config(%opts);
}

sub history { $_[0]{history} }

sub system  { $_[0]{system_prompt} }

sub set_thought {
    my ($self, %opts) = @_;

    # Handle conflicts first
    if (defined $opts{mode} && defined $opts{pattern}) {
        if ($opts{mode} eq 'disabled' && $opts{pattern}) {
            die "Cannot disable thought filtering while also providing a pattern\n";
        }
    }

    if (defined $opts{mode}) {
        if ($opts{mode} eq 'disabled') {
            $self->{_thought}{mode} = 'disabled';
            $self->{_thought}{pattern} = undef;
            sel 1, "Thought filtering DISABLED - all reasoning will be shown";
        }
        elsif ($opts{mode} eq 'enabled') {
            $self->{_thought}{mode} = 'enabled';
            if (defined $opts{pattern}) {
                $self->{_thought}{pattern} = $opts{pattern};
                sel 1, "Thought filtering ENABLED with custom pattern";
            } else {
                $self->{_thought}{pattern} = $def_thought_re;
                sel 1, "Thought filtering ENABLED with default pattern";
            }
        }
        elsif ($opts{mode} eq 'auto') {
            $self->{_thought}{mode} = 'auto';
            $self->{_thought}{pattern} = undef;
            sel 1, "Thought filtering set to AUTO-DETECT from system prompt";
        }
        else {
            die "Invalid thought mode '$opts{mode}' - must be 'auto', 'enabled', or 'disabled'\n";
        }
    }
    elsif (defined $opts{pattern}) {
        # Pattern provided without mode - assume enabled
        if (($opts{pattern} // '') =~ /^\s*$/) {
            warn "Empty or whitespace-only thought pattern provided - thought filtering disabled\n";
            $self->{_thought}{mode} = 'disabled';
            $self->{_thought}{pattern} = undef;
        } else {
            $self->{_thought}{mode} = 'enabled';
            $self->{_thought}{pattern} = $opts{pattern};
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
    my ($self, $opts) = @_;

    # If user explicitly requests no streaming, honor it
    return 0 if defined $opts->{stream} && !$opts->{stream};

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

sub query($self, $user_text, $opts=undef) {
    $opts ||= {};
    my $print_fh;
    if (exists $opts->{print}) {
        $print_fh = _validate_print_opt($opts->{print});
    } elsif ($self->{_print_target}) {
        $print_fh = $self->{_print_target};
    }
    my $on_chunk = exists $opts->{on_chunk} ? $opts->{on_chunk} : $self->{_on_chunk};

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
    my $should_stream = $self->_should_stream($opts);

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
    my @messages  = (@$pins_msgs, @context, { role => 'user', content => $user_text });

    # Add system message if we have content
    if ($system_content) {
        unshift @messages, { role => 'system', content => $system_content };
    }

    my $raw_response = '';

    if ($should_stream) {
        my $cb = sub ($piece) {
            $raw_response .= $piece;
            if ($on_chunk) {
                $on_chunk->($piece);
            } elsif ($print_fh) {
                print $print_fh $piece;
            }
        };
        $self->{core}->complete_request(\@messages, {
            stream => 1,
            on_chunk => $cb,
            fallbacks_ok => $self->{_fallbacks_ok}
        });
    } else {
        $raw_response = $self->{core}->complete_request(\@messages, {
            stream => 0,
            fallbacks_ok => $self->{_fallbacks_ok}
        });

        # Apply thought filtering to complete response
        my $filtered_response = $self->_apply_thought_filter($raw_response);

        # Output the filtered result
        if ($print_fh && !$on_chunk) {
            print $print_fh $filtered_response;
        }
        if ($on_chunk) {
            $on_chunk->($filtered_response);
        }

        # Use filtered version for return and storage
        $raw_response = $filtered_response;
    }
    if ($raw_response !~ /\n$/) {
        print $print_fh "\n";
    }

    # Store in history
    $self->{history}->append('user', $user_text);
    $self->{history}->append('assistant', $raw_response);
    $self->{history}->save();

    return $raw_response;
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

sub history_owrite_last {
    my ($self, @args) = @_;
    $self->{history}->owrite_last(@args);
    $self->{history}->save();
    return $self;
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

    # Configuration storage
    $z->store_user_config(preset => "default");
    $z->store_session_config(preset => "coding-assistant");

=head1 DESCRIPTION

ZChat provides a clean interface to LLM APIs with session management,
conversation history, pinned messages, and preset system prompts.

=cut
