package ZChat::Config;
use v5.34;
use warnings;
use utf8;
use File::Spec;
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
    sel(2, "Setting preset '$config->{preset}' from system defaults");
    
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
    $config->{system_file_user}    = $user_config->{system_file}       if $user_config && defined $user_config->{system_file};
    $config->{system_prompt_user}  = $user_config->{system_prompt}     if $user_config && defined $user_config->{system_prompt};
    if ($effective_session) {
        my $session_config = $self->_load_session_config() || {};
        $config->{system_file_session}   = $session_config->{system_file}   if defined $session_config->{system_file};
        $config->{system_prompt_session} = $session_config->{system_prompt} if defined $session_config->{system_prompt};
    }
    
    # 4. CLI overrides (runtime only) — keep originals *and* stash source-marked copies
    for my $key (qw(system_prompt system_file)) {
        if (defined $cli_opts{$key}) {
            $config->{$key} = $cli_opts{$key};
            sel(2, "Setting $key '$cli_opts{$key}' from CLI options");
        }
    }
    $config->{_cli_system_prompt} = $cli_opts{system_prompt} if defined $cli_opts{system_prompt};
    $config->{_cli_system_file}   = $cli_opts{system_file}   if defined $cli_opts{system_file};
    $config->{preset} = $cli_opts{preset} if defined $cli_opts{preset};

    # Preserve pin_shims / pin_sys_mode CLI handling (was lost)
    if (defined $cli_opts{pin_shims}) {
        $config->{pin_shims} = $cli_opts{pin_shims};
        sel(2, "Setting pin_shims from CLI options");
    }
    if (defined $cli_opts{pin_sys_mode}) {
        $config->{pin_sys_mode} = $cli_opts{pin_sys_mode};
        sel(2, "Setting pin_sys_mode '$cli_opts{pin_sys_mode}' from CLI options");
    }
    $config->{_cli_pin_shims}   = $cli_opts{pin_shims}   if defined $cli_opts{pin_shims};
    $config->{_cli_pin_sys_mode}= $cli_opts{pin_sys_mode}if defined $cli_opts{pin_sys_mode};

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
        preset => 'default',
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
    sel 2, "  YAML result: ", ($yaml // 'unable to load');
    return $yaml;
}

sub _load_session_config {
    my ($self) = @_;
    
    return undef unless $self->{session_name};
    
    my $session_dir = $self->_get_session_dir();
    my $session_config_file = File::Spec->catfile($session_dir, 'session.yaml');
    sel 1, "Loading Session config file: $session_config_file";
    my $yaml = $self->{storage}->load_yaml($session_config_file);
    sel 2, "  YAML result: ", ($yaml // 'unable to load');
    
    return $yaml;
}

sub store_user_config {
    my ($self, %opts) = @_;
    
    my $config_dir = $self->_get_config_dir();
    make_path($config_dir) unless -d $config_dir;
    
    my $user_config_file = File::Spec->catfile($config_dir, 'user.yaml');
    
    # Load existing config
    my $existing = $self->_load_user_config() || {};
    
    # Update with new values
    for my $key (qw(preset session system_prompt system_file)) {
        if (defined $opts{$key}) {
            $existing->{$key} = $opts{$key};
        }
    }
    if (defined $opts{pin_shims}) {
        $existing->{pin_shims} = $opts{pin_shims};
    }
    if (defined $opts{pin_sys_mode}) {
        $existing->{pin_sys_mode} = $opts{pin_sys_mode};
    }

    # Allow storing system prompt/file at user level too
    for my $key (qw(system_prompt system_file)) {
        if (defined $opts{$key}) {
            $existing->{$key} = $opts{$key};
        }
    }

    sel 1, "Saving user config as YAML at: $user_config_file";
    return $self->{storage}->save_yaml($user_config_file, $existing);
}

sub store_session_config {
    my ($self, %opts) = @_;
    
    return undef unless $self->{session_name};
    
    my $session_dir = $self->_get_session_dir();
    make_path($session_dir) unless -d $session_dir;
    
    my $session_config_file = File::Spec->catfile($session_dir, 'session.yaml');
    
    # Load existing config
    my $existing = $self->_load_session_config() || {};
    
    # Add created timestamp if new
    $existing->{created} = time() unless exists $existing->{created};
    
    # Update with new values
    for my $key (qw(preset system_prompt system_file)) {
        if (defined $opts{$key}) {
            $existing->{$key} = $opts{$key};
        }
    }
    if (defined $opts{pin_shims}) {
        $existing->{pin_shims} = $opts{pin_shims};
    }
    if (defined $opts{pin_sys_mode}) {
        $existing->{pin_sys_mode} = $opts{pin_sys_mode};
    }
    
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
