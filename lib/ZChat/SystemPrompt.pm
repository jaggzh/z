##### File: lib/ZChat/SystemPrompt.pm
package ZChat::SystemPrompt;
use v5.26.3;
use feature 'say';
use experimental 'signatures';
use strict;
use warnings;

use utf8;

sub new {
    my ($class, %opts) = @_;
    my $self = {
        config       => ($opts{config} // die "config required"),
        scope        => 'CODE',   # default provenance for direct setters
    };
    bless $self, $class;
    return $self;
}

sub _scope {
    my ($self, $opts) = @_;
    return ($opts && $opts->{scope}) ? $opts->{scope} : 'CODE';
}

sub set {
    my ($self, $name, $opts) = @_;
    die "set(): exactly one positional arg required" unless defined $name && @_ == 2 || (@_ == 3 && ref($opts) eq 'HASH');
    my $scope = $self->_scope($opts);
    $self->{config}->set_system_candidate($scope, file_or_persona => $name);
    return $self;
}

sub set_file {
    my ($self, $path, $opts) = @_;
    my $scope = $self->_scope($opts);
    $self->{config}->set_system_candidate($scope, system_file => $path);
    return $self;
}

sub set_persona {
    my ($self, $name, $opts) = @_;
    my $scope = $self->_scope($opts);
    $self->{config}->set_system_candidate($scope, system_persona => $name);
    return $self;
}

sub set_str {
    my ($self, $text, %opts) = @_;
    my $scope = $self->_scope(\%opts);
    $self->{config}->set_system_candidate($scope, system_str => $text);
    return $self;
}

sub set_auto {
    my ($self, $name, $opts) = @_;
    my $scope = $self->_scope($opts);
    $self->{config}->set_system_candidate($scope, system => $name);
    return $self;
}

sub resolve {
    my ($self) = @_;
    
    my $cfg = $self->{config}->get_effective_config();
    
    # Check CLI scope first (highest precedence)
    if (defined $cfg->{_cli_system_file}) {
        sel(2, "Resolving CLI system_file: $cfg->{_cli_system_file}");
        return { source => 'file', value => $cfg->{_cli_system_file}, provenance => 'CLI' };
    }
    if (defined $cfg->{_cli_system_str}) {
        sel(2, "Resolving CLI system_str");
        return { source => 'str', value => $cfg->{_cli_system_str}, provenance => 'CLI' };
    }
    if (defined $cfg->{_cli_system_persona}) {
        sel(2, "Resolving CLI system_persona: $cfg->{_cli_system_persona}");
        return { source => 'persona', value => $cfg->{_cli_system_persona}, provenance => 'CLI' };
    }
    if (defined $cfg->{_cli_system}) {
        sel(2, "Resolving CLI system (auto): $cfg->{_cli_system}");
        return $self->_resolve_auto($cfg->{_cli_system}, 'CLI');
    }
    
    # Check session scope
    if (defined $cfg->{system_file_session}) {
        sel(2, "Resolving session system_file: $cfg->{system_file_session}");
        return { source => 'file', value => $cfg->{system_file_session}, provenance => 'SESSION' };
    }
    if (defined $cfg->{system_prompt_session}) {
        sel(2, "Resolving session system_prompt");
        return { source => 'str', value => $cfg->{system_prompt_session}, provenance => 'SESSION' };
    }
    if (defined $cfg->{system_persona_session}) {
        sel(2, "Resolving session system_persona: $cfg->{system_persona_session}");
        return { source => 'persona', value => $cfg->{system_persona_session}, provenance => 'SESSION' };
    }
    if (defined $cfg->{system_session}) {
        sel(2, "Resolving session system (auto): $cfg->{system_session}");
        return $self->_resolve_auto($cfg->{system_session}, 'SESSION');
    }
    
    # Check user scope
    if (defined $cfg->{system_file_user}) {
        sel(2, "Resolving user system_file: $cfg->{system_file_user}");
        return { source => 'file', value => $cfg->{system_file_user}, provenance => 'USER' };
    }
    if (defined $cfg->{system_prompt_user}) {
        sel(2, "Resolving user system_prompt");
        return { source => 'str', value => $cfg->{system_prompt_user}, provenance => 'USER' };
    }
    if (defined $cfg->{system_persona_user}) {
        sel(2, "Resolving user system_persona: $cfg->{system_persona_user}");
        return { source => 'persona', value => $cfg->{system_persona_user}, provenance => 'USER' };
    }
    if (defined $cfg->{system_user}) {
        sel(2, "Resolving user system (auto): $cfg->{system_user}");
        return $self->_resolve_auto($cfg->{system_user}, 'USER');
    }
    
    return undef;
}

sub _resolve_auto {
    my ($self, $name, $provenance) = @_;
    
    # Try as file first
    if (-f $name) {
        sel(2, "Auto-resolved '$name' as file");
        return { source => 'file', value => $name, provenance => $provenance };
    }
    
    # Try as persona
    sel(2, "Auto-resolving '$name' as persona");
    return { source => 'persona', value => $name, provenance => $provenance };
}

sub get_source {
    my ($self) = @_;
    my $r = $self->resolve() // return undef;
    return $r->{source};
}

sub get_provenance {
    my ($self) = @_;
    my $r = $self->resolve() // return undef;
    return $r->{provenance};
}

sub as_hash {
    my ($self) = @_;
    my $r = $self->resolve() // return undef;
    return {
        source     => $r->{source},
        value      => $r->{value},
        provenance => $r->{provenance},
    };
}

1;
