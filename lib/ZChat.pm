package ZChat;
use v5.34;
use warnings;
use utf8;
use File::Spec;

use ZChat::Core;
use ZChat::Config;
use ZChat::Storage;
use ZChat::Pin;
use ZChat::Preset;
use ZChat::Utils ':all';

our $VERSION = '1.0.0';

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        session_name => ($opts{session} // ''),
        preset => $opts{preset},
        system_prompt => $opts{system_prompt},
        system_file => $opts{system_file},
        pin_shims => $opts{pin_shims},
        config => undef,
        core => undef,
        storage => undef,
        pin_mgr => undef,
        preset_mgr => undef,
    };
    
    bless $self, $class;
    
    # Initialize components
    $self->{storage} = ZChat::Storage->new();
    $self->{config} = ZChat::Config->new(
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

	# Presets setup
    my %preset_opts = (
    	storage => $self->{storage},
	);
	if (exists $ENV{ZCHAT_DATADIR}) {
		my $data_dir = File::Spec->catdir($ENV{ZCHAT_DATADIR}, 'sys');
		if ($data_dir ne '' && -d $data_dir) {
			$preset_opts{data_dir} = $data_dir;
		} else {
			$preset_opts{data_dir} = undef;
		}
	}
    $self->{preset_mgr} = ZChat::Preset->new(%preset_opts);

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

sub complete {
    my ($self, $user_input, %opts) = @_;
    
    # Build complete message array with pins
    my $messages = $self->_build_messages($user_input, %opts);
    
    # Get model info for context management
    my $model_info = $self->{core}->get_model_info();
    my $max_tokens = $model_info->{n_ctx} // 8192;
    
    # Truncate history if needed
    $messages = $self->_manage_context($messages, $max_tokens);
    
    # Make completion request
    return $self->{core}->complete_request($messages, %opts);
}

sub _build_messages {
    my ($self, $user_input, %opts) = @_;
    
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

    # Determine source precedence: CLI > session > user > preset
    my %src = (
        cli     => { file => $cfg->{_cli_system_file},  prompt => $cfg->{_cli_system_prompt} },
        session => { file => $cfg->{system_file_session}, prompt => $cfg->{system_prompt_session} },
        user    => { file => $cfg->{system_file_user},   prompt => $cfg->{system_prompt_user} },
    );

    # Prefer file over prompt at the same level
    for my $level (qw(cli session user)) {
        if ($src{$level}{file}) {
            return ($level, file   => $src{$level}{file});
        }
        if ($src{$level}{prompt}) {
            return ($level, prompt => $src{$level}{prompt});
        }
    }
    return ('preset', preset => $cfg->{preset}); # fallback
}

sub _get_system_content {
    my ($self) = @_;
    
    my ($level, $kind, $val) = $self->_select_system_source();
    my $content = '';
    
    if ($level eq 'preset') {
        if ($val) {
            sel(2, "Selected system content from PRESET: '$val'");
            my $preset_content = $self->{preset_mgr}->resolve_preset($val);
            if ($preset_content) {
                sel(2, "Got preset content, length: " . length($preset_content));
                $content = $preset_content;
            } else {
                sel(2, "Preset '$val' not found; empty system content");
            }
        } else {
            sel(2, "No preset configured; empty system content");
        }
    } else {
        if ($kind eq 'file') {
            sel(2, sprintf "Selected system content from %s: system_file=%s (overrides lower levels)", uc($level), $val);
            my $file_content = read_file($val);
            $content = defined $file_content ? $file_content : '';
            sel(2, "Loaded system file length: " . length($content));
        } else { # prompt
            my $len = defined($val) ? length($val) : 0;
            sel(2, sprintf "Selected system content from %s: system_prompt (len=%d) (overrides lower levels)", uc($level), $len);
            $content = $val // '';
        }
    }

    my $final = $content ne '' ? $content : undef;
    sel(2, $final ? "Final system content length: " . length($final) : "No final system content");

    if ($final) {
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
        $final = $tpl->render_string($final, $vars);
    }

    return $final;
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
    my ($self, $content, %opts) = @_;
    return $self->{pin_mgr}->add_pin($content, %opts);
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

1;

__END__

=head1 NAME

ZChat - Perl interface to LLM chat completions with session management

=head1 SYNOPSIS

    use ZChat;
    
    # Simple usage
    my $z = ZChat->new();
    my $response = $z->complete("Hello, how are you?");
    
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
