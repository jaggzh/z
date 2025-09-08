package ZChat::Pin;
use v5.26.3;
use feature 'say';
use experimental 'signatures';
use strict;
use warnings;
use Text::Xslate;

use utf8;

sub new {
    my ($class, %opts) = @_;

    my $self = {
        storage => ($opts{storage} // die "storage required"),
        session_name => ($opts{session_name} // ''),
        pins => [],
        loaded => 0,
    };

    bless $self, $class;
    return $self;
}

sub set_session_name { my ($self,$n)=@_; $self->{session_name}=$n; }

sub _load_pins {
    my ($self) = @_;
    return if $self->{loaded};
    $self->{pins} = $self->{storage}->load_pins($self->{session_name});
    $self->{loaded} = 1;
}

sub add_pin($self, $content, $opts=undef) {
    $opts ||= {};

    return 0 unless defined $content && $content ne '';

    $self->_load_pins();

    # Set defaults
    my $role = $opts->{role} || 'system';
    my $method = $opts->{method} || 'concat';

    # Validate role
    unless ($role =~ /^(system|user|assistant)$/) {
        warn "Invalid pin role '$role', using 'system'";
        $role = 'system';
    }

    # Validate method
    unless ($method =~ /^(concat|msg)$/) {
        warn "Invalid pin method '$method', using 'concat'";
        $method = 'concat';
    }

    # Create pin object
    my $pin = {
        content => $content,
        role => $role,
        method => $method,
        timestamp => time(),
    };

    push @{$self->{pins}}, $pin;

    # Save to storage
    return $self->_save_pins();
}

sub list_pins {
    my ($self) = @_;

    $self->_load_pins();

    return [@{$self->{pins}}];  # Return copy
}

sub clear_pins {
    my ($self) = @_;

    $self->{pins} = [];
    $self->{loaded} = 1;

    return $self->_save_pins();
}

sub clear_pins_by_role {
    my ($self, $role) = @_;
    return 0 unless $role && $role =~ /^(system|user|assistant)$/;
    $self->_load_pins();
    my $before = scalar @{$self->{pins}};
    $self->{pins} = [ grep { $_->{role} ne $role } @{$self->{pins}} ];
    $self->{loaded} = 1;
    $self->_save_pins();
    return ($before != scalar @{$self->{pins}}) ? 1 : 0;
}

sub remove_pin {
    my ($self, $index) = @_;

    return 0 unless defined $index;

    $self->_load_pins();

    # Validate index
    return 0 if $index < 0 || $index >= @{$self->{pins}};

    splice @{$self->{pins}}, $index, 1;

    return $self->_save_pins();
}

sub update_pin {
    my ($self, $index, $new_content, %opts) = @_;
    
    return 0 unless defined $index && defined $new_content;
    
    $self->_load_pins();
    
    # Handle negative indices
    $index = @{$self->{pins}} + $index if $index < 0;
    
    # Validate index
    return 0 if $index < 0 || $index >= @{$self->{pins}};
    
    # Update content and timestamp, preserve other fields
    $self->{pins}[$index]{content} = $new_content;
    $self->{pins}[$index]{timestamp} = time();
    
    # Allow role/method updates if specified
    $self->{pins}[$index]{role} = $opts{role} if defined $opts{role};
    $self->{pins}[$index]{method} = $opts{method} if defined $opts{method};
    
    return $self->_save_pins();
}

sub validate_pin_indices {
    my ($self, @indices) = @_;
    
    $self->_load_pins();
    my $pin_count = @{$self->{pins}};
    
    for my $index (@indices) {
        # Handle negative indices
        my $actual_index = $index < 0 ? $pin_count + $index : $index;
        
        if ($actual_index < 0 || $actual_index >= $pin_count) {
            return (0, "Pin index $index is out of range (have $pin_count pins)");
        }
    }
    
    return (1, "All indices valid");
}

sub build_message_array {
    my ($self) = @_;
    $self->_load_pins();

    return [] unless @{$self->{pins}};

    my @messages;

    # Group pins by role and method
    my %grouped = (
        system => { concat => [], msg => [] },
        assistant => { concat => [], msg => [] },
        user => { concat => [], msg => [] },
    );

    for my $pin (@{$self->{pins}}) {
        push @{$grouped{$pin->{role}}{$pin->{method}}}, $pin;
    }

    # Build messages in hard-coded order:
    # 1. System pins (concat only - system pins are always concat)
    if (@{$grouped{system}{concat}}) {
        my $content = join("\n", map { $_->{content} } @{$grouped{system}{concat}});
        push @messages, {
            role => 'system',
            content => $content,
            is_pinned => 1,
        };
    }

    # 2. Assistant pins (concat)
    if (@{$grouped{assistant}{concat}}) {
        my $content = join("\n", map { $_->{content} } @{$grouped{assistant}{concat}});
        push @messages, {
            role => 'assistant',
            content => $content,
            is_pinned => 1,
        };
    }

    # 3. User pins (concat)
    if (@{$grouped{user}{concat}}) {
        my $content = join("\n", map { $_->{content} } @{$grouped{user}{concat}});
        push @messages, {
            role => 'user',
            content => $content,
            is_pinned => 1,
        };
    }

    # 4. Individual assistant pins
    for my $pin (@{$grouped{assistant}{msg}}) {
        push @messages, {
            role => 'assistant',
            content => $pin->{content},
            is_pinned => 1,
        };
    }

    # 5. Individual user pins
    for my $pin (@{$grouped{user}{msg}}) {
        push @messages, {
            role => 'user',
            content => $pin->{content},
            is_pinned => 1,
        };
    }

    return \@messages;
}

sub _process_role_pins {
    my ($self, $messages, $role, $mode, $shims, $template) = @_;

    # Find messages for this role
    my @role_messages = grep { $_->{is_pinned} && $_->{role} eq $role } @$messages;
    return unless @role_messages;

    if ($mode eq 'vars' || $mode eq 'varsfirst') {
        # Get all pins for this role for template variables
        my @role_pins = map { $_->{content} } grep { $_->{role} eq $role } @{$self->{pins}};
        my $pins_str = join("\n", @role_pins);
        my $pin_cnt = scalar @role_pins;

        # Determine which template to use
        my $template_content = $template;

        # Process each message with template variables
        for my $i (0..$#role_messages) {
            my $msg = $role_messages[$i];
            my $pin_idx = $i;

            # For varsfirst mode, only process first message
            if ($mode eq 'varsfirst' && $pin_idx > 0) {
                # Mark for removal instead of just clearing content
                $msg->{_remove} = 1;
                next;
            }

            # Use template if provided, otherwise use message content
            my $content = $template_content // $msg->{content};

            # Apply template processing if content contains template syntax
            if ($template_content || $content =~ /<:|:\>|^\s*:/) {
                my $template_vars = {
                    pins => \@role_pins,
                    pins_str => $pins_str,
                    pin_cnt => $pin_cnt,
                    pin_idx => $pin_idx,
                };
                $content = $self->_apply_template($content, $template_vars);
            }

            $msg->{content} = $content;

            # NO shim for vars/varsfirst modes - shims only for concat mode
        }
    } elsif ($mode eq 'concat') {
        # Traditional concatenation with shims
        for my $msg (@role_messages) {
            if ($role ne 'system' && $shims->{$role}) {
                $msg->{content} .= "\n" . $shims->{$role};
            }
        }
    }

    # Handle system mode special cases
    if ($role eq 'system' && $mode eq 'vars') {
        # Remove system pinned messages (they'll be in template vars)
        @$messages = grep { !($_->{is_pinned} && $_->{role} eq 'system') } @$messages;
    }
}

sub build_message_array_with_shims($self, $shims, $opts=undef) {
    $opts ||= {};
    $shims ||= {
        user => '<pin-shim/>',
        assistant => '<pin-shim/>',
    };

    my $messages = $self->build_message_array();

    # Get pin modes and templates
    my $sys_mode = $opts->{sys_mode} // 'vars';
    my $user_mode = $opts->{user_mode} // 'concat';
    my $ast_mode = $opts->{ast_mode} // 'concat';
    my $user_template = $opts->{user_template};
    my $ast_template = $opts->{ast_template};

    # Process each role's pins
    $self->_process_role_pins($messages, 'system', $sys_mode, $shims, undef);
    $self->_process_role_pins($messages, 'user', $user_mode, $shims, $user_template);
    $self->_process_role_pins($messages, 'assistant', $ast_mode, $shims, $ast_template);

    # Remove messages marked for removal (from varsfirst mode)
    @$messages = grep { !$_->{_remove} } @$messages;

    # Ensure alternating roles by inserting shims where needed
    $self->_ensure_alternating_roles($messages, $shims);

    return $messages;
}

sub _ensure_alternating_roles {
    my ($self, $messages, $shims) = @_;

    return unless @$messages > 1;

    my @result;
    my $last_role;

    for my $msg (@$messages) {
        # Skip system messages for alternating logic
        if ($msg->{role} eq 'system') {
            push @result, $msg;
            next;
        }

        # If we have consecutive non-system messages of the same role, inject alternate
        if (defined $last_role && $last_role eq $msg->{role}) {
            my $alternate_role = ($msg->{role} eq 'user') ? 'assistant' : 'user';
            my $shim_content = $shims->{$alternate_role} // '<shim/>';

            push @result, {
                role => $alternate_role,
                content => $shim_content,
                is_pinned => 1,
                _injected_shim => 1,
            };
        }

        push @result, $msg;
        $last_role = $msg->{role} unless $msg->{role} eq 'system';
    }

    @$messages = @result;
}

sub _apply_template {
    my ($self, $content, $vars) = @_;

    my $tpl = Text::Xslate->new(type => 'text', verbose => 0);

    eval {
        $content = $tpl->render_string($content, $vars);
    };
    warn "Template processing failed: $@" if $@;

    return $content;
}

sub get_pin_count {
    my ($self, $role) = @_;
    $self->_load_pins();
    return scalar @{$self->{pins}} unless defined $role;
    return scalar grep { $_->{role} eq $role } @{$self->{pins}};
}

sub get_system_pins {
    my ($self) = @_;
    $self->_load_pins();
    my @sys = map { $_->{content} } grep { $_->{role} eq 'system' } @{$self->{pins}};
    return \@sys;
}

sub get_pins_summary {
    my ($self, $max_length) = @_;
    $max_length ||= 100;
    $self->_load_pins();
    my @summaries;

    for my $i (0..$#{$self->{pins}}) {
        my $pin = $self->{pins}[$i];

        my $content = $pin->{content};
        # Escape special characters for display
        $content =~ s/\n/\\n/g;
        $content =~ s/\t/\\t/g;
        $content =~ s/\r/\\r/g;

        # Truncate if needed
        if (length($content) > ($max_length - 20)) { # Reserve space for prefix
            $content = substr($content, 0, $max_length - 23) . '...';
        }

        my $summary = sprintf("%d: [%s/%s] %s",
            $i,
            $pin->{role},
            $pin->{method},
            $content
        );

        push @summaries, $summary;
    }

    return \@summaries;
}

sub _save_pins {
    my ($self) = @_;

    return $self->{storage}->save_pins($self->{session_name}, $self->{pins});
}

# Validation helpers
sub _validate_pin_limits {
    my ($self, $limits) = @_;
    return 1 unless $limits;
    $self->_load_pins();

    my %counts = (
        system => 0,
        user => 0,
        assistant => 0,
    );

    for my $pin (@{$self->{pins}}) {
        $counts{$pin->{role}}++;
    }

    for my $role (keys %counts) {
        if ($limits->{$role} && $counts{$role} > $limits->{$role}) {
            return 0;
        }
    }

    return 1;
}

sub enforce_pin_limits {
    my ($self, $limits) = @_;

    return 1 unless $limits;

    $self->_load_pins();

    # Group pins by role
    my %by_role = (
        system => [],
        user => [],
        assistant => [],
    );

    for my $pin (@{$self->{pins}}) {
        push @{$by_role{$pin->{role}}}, $pin;
    }

    # Trim each role to its limit (keep newest)
    my @new_pins;
    for my $role (keys %by_role) {
        my $limit = $limits->{$role} || 50;
        my @role_pins = @{$by_role{$role}};

        if (@role_pins > $limit) {
            # Sort by timestamp and keep newest
            @role_pins = sort { $b->{timestamp} <=> $a->{timestamp} } @role_pins;
            @role_pins = @role_pins[0..($limit-1)];
        }

        push @new_pins, @role_pins;
    }

    # Sort by timestamp to maintain order
    @new_pins = sort { $a->{timestamp} <=> $b->{timestamp} } @new_pins;

    $self->{pins} = \@new_pins;

    return $self->_save_pins();
}

1;

__END__

=head1 NAME

ZChat::Pin - Pin management for ZChat

=head1 SYNOPSIS

    use ZChat::Pin;

    my $pin_mgr = ZChat::Pin->new(
        storage => $storage,
        session_name => "myproject"
    );

    # Add pins
    $pin_mgr->add_pin("You are a helpful assistant.");
    $pin_mgr->add_pin("I'm working on Perl.", role => 'user');
    $pin_mgr->add_pin("Let me help!", role => 'assistant', method => 'msg');

    # List and manage
    my $pins = $pin_mgr->list_pins();
    my $summaries = $pin_mgr->get_pins_summary(60);
    $pin_mgr->remove_pin(0);
    $pin_mgr->clear_pins();

    # Build message array for API
    my $messages = $pin_mgr->build_message_array();

=head1 DESCRIPTION

Manages pinned messages with ordering, concatenation, and storage.
Implements the hard-coded message order: system pins, then assistant
concat, user concat, assistant individual, user individual.

=cut
