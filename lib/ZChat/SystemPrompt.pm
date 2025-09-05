##### File: lib/ZChat/SystemPrompt.pm
package ZChat::SystemPrompt;
use v5.34;
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
    my ($self, $name, %opts) = @_;
    die "set(): exactly one positional arg required" unless defined $name && @_ == 2 || (@_ == 3 && ref($opts[0]) eq 'HASH');
    my $scope = $self->_scope(\%opts);
    $self->{config}->set_system_candidate($scope, file_or_persona => $name);
    return $self;
}

sub set_file {
    my ($self, $path, %opts) = @_;
    my $scope = $self->_scope(\%opts);
    $self->{config}->set_system_candidate($scope, system_file => $path);
    return $self;
}

sub set_persona {
    my ($self, $name, %opts) = @_;
    my $scope = $self->_scope(\%opts);
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
    my ($self, $name, %opts) = @_;
    my $scope = $self->_scope(\%opts);
    $self->{config}->set_system_candidate($scope, system => $name);
    return $self;
}

sub resolve {
    my ($self) = @_;
    return $self->{config}->resolve_system_prompt();
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
