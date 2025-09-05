##### File: lib/ZChat/History.pm
package ZChat::History;
use v5.26.3;
use feature 'say';
use experimental 'signatures';
use strict;
use warnings;

use utf8;

use Scalar::Util qw(looks_like_number);

sub new {
    my ($class, %opts) = @_;
    my $self = {
        storage      => ($opts{storage}      // die "storage required"),
        session_name => ($opts{session}      // die "session required"),
        mode         => ($opts{mode}         // 'rw'),   # rw | ro | none
        _messages    => [],                              
        _loaded      => 0,
    };
    bless $self, $class;
    return $self;
}

sub set_mode {
    my ($self, $mode) = @_;
    die "set_mode: expected 'rw','ro','none'" unless defined $mode && $mode =~ /^(rw|ro|none)$/;
    $self->{mode} = $mode;
    return $self;
}

sub get_mode { $_[0]{mode} }

sub load {
    my ($self) = @_;
    return $self if $self->{mode} eq 'none';
    return $self if $self->{_loaded};
    my $msgs = $self->{storage}->load_history($self->{session_name}) // [];
    $self->{_messages} = $msgs;
    $self->{_loaded}   = 1;
    return $self;
}

sub save {
    my ($self) = @_;
    return $self unless $self->{mode} eq 'rw';
    $self->{storage}->save_history($self->{session_name}, $self->{_messages});
    return $self;
}

sub wipe {
    my ($self) = @_;
    $self->{storage}->wipe_history($self->{session_name});
    $self->{_messages} = [];
    $self->{_loaded}   = 1;
    return $self;
}

sub wipe_memory {
    my ($self) = @_;
    $self->{_messages} = [];
    $self->{_loaded}   = 1;
    return $self;
}

sub append {
    my ($self, $role, $content, $meta) = @_;
    die "append: role required" unless defined $role && length $role;
    die "append: content required" unless defined $content;
    push @{$self->{_messages}}, {
        role     => $role,
        content  => $content,
        meta     => $meta || {},
        ts       => time,
    };
    return $self;
}

sub messages { $_[0]{_messages} }

sub len { scalar @{ $_[0]{_messages} } }

sub empty { @{ $_[0]{_messages} } ? 0 : 1 }

sub _find_last_index_for_role {
    my ($self, $role) = @_;
    for (my $i = $#{ $self->{_messages} }; $i >= 0; $i--) {
        return $i if ($self->{_messages}[$i]{role} // '') eq $role;
    }
    return undef;
}

sub get_last {
    my ($self, %opts) = @_;
    if (defined $opts{role}) {
        my $idx = $self->_find_last_index_for_role($opts{role});
        return undef unless defined $idx;
        return $self->{_messages}[$idx];
    }
    my $u = $self->get_last(role => 'user');
    my $a = $self->get_last(role => 'assistant');
    return { user => $u, assistant => $a };
}

sub owrite_last {
    my ($self, $payload, $opts) = @_;
    if (ref($payload) eq 'HASH') {
        for my $role (qw(user assistant system)) {
            next unless exists $payload->{$role};
            my $idx = $self->_find_last_index_for_role($role);
            if (defined $idx) {
                $self->{_messages}[$idx]{content} = $payload->{$role};
                $self->{_messages}[$idx]{ts} = time;
            } else {
                $self->append($role, $payload->{$role});
            }
        }
        return $self;
    }
    my $role = ($opts && $opts->{role}) // 'assistant';
    my $idx  = $self->_find_last_index_for_role($role);
    if (defined $idx) {
        $self->{_messages}[$idx]{content} = $payload;
        $self->{_messages}[$idx]{ts} = time;
    } else {
        $self->append($role, $payload);
    }
    return $self;
}

1;
