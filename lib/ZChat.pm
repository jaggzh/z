package ZChat;
use v5.26.3;
use feature 'say';
use experimental 'signatures';
use strict;
use warnings;

use utf8;
use File::Spec;

use ZChat::Core;
use ZChat::Config;
use ZChat::Storage;
use ZChat::Pin;
use ZChat::Utils ':all';
use ZChat::History;
use ZChat::SystemPrompt;

our $VERSION = '1.1.0';

my $def_thought_re = qr{(?:<think>)?.*?<\/think>\s*};

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        session_name => ($opts{session} // ''),
        system       => $opts{system},
        system_prompt=> $opts{system_prompt},
        system_file  => $opts{system_file},
        pin_shims    => $opts{pin_shims},
        config       => undef,
        core         => undef,
        storage      => undef,
        pin_mgr      => undef,
        history      => undef,
        _thought     => { enabled => 1, pattern => qr/(?:<think>)?.*?<\/think>\s*/s },
        _fallbacks_ok => 0,
        _print_target    => undef,   # undef (silent) | *FH
        _on_chunk        => undef,   # optional streaming callback
    };
    
    bless $self, $class;
    
    $self->{storage} = ZChat::Storage->new();
    $self->{config}  = ZChat::Config->new(
        storage => $self->{storage},
        session_name => $self->{session_name}
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
    
    my $config = $self->{config}->load_effective_config(
        preset => $opts{preset},
        system_prompt => $opts{system_prompt},
        system_file => $opts{system_file},
        pin_shims => $opts{pin_shims},
        pin_sys_mode => $opts{pin_sys_mode},
    );
}

# # High level is handled through ->query(). Remove this
# sub complete {
#     my ($self, $user_input, $opts={}) = @_;
    
#     # Build complete message array with pins
#     my $messages = $self->_build_messages($user_input, $opts);
    
#     # Get model info for context management
#     my $model_info = $self->{core}->get_model_info();
#     my $max_tokens = $model_info->{n_ctx} // 8192;
    
#     # Truncate history if needed
#     $messages = $self->_manage_context($messages, $max_tokens);
    
#     # Make completion request
#     return $self->{core}->complete_request($messages, $opts);
# }

sub _build_messages($self, $user_input, $opts={}) {
    
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
    
    # 2. Enforce pin limits then add pinned messages (with shims)
    my $limits = $self->{config}->get_pin_limits();
    $self->{pin_mgr}->enforce_pin_limits($limits);
    my $shims  = $self->{config}->get_pin_shims();
    my $pinned_messages = $self->{pin_mgr}->build_message_array_with_shims(
        $shims,
        sys_mode => ($self->{config}->get_pin_sys_mode() // 'vars'),
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

sub _resolve_persona_path {
    my ($self, $name) = @_;
    my $cmd = "persona --path find " . $name;
    my $path = `$cmd`;
    chomp $path if defined $path;
    die "persona '$name' not found (command: $cmd)\n" unless defined $path && $path ne '' && -f $path;
    return $path;
}

sub _get_system_content {
    my ($self) = @_;
    
    my ($level, $kind, $val) = $self->_select_system_source();
    my $content;

    if ($level eq 'NONE') {
        sel(2, "No system source selected; system message will be empty");
        return undef;
    }

    if ($kind eq 'file') {
        sel(2, sprintf "Selected system source: %s system_file=%s", $level, $val);
        my $abs = $self->_resolve_system_file($val);
        sel(2, "Resolved system_file => $abs");
        $content = read_file($abs);
        die "system-file '$abs' unreadable or empty\n" unless defined $content && $content ne '';
        sel(2, "Loaded system file length: " . length($content));
    }
    elsif ($kind eq 'str') {
        my $len = defined($val) ? length($val) : 0;
        sel(2, sprintf "Selected system source: %s system_str (len=%d)", $level, $len);
        $content = $val // '';
        die "empty --system-str provided\n" if $content eq '';
    }
    elsif ($kind eq 'persona') {
        sel(2, sprintf "Selected system source: %s system_persona=%s", $level, $val);
        my $ppath = $self->_resolve_persona_path($val);
        sel(2, "persona resolved => $ppath");
        $content = read_file($ppath);
        die "persona file '$ppath' unreadable or empty\n" unless defined $content && $content ne '';
        sel(2, "Loaded persona content length: " . length($content));
    }

    # Render Xslate variables if present (no concatenation)
    if ($content) {
        require Text::Xslate;
        require POSIX;
        # Collect system pins as template vars
        my $sys_pins_ar = $self->{pin_mgr}->get_system_pins();
        my $pins_str    = join("\n", @$sys_pins_ar);
        my $tpl = Text::Xslate->new(type=>'text', verbose=>0);
        my $modelname = $self->{core}->get_model_info()->{name} // 'unknown-model';
        my $now = time;
        my $vars = {
            datenow_ymd   => POSIX::strftime("%Y-%m-%d", localtime($now)),
            datenow_iso   => POSIX::strftime("%Y-%m-%dT%H:%M:%S%z", localtime($now)),
            datenow_local => scalar localtime($now),
            modelname     => $modelname,
            pins          => $sys_pins_ar,   # array of system pin strings
            pins_str      => $pins_str,      # "\n" joined system pins
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
sub pin {
    my ($self, $content, $opts) = @_;
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
    my ($self, $opts) = @_;
	if (($opts->{pattern}//'') eq /^\s*$/) {
		sel 0, "Empty/undef/whitespace thought pattern provided. Thought removal has been disabled and streaming may be active.";
		$self->{_thought}{enabled} = 0;
		$self->{_thought}{pattern} = undef;
	} else {
		if ($opts->{pattern} // 0) { # Pattern provided
			$self->{_thought}{pattern} = $opts->{pattern};
			$self->{_thought}{enabled} = 1;
		} elsif (exists $self->{_thought}{enabled}) {
			sel 1, "Default thought pattern enabled ($def_thought_re)";
			$self->{_thought}{pattern} = $def_thought_re;
			$self->{_thought}{enabled} = 1;
		}
	}
    return $self;
}

sub set_allow_fallbacks {
    my ($self, $v) = @_;
    $self->{_fallbacks_ok} = $v ? 1 : 0;
    return $self;
}

sub set_print($self, $target) {
	my $accept_msg = "We accept 0 (disable), 1 (*STDOUT), or a valid open file handle.";
	my $print_fh = _validate_print_opt($target);
    $self->{_print_target} = $target;   # GLOB/IO handle
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

sub _apply_thought_filter {
    my ($self, $text) = @_;
    return $text unless $self->{_thought}{enabled};
    my $re = $self->{_thought}{pattern} // qr/(?:<think>)?.*?<\/think>\s*/s;
    $text =~ s/$re//g;
    return $text;
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

sub query($self, $user_text, $opts={}) {
    my $print_fh;
    if (exists $opts->{print}) {
		$print_fh = _validate_fh($opts->{print});
	}
    my $on_chunk = exists $opts->{on_chunk} ? $opts->{on_chunk} : $self->{_on_chunk};
    my $stream   = $opts->{stream} ? 1 : 0;

    if ($stream && $self->{_thought}{enabled} && defined $self->{_thought}{pattern}) {
        # Too common to revert to non-streaming. We won't notify.
        if ($self->{_fallbacks_ok}) {
            # warn "$msg\n";
            $stream = 0;
        }
    }

    $self->{history}->load();

    my $resolved = $self->{system_prompt}->resolve();
    if ($resolved && $resolved->{source} eq 'str') {
        # no file IO needed; ok
    }

    my $pins_msgs = $self->{pin_mgr}->build_message_array();
    my @context   = @{ $self->{history}->messages() // [] };
    my @messages  = (@$pins_msgs, @context, { role => 'user', content => $user_text });

    my $accum = '';
    if ($stream) {
        my $cb = sub ($piece) {
            $accum .= $piece;
            if ($on_chunk) {
                $on_chunk->($piece);
            } elsif ($print_fh) {
                print $print_fh $piece;
            }
        };
        $self->{core}->complete_request(\@messages, { on_chunk => $cb, fallbacks_ok => $self->{_fallbacks_ok} });
    } else {
        my $full = $self->{core}->complete_request(\@messages, { fallbacks_ok => $self->{_fallbacks_ok} });
        $accum = $full;
        if ($print_fh && !$on_chunk) {
            print $print_fh $accum;
        }
    }

    my $clean = $self->_apply_thought_filter($accum);

    $self->{history}->append('user', $user_text);
    $self->{history}->append('assistant', $clean);
    $self->{history}->save();

    return $clean;
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
