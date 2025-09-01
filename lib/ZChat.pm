package ZChat;

use v5.34;
use warnings;
use utf8;

use ZChat::Core;
use ZChat::Config;
use ZChat::Storage;
use ZChat::Pin;
use ZChat::Preset;

our $VERSION = '1.0.0';

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        session_name => $opts{session} // '',
        preset => $opts{preset},
        system_prompt => $opts{system_prompt},
        system_file => $opts{system_file},
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
    $self->{pin_mgr} = ZChat::Pin->new(
        storage => $self->{storage},
        session_name => $self->{session_name}
    );
    $self->{preset_mgr} = ZChat::Preset->new(
        storage => $self->{storage}
    );
    $self->{core} = ZChat::Core->new();
    
    # Load effective configuration
    $self->_load_config(%opts);
    $DB::single=1;
    $self->{session_name} = $self->{config}->get_effective_session_name();

    return $self;
}

sub _load_config {
    my ($self, %opts) = @_;
    
    my $config = $self->{config}->load_effective_config(
        preset => $opts{preset},
        system_prompt => $opts{system_prompt},
        system_file => $opts{system_file},
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
        push @messages, {
            role => 'system',
            content => $system_content
        };
    }
    
    # 2. Add pinned messages in order
    my $pinned_messages = $self->{pin_mgr}->build_message_array();
    push @messages, @$pinned_messages;
    
    # 3. Add conversation history
    my $history = $self->{storage}->load_history($self->{session_name});
    push @messages, @$history if $history;
    
    # 4. Add current user input
    push @messages, {
        role => 'user',
        content => $user_input
    };
    
    return \@messages;
}

sub _get_system_content {
    my ($self) = @_;
    
    my $config = $self->{config};
    my $content = '';
    
    # From preset
    if ($config->{preset}) {
        my $preset_content = $self->{preset_mgr}->resolve_preset($config->{preset});
        $content .= $preset_content if $preset_content;
    }
    
    # From system file
    if ($config->{system_file}) {
        my $file_content = $self->{storage}->read_file($config->{system_file});
        $content .= "\n" . $file_content if $file_content;
    }
    
    # From direct system prompt
    if ($config->{system_prompt}) {
        $content .= "\n" . $config->{system_prompt};
    }
    
    return $content || undef;
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
    return $self->{config}->{preset};
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
