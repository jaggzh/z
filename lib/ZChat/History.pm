##### File: lib/ZChat/History.pm
package ZChat::History;
use v5.26.3;
use feature 'say';
use experimental 'signatures';
use strict;
use warnings;
use Scalar::Util qw(looks_like_number);
use utf8;

use ZChat::Utils ':all';

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
    die "append: invalid role '$role'" unless $role =~ /^(user|assistant|system|tool)$/;
    
    my $next_id = @{$self->{_messages}} ? ($self->{_messages}[-1]{id} || 0) + 1 : 1;
    
    push @{$self->{_messages}}, {
        role     => $role,
        content  => $content,
        meta     => $meta || {},
        ts       => time,
        id       => $next_id,
    };
    return $self;
}

sub wipe_old {
    my ($self, $age_spec) = @_;
    
    die "wipe_old: age specification required (e.g., '10s', ... '1.5h', '2d', '1w')\n" unless defined $age_spec;
    
    $self->load();
    
    my $cutoff_time = $self->_parse_age_spec($age_spec);
    my $original_count = @{$self->{_messages}};
    
    # Keep messages newer than cutoff
    $self->{_messages} = [ grep { ($_->{ts} || 0) > $cutoff_time } @{$self->{_messages}} ];
    
    my $removed_count = $original_count - @{$self->{_messages}};
    
    # Re-sequence IDs
    for my $i (0..$#{$self->{_messages}}) {
        $self->{_messages}[$i]{id} = $i + 1;
    }
    
    return $removed_count;
}

sub _parse_age_spec {
    my ($self, $spec) = @_;
    
    # Parse formats like: 1.5h, 2d, 3w, 1M, 2y
    unless ($spec =~ /^(\d+(?:\.\d+)?)(s|m|h|d|w|M|y)$/) {
        die "Invalid age format '$spec'. Use: 1.5h, 2d, 1w, 1M, 2y\n";
    }
    
    my ($amount, $unit) = ($1, $2);
    
    my %multipliers = (
        s => 1,           # seconds
        m => 60,          # minutes  
        h => 3600,        # hours
        d => 86400,       # days
        w => 604800,      # weeks
        M => 2629746,     # months (30.44 days average)
        y => 31556952,    # years (365.24 days)
    );
    
    my $seconds_ago = $amount * $multipliers{$unit};
    return time - $seconds_ago;
}

sub get_stats {
    my ($self) = @_;
    
    $self->load();
    
    my %stats = (
        total_messages => scalar @{$self->{_messages}},
        by_role => {},
        date_range => {},
        tokens => { total_input => 0, total_output => 0 },
    );
    
    # Count by role and collect token stats
    for my $msg (@{$self->{_messages}}) {
        $stats{by_role}{$msg->{role}}++;
        
        if ($msg->{meta}) {
            $stats{tokens}{total_input} += $msg->{meta}{tokens_input} || 0;
            $stats{tokens}{total_output} += $msg->{meta}{tokens_output} || 0;
        }
    }
    
    # Date range
    if (@{$self->{_messages}}) {
        my @timestamps = map { $_->{ts} || 0 } @{$self->{_messages}};
        @timestamps = sort { $a <=> $b } @timestamps;
        $stats{date_range}{oldest} = $timestamps[0];
        $stats{date_range}{newest} = $timestamps[-1];
    }
    
    return \%stats;
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

sub get_last($self, $optshro=undef) {
    $optshro ||= {};

    if (exists $optshro->{role}) {
        my $idx = $self->_find_last_index_for_role($optshro->{role});
        return undef unless defined $idx;
        return $self->{_messages}[$idx];
    }
    my $u = $self->get_last(role => 'user');
    my $a = $self->get_last(role => 'assistant');
    return { user => $u, assistant => $a };
}

sub owrite_last($self, $payload, $optshro=undef) {
    $optshro ||= {};

    if (ref($payload) eq 'HASH') {
    	swarn "owrite_last() called with a hash payload AND role restrictions. We do not handle filtering, if that's what you were intending. Only the payload is being honored."
			if defined $optshro && exists $optshro->{role};
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
    if (!exists $optshro->{role}) {
    	die "owrite_last() called with no role. We do not handle this currently.";
	}
    my $role = $optshro->{role};
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
