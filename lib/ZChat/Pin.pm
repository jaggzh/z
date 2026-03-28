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

    my $role   = $opts->{role}   || 'system';
    my $id     = $opts->{id};
    my $mate   = $opts->{mate};   # per-pin mate content (msg pins only)

    unless ($role =~ /^(system|user|assistant)$/) {
        warn "Invalid pin role '$role', using 'system'";
        $role = 'system';
    }

    # System pins are always concat. User/ast default to msg.
    my $method;
    if ($role eq 'system') {
        $method = 'concat';
    } else {
        $method = $opts->{method} || 'msg';
        unless ($method =~ /^(concat|msg|concatvars)$/) {
            warn "Invalid pin method '$method', using 'msg'";
            $method = 'msg';
        }
    }

    my $pin = {
        content   => $content,
        role      => $role,
        method    => $method,
        timestamp => time(),
        (defined $id   ? (id   => $id)   : ()),
        (defined $mate ? (mate => $mate) : ()),
    };

    push @{$self->{pins}}, $pin;
    return $self->_save_pins();
}

# Resolve a pin identifier (name string or numeric index) to a numeric index.
# Returns undef if not found.
sub _resolve_pin_index {
    my ($self, $ident) = @_;
    return undef unless defined $ident;

    # Numeric index
    if ($ident =~ /^-?\d+$/) {
        my $idx = $ident < 0 ? @{$self->{pins}} + $ident : $ident;
        return undef if $idx < 0 || $idx >= @{$self->{pins}};
        return $idx;
    }

    # Named id — return first match
    for my $i (0 .. $#{$self->{pins}}) {
        return $i if (($self->{pins}[$i]{id} // '') eq $ident);
    }
    return undef;
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
    my ($self, $ident) = @_;
    return 0 unless defined $ident;
    $self->_load_pins();
    my $index = $self->_resolve_pin_index($ident);
    return 0 unless defined $index;
    splice @{$self->{pins}}, $index, 1;
    return $self->_save_pins();
}

sub update_pin {
    my ($self, $ident, $new_content, %opts) = @_;
    return 0 unless defined $ident && defined $new_content;
    $self->_load_pins();
    my $index = $self->_resolve_pin_index($ident);
    return 0 unless defined $index;
    $self->{pins}[$index]{content}   = $new_content;
    $self->{pins}[$index]{timestamp} = time();
    $self->{pins}[$index]{role}   = $opts{role}   if defined $opts{role};
    $self->{pins}[$index]{method} = $opts{method} if defined $opts{method};
    $self->{pins}[$index]{id}     = $opts{id}     if defined $opts{id};
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

sub build_message_array_with_mates {
    my ($self, $config) = @_;
    $config ||= {};
    $self->_load_pins();

    my @messages;

    # System pins are assembled into the system string by _get_system_content.
    # Only process user and assistant pins here.
    my @role_order = @{ $config->{role_order} // [qw(user assistant)] };

    for my $role (@role_order) {
        next if $role eq 'system';
        my $alt = $role eq 'user' ? 'assistant' : 'user';

        # Group this role's pins by method
        my %buckets;
        for my $pin (grep { $_->{role} eq $role } @{$self->{pins}}) {
            my $m = $pin->{method} // 'msg';
            push @{ $buckets{$m} }, $pin;
        }

        my @method_order = split /,/, ($config->{"${role}_order"} // 'concat,msg,concatvars');

        for my $method (@method_order) {
            my $pins = $buckets{$method};
            next unless $pins && @$pins;

            if ($method eq 'concat') {
                # All concat pins joined into one message + one mate
                my $sep     = $config->{"${role}_concat_join"} // "\n";
                my $content = join($sep, map { $_->{content} } @$pins);
                my $mate    = $config->{"${role}_concat_mate"} // '';
                push @messages,
                    { role => $role, content => $content, is_pinned => 1, _method => 'concat' },
                    { role => $alt,  content => $mate,    is_pinned => 1, _method => 'concat', _injected_mate => 1 };

            } elsif ($method eq 'msg') {
                # One message + mate per pin; mate stored per-pin or from config
                for my $pin (@$pins) {
                    my $mate = (defined $pin->{mate} ? $pin->{mate}
                                                     : ($config->{"${role}_msg_mate"} // ''));
                    push @messages,
                        { role => $role, content => $pin->{content}, is_pinned => 1,
                          _method => 'msg', _pin_id => ($pin->{id} // '') },
                        { role => $alt,  content => $mate,           is_pinned => 1,
                          _method => 'msg', _injected_mate => 1 };
                }

            } elsif ($method eq 'concatvars') {
                # Each pin rendered through template; results joined into one message + one mate
                my $tpl = $config->{"${role}_concatvars_tpl"};
                my @pin_ids  = map { $_->{id} // '' } @$pins;
                my @contents = map { $_->{content} } @$pins;
                my $pins_str = join("\n", @contents);
                my $pin_cnt  = scalar @$pins;

                my @rendered;
                for my $i (0 .. $#$pins) {
                    my $vars = {
                        pins     => \@contents,
                        pins_str => $pins_str,
                        pin_cnt  => $pin_cnt,
                        pin_idx  => $i,
                        pin_last => ($i == $#$pins) ? 1 : 0,
                        pin_id   => $pins->[$i]{id} // '',
                        pin_ids  => \@pin_ids,
                        pin_str  => $pins->[$i]{content},
                    };
                    if ($tpl) {
                        push @rendered, $self->_apply_template($tpl, $vars);
                    } else {
                        # No template: fall back to raw content (same as concat)
                        push @rendered, $pins->[$i]{content};
                    }
                }

                my $sep     = $config->{"${role}_concatvars_join"} // "\n";
                my $content = join($sep, @rendered);
                my $mate    = $config->{"${role}_concatvars_mate"} // '';
                push @messages,
                    { role => $role, content => $content, is_pinned => 1, _method => 'concatvars' },
                    { role => $alt,  content => $mate,    is_pinned => 1, _method => 'concatvars', _injected_mate => 1 };
            }
        }
    }

    # Safety net: catch any remaining alternation violations that can arise when
    # both user and assistant pin groups are used together.
    my %bridge = (
        user      => $config->{user_msg_mate} // '',
        assistant => $config->{ast_msg_mate}  // '',
    );
    _fix_alternation(\@messages, \%bridge);

    return \@messages;
}

# Scan for consecutive same-role messages and insert a bridge mate between them.
sub _fix_alternation {
    my ($messages, $bridge) = @_;
    my @result;
    my $last_role;
    for my $msg (@$messages) {
        if ($msg->{role} eq 'system' || $msg->{role} eq 'tool') {
            push @result, $msg;
            next;
        }
        if (defined $last_role && $last_role eq $msg->{role}) {
            my $alt = $msg->{role} eq 'user' ? 'assistant' : 'user';
            push @result, {
                role           => $alt,
                content        => $bridge->{$alt} // '',
                is_pinned      => 1,
                _injected_mate => 1,
                _method        => 'bridge',
            };
        }
        push @result, $msg;
        $last_role = $msg->{role};
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

# Returns content of system pins filtered by method (e.g. 'concat').
sub get_system_pins_by_method {
    my ($self, $method) = @_;
    $self->_load_pins();
    my @sys = map  { $_->{content} }
              grep { $_->{role} eq 'system' && ($_->{method}//'') eq $method }
              @{$self->{pins}};
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

        my $id_str  = defined $pin->{id} ? " [$pin->{id}]" : "";
        my $summary = sprintf("%d: [%s/%s]%s %s",
            $i,
            $pin->{role},
            $pin->{method},
            $id_str,
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

Manages pinned messages with three methods:

  concat     - all pins of this role joined into one message (one mate)
  msg        - one message per pin; mate stored per-pin or from config
  concatvars - each pin rendered through a template, results joined into one message

System pins are always concat and are assembled into the system prompt string
by ZChat::_get_system_content(), not into the message array.

Assembly order within a role is controlled by the C<user_order>/C<ast_order>
config keys (default: concat, msg, concatvars). Role order (user vs assistant
groups) is controlled by C<role_order> (default: user first).

=cut
