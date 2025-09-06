package ZChat::Config;
use v5.26.3;
use feature 'say';
use experimental 'signatures';
use strict;
use warnings;

use utf8;
use File::Spec;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use ZChat::Utils ':all';

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        storage => ($opts{storage} // die "storage required"),
        session_name => ($opts{session_name} // ''),
        effective_config => {},
    };
    
    bless $self, $class;
    return $self;
}

sub load_effective_config {
    my ($self, %cli_opts) = @_;
    
    my $config = {};
    
    # 1. System defaults
    my $system_defaults = $self->_get_system_defaults();
    %$config = (%$config, %$system_defaults);
    
    # 2. User global config
    my $user_config = $self->_load_user_config();
    if ($user_config) {
        %$config = (%$config, %$user_config);
        sel(2, "Loaded user config overrides");
    }
    
    # 3. Session config  
    my $effective_session = $self->_resolve_session_name(\%cli_opts, $config);
    $config->{session} = $effective_session;
    sel(2, "Using session '$effective_session'");
    
    if ($effective_session) {
        $self->{session_name} = $effective_session;
        my $session_config = $self->_load_session_config();
        if ($session_config) {
            %$config = (%$config, %$session_config);
            sel(2, "Loaded session config overrides");
        }
    }

    # Record source-specific copies for precedence resolution
    $config->{system_file_user}       = $user_config->{system_file}       if $user_config && defined $user_config->{system_file};
    $config->{system_prompt_user}     = $user_config->{system_prompt}     if $user_config && defined $user_config->{system_prompt};
    $config->{system_persona_user}    = $user_config->{system_persona}    if $user_config && defined $user_config->{system_persona};
    if ($effective_session) {
        my $session_config = $self->_load_session_config() || {};
        $config->{system_file_session}    = $session_config->{system_file}    if defined $session_config->{system_file};
        $config->{system_prompt_session}  = $session_config->{system_prompt}  if defined $session_config->{system_prompt};
        $config->{system_persona_session} = $session_config->{system_persona} if defined $session_config->{system_persona};
    }

    # 4. CLI overrides (runtime only) — stash source-marked copies
    if (defined $cli_opts{system_str})  { $config->{system_prompt} = $cli_opts{system_str};  $config->{_cli_system_str}  = $cli_opts{system_str};  sel(2, "Setting system_str from CLI options"); }
    if (defined $cli_opts{system_file}) { $config->{system_file}   = $cli_opts{system_file}; $config->{_cli_system_file} = $cli_opts{system_file}; sel(2, "Setting system_file from CLI options"); }
    if (defined $cli_opts{system_persona}) { $config->{system_persona} = $cli_opts{system_persona}; $config->{_cli_system_persona} = $cli_opts{system_persona}; sel(2, "Setting system_persona from CLI options"); }

    # Preserve pin_shims / pin_sys_mode CLI handling
    if (defined $cli_opts{pin_shims}) {
        $config->{pin_shims} = $cli_opts{pin_shims};
        sel(2, "Setting pin_shims from CLI options");
    }
    if (defined $cli_opts{pin_sys_mode}) {
        $config->{pin_sys_mode} = $cli_opts{pin_sys_mode};
        sel(2, "Setting pin_sys_mode '$cli_opts{pin_sys_mode}' from CLI options");
    }
    $config->{_cli_pin_shims}    = $cli_opts{pin_shims}    if defined $cli_opts{pin_shims};
    $config->{_cli_pin_sys_mode} = $cli_opts{pin_sys_mode} if defined $cli_opts{pin_sys_mode};

    $self->{effective_config} = $config;
    return $config;
}

sub _resolve_session_name {
    my ($self, $cli_opts, $config) = @_;
    
    # CLI session takes precedence
    return $cli_opts->{session} if defined $cli_opts->{session} && $cli_opts->{session} ne '';
    
    # Then original session_name from constructor
    return $self->{session_name} if defined $self->{session_name} && $self->{session_name} ne '';
    
    # Then user config session
    return $config->{session} if defined $config->{session} && $config->{session} ne '';
    
    # Finally default
    return 'default';
}

sub get_session_name {
    my ($self) = @_;
    return $self->{effective_config}->{session} // 'default';
}

sub _get_system_defaults {
    return {
        session => '',
        pin_defaults => {
            role => 'system',
            method => 'concat',
        },
        pin_limits => {
            system => 50,
            user => 50,
            assistant => 50,
        },
        pin_shims => {
            user => '<pin-shim/>',
            assistant => '<pin-shim/>',
        },
        pin_sys_mode => 'vars',   # how system pins are applied: vars|concat|both
    };
}

sub _load_user_config {
    my ($self) = @_;
    
    my $config_dir = $self->_get_config_dir();
    my $user_config_file = File::Spec->catfile($config_dir, 'user.yaml');
    sel 1, "Loading User config file: $user_config_file";
    my $yaml = $self->{storage}->load_yaml($user_config_file);
    sel 3, "  YAML result: ", ($yaml // 'unable to load');
    return $yaml;
}

sub _load_session_config {
    my ($self) = @_;
    
    return undef unless $self->{session_name};
    
    my $session_dir = $self->_get_session_dir();
    my $session_config_file = File::Spec->catfile($session_dir, 'session.yaml');
    sel 1, "Loading Session config file: $session_config_file";
    my $yaml = $self->{storage}->load_yaml($session_config_file);
    sel 3, "  YAML result: ", ($yaml // 'unable to load');
    
    return $yaml;
}

sub store_user_config {
    my ($self, %opts) = @_;
    
    my $config_dir = $self->_get_config_dir();
    make_path($config_dir) unless -d $config_dir;
    
    my $user_config_file = File::Spec->catfile($config_dir, 'user.yaml');
    
    # Load existing config
    my $existing = $self->_load_user_config() || {};
    
    for my $key (qw(session system_prompt system_file system_persona pin_sys_mode)) {
        if (defined $opts{$key}) {
            $existing->{$key} = $opts{$key};
        }
    }
    if (defined $opts{pin_shims}) {
        $existing->{pin_shims} = $opts{pin_shims};
    }
    
    sel 1, "Saving user config as YAML at: $user_config_file";
    return $self->{storage}->save_yaml($user_config_file, $existing);
}

sub store_session_config {
    my ($self, %opts) = @_;
    
    my $session_dir = $self->{storage}->get_session_dir($self->{session_name});
    make_path($session_dir) unless -d $session_dir;
    
    my $session_config_file = File::Spec->catfile($session_dir, 'session.yaml');
    
    # Load existing config
    my $existing = $self->_load_session_config() || {};
    
    # Add created timestamp if new
    $existing->{created} = time() unless exists $existing->{created};
    
    # Update with new values
    for my $key (qw(system_prompt system_file system_persona pin_sys_mode)) {
        if (defined $opts{$key}) {
            $existing->{$key} = $opts{$key};
        }
    }
    if (defined $opts{pin_shims}) {
        $existing->{pin_shims} = $opts{pin_shims};
    }
    
    sel 1, "Saving session config as YAML at: $session_config_file";
    return $self->{storage}->save_yaml($session_config_file, $existing);
}

sub _get_config_dir {
    my ($self) = @_;
    
    my $home = $ENV{HOME} || die "HOME environment variable not set";
    return File::Spec->catdir($home, '.config', 'zchat');
}

sub _get_session_dir {
    my ($self) = @_;
    
    return undef unless $self->{session_name};
    
    my $config_dir = $self->_get_config_dir();
    my @session_parts = split('/', $self->{session_name});
    
    return File::Spec->catdir($config_dir, 'sessions', @session_parts);
}

sub get_effective_config {
    my ($self) = @_;
    return $self->{effective_config};
}

# Convenience methods for common config access
sub get_preset {
    my ($self) = @_;
    return $self->{effective_config}->{preset};
}

sub get_pin_defaults {
    my ($self) = @_;
    return $self->{effective_config}->{pin_defaults} || {};
}

sub get_pin_limits {
    my ($self) = @_;
    return $self->{effective_config}->{pin_limits} || {};
}

sub get_pin_shims {
    my ($self) = @_;
    return $self->{effective_config}->{pin_shims} || {};
}

sub get_pin_sys_mode {
    my ($self) = @_;
    return $self->{effective_config}->{pin_sys_mode} || 'vars';
}

sub set_system_candidate {
    my ($self, $scope, %kv) = @_;
    die "set_system_candidate: scope required" unless defined $scope;
    my ($k, $v) = each %kv;
    die "set_system_candidate: exactly one key" unless defined $k && @_ == 4;
    $self->{_sp_candidates} //= {};
    $self->{_sp_candidates}{$scope} //= {};
    $self->{_sp_candidates}{$scope}{$k} = $v;
    return $self;
}

sub resolve_system_prompt {
    my ($self) = @_;

    my $check_file = sub ($p) {
        return 0 unless defined $p && length $p;
        return -f $p ? 1 : 0;
    };
    my $norm_file = sub ($p) {
        return abs_path($p) // $p;
    };
    my $check_persona = sub ($name) {
        return 0 unless defined $name && length $name;
        system("persona --help >/dev/null 2>&1");
        return ($? == 0) ? 1 : 0;
    };

    my @scopes = qw(CLI SESSION USER CODE);
    my %cand   = %{ $self->{_sp_candidates} // {} };

    my $pick_in_scope = sub ($scope) {
        my $h = $cand{$scope} // {};
        if (defined $h->{system_file}) {
            my $ok = $check_file->($h->{system_file});
            die "system_file not found: $h->{system_file}" unless $ok;
            return { source=>'file', value=>$norm_file->($h->{system_file}), provenance=>$scope };
        }
        if (defined $h->{system_str}) {
            return { source=>'str', value=>$h->{system_str}, provenance=>$scope };
        }
        if (defined $h->{system_persona}) {
            die "persona tool unavailable" unless $check_persona->($h->{system_persona});
            return { source=>'persona', value=>$h->{system_persona}, provenance=>$scope };
        }
        if (defined $h->{system}) {
            my $name = $h->{system};
            if ($check_file->($name)) {
                return { source=>'file', value=>$norm_file->($name), provenance=>$scope };
            }
            die "persona tool unavailable" unless $check_persona->($name);
            return { source=>'persona', value=>$name, provenance=>$scope };
        }
        if (defined $h->{file_or_persona}) {
            my $name = $h->{file_or_persona};
            if ($check_file->($name)) {
                return { source=>'file', value=>$norm_file->($name), provenance=>$scope };
            }
            die "persona tool unavailable" unless $check_persona->($name);
            return { source=>'persona', value=>$name, provenance=>$scope };
        }
        return undef;
    };

    for my $S (@scopes) {
        my $r = $pick_in_scope->($S);
        return $r if $r;
    }
    return undef;
}

1;

__END__

=head1 NAME

ZChat::Config - Configuration management with precedence chain

=head1 SYNOPSIS

    use ZChat::Config;
    
    my $config = ZChat::Config->new(
        storage => $storage,
        session_name => "myproject/analysis"
    );
    
    # Load effective configuration (system → user → session → CLI)
    my $effective = $config->load_effective_config(
        preset => "coding",  # CLI override
    );
    
    # Store configurations
    $config->store_user_config(preset => "default");
    $config->store_session_config(preset => "coding");

=head1 DESCRIPTION

Handles configuration loading and storage with proper precedence:
system defaults → user config → session config → CLI overrides

=cut

# vim: et
