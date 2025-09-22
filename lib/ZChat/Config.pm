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
use ZChat::ParentID qw(get_parent_id);
use ZChat::Utils ':all';
use ZChat::ansi;

sub new {
    my ($class, %opts) = @_;

    my $self = {
        storage => ($opts{storage} // die "storage required"),
        session_name => ($opts{session_name} // ''),
        override_pproc => $opts{override_pproc},
        effective_config => {},
        _session_config_cache => undef,  # Cache to avoid redundant loads
        _shell_session_id => undef,      # Cache shell session ID
    };

    bless $self, $class;
    return $self;
}

sub load_effective_config($self, $cli_optshro=undef) {
    $cli_optshro ||= {};

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

    # 3. Environment variable override
    my $env_session = $ENV{ZCHAT_SESSION};
    if ($env_session) {
        $config->{session} = $env_session;
        sel(2, "Using ZCHAT_SESSION env: $env_session");
    }

    # 4. Shell session config (PPID-scoped)
    my $shell_config = $self->_load_shell_config();
    if ($shell_config) {
        %$config = (%$config, %$shell_config);
        
        # Record source-specific copies for shell scope
        $config->{system_file_shell}    = $shell_config->{system_file}    if defined $shell_config->{system_file};
        $config->{system_string_shell}  = $shell_config->{system_string}  if defined $shell_config->{system_string};
        $config->{system_persona_shell} = $shell_config->{system_persona} if defined $shell_config->{system_persona};
        $config->{system_shell}         = $shell_config->{system}         if defined $shell_config->{system};
        
        sel(2, "Loaded shell session config overrides");
    }

    # 5. Session config
    my $effective_session = $self->_resolve_session_name($cli_optshro, $config);
    $config->{session} = $effective_session;
    sel(2, "Using session '$effective_session'");

    my $session_config;
    if ($effective_session) {
        $self->{session_name} = $effective_session;
        $session_config = $self->_load_session_config();
        if ($session_config) {
            %$config = (%$config, %$session_config);
            sel(2, "Loaded session config overrides");
        }
    }

    # Record source-specific copies for precedence resolution
    $config->{system_file_user}       = $user_config->{system_file}       if $user_config && defined $user_config->{system_file};
    $config->{system_string_user}     = $user_config->{system_string}     if $user_config && defined $user_config->{system_string};
    $config->{system_persona_user}    = $user_config->{system_persona}    if $user_config && defined $user_config->{system_persona};
    $config->{system_user}            = $user_config->{system}            if $user_config && defined $user_config->{system};

    if ($session_config) {
        $config->{system_file_session}    = $session_config->{system_file}    if defined $session_config->{system_file};
        $config->{system_string_session}  = $session_config->{system_string}  if defined $session_config->{system_string};
        $config->{system_persona_session} = $session_config->{system_persona} if defined $session_config->{system_persona};
        $config->{system_session}         = $session_config->{system}         if defined $session_config->{system};
    }

    # 6. CLI overrides (runtime only) — stash source-marked copies
    if (defined $cli_optshro->{system_string}) { $config->{system_string} = $cli_optshro->{system_string};  $config->{_cli_system_string} = $cli_optshro->{system_string};
        sel(2, "Setting system_string from CLI options"); }
    if (defined $cli_optshro->{system_file}) { $config->{system_file}   = $cli_optshro->{system_file}; $config->{_cli_system_file} = $cli_optshro->{system_file};
        sel(2, "Setting system_file from CLI options"); }
    if (defined $cli_optshro->{system_persona}) { $config->{system_persona} = $cli_optshro->{system_persona}; $config->{_cli_system_persona} = $cli_optshro->{system_persona};
        sel(2, "Setting system_persona from CLI options"); }
    if (defined $cli_optshro->{system}) { $config->{system} = $cli_optshro->{system}; $config->{_cli_system} = $cli_optshro->{system};
        sel(2, "Setting system from CLI options"); }

    # Preserve pin_shims / pin_mode CLI handling
    if (defined $cli_optshro->{pin_shims}) {
        $config->{pin_shims} = $cli_optshro->{pin_shims};
        sel(2, "Setting pin_shims from CLI options");
    }
    if (defined $cli_optshro->{pin_mode_sys}) {
        $config->{pin_mode_sys} = $cli_optshro->{pin_mode_sys};
        sel(2, "Setting pin_mode_sys '$cli_optshro->{pin_mode_sys}' from CLI options");
    }
    if (defined $cli_optshro->{pin_mode_user}) {
        $config->{pin_mode_user} = $cli_optshro->{pin_mode_user};
        sel(2, "Setting pin_mode_user '$cli_optshro->{pin_mode_user}' from CLI options");
    }
    if (defined $cli_optshro->{pin_mode_ast}) {
        $config->{pin_mode_ast} = $cli_optshro->{pin_mode_ast};
        sel(2, "Setting pin_mode_ast '$cli_optshro->{pin_mode_ast}' from CLI options");
    }
    $config->{_cli_pin_shims}     = $cli_optshro->{pin_shims}     if defined $cli_optshro->{pin_shims};
    $config->{_cli_pin_mode_sys}  = $cli_optshro->{pin_mode_sys}  if defined $cli_optshro->{pin_mode_sys};
    $config->{_cli_pin_mode_user} = $cli_optshro->{pin_mode_user} if defined $cli_optshro->{pin_mode_user};
    $config->{_cli_pin_mode_ast}  = $cli_optshro->{pin_mode_ast}  if defined $cli_optshro->{pin_mode_ast};

    $self->{effective_config} = $config;
    return $config;
}

sub _resolve_session_name($self, $cli_optshr, $config) {
    $cli_optshr ||= {};

    # CLI session takes precedence
    return $cli_optshr->{session} if defined $cli_optshr->{session} && $cli_optshr->{session} ne '';

    # Then original session_name from constructor
    return $self->{session_name} if defined $self->{session_name} && $self->{session_name} ne '';

    # Then user config session
    return $config->{session} if defined $config->{session} && $config->{session} ne '';

    # Finally default
    return 'default';
}

sub get_session_name($self) {
    return $self->{effective_config}->{session} // 'default';
}

sub _get_system_defaults {
    return {
        session => '',
        system_string => 'You are a helpful AI assistant.',
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
        pin_tpl_user => undef,
        pin_tpl_ast => undef,
        pin_mode_sys => 'vars',      # vars|concat|both
        pin_mode_user => 'concat',   # vars|varsfirst|concat  
        pin_mode_ast => 'concat',    # vars|varsfirst|concat
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

    # Return cached version if available
    return $self->{_session_config_cache} if defined $self->{_session_config_cache};

    my $session_dir = $self->_get_session_dir();
    my $session_config_file = File::Spec->catfile($session_dir, 'session.yaml');
    sel 1, "Loading Session config file: $session_config_file";
    my $yaml = $self->{storage}->load_yaml($session_config_file);
    sel 3, "  YAML result: ", ($yaml // 'unable to load');

    # Cache the result
    $self->{_session_config_cache} = $yaml;

    return $yaml;
}

sub store_user_config($self, $optshr) {
    my $config_dir = $self->_get_config_dir();
    make_path($config_dir) unless -d $config_dir;

    my $user_config_file = File::Spec->catfile($config_dir, 'user.yaml');

    # Load existing config
    my $existing = $self->_load_user_config() || {};

    for my $key (qw(session system_string system_file system_persona system pin_tpl_user pin_tpl_ast pin_mode_sys pin_mode_user pin_mode_ast)) {
        if (defined $optshr->{$key}) {
            $existing->{$key} = $optshr->{$key};
        }
    }
    if (defined $optshr->{pin_shims}) {
        $existing->{pin_shims} = $optshr->{pin_shims};
    }

    sel 1, "Saving user config as YAML at: $user_config_file";
    return $self->{storage}->save_yaml($user_config_file, $existing);
}

sub store_session_config($self, $optshr) {
    my $session_dir = $self->{storage}->get_session_dir($self->{session_name});
    make_path($session_dir) unless -d $session_dir;

    my $session_config_file = File::Spec->catfile($session_dir, 'session.yaml');

    # Use cached session config if available, otherwise load it
    my $existing = $self->{_session_config_cache} || $self->_load_session_config() || {};

    # Add created timestamp if new
    $existing->{created} = time() unless exists $existing->{created};

    # If storing any system source, clear others in this scope
    if (defined $optshr->{system_string} || defined $optshr->{system_file} || 
        defined $optshr->{system_persona} || defined $optshr->{system}) {
        
        # Clear all system sources in session config
        delete $existing->{system_string};
        delete $existing->{system_file}; 
        delete $existing->{system_persona};
        delete $existing->{system};
        
        # Set the new one
        for my $key (qw(system_string system_file system_persona system)) {
            $existing->{$key} = $optshr->{$key} if defined $optshr->{$key};
        }
    }

    # Update with new values
    for my $key (qw(system_string system_file system_persona system pin_tpl_user pin_tpl_ast pin_mode_sys pin_mode_user pin_mode_ast)) {
        if (defined $optshr->{$key}) {
            if (($optshr->{$key} // '') eq '') {
                sel 1, "Clearing $key in session config";
                delete $existing->{$key};
            } else {
                $existing->{$key} = $optshr->{$key};
                sel 1, "Storing $key = $$optshr{$key} in session config";
            }
        }
    }
    if (defined $optshr->{pin_shims}) {
        $existing->{pin_shims} = $optshr->{pin_shims};
    }

    # Update cache with new values
    $self->{_session_config_cache} = $existing;

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

sub get_readline_filename {
    my ($self) = @_;
    return File::Spec->catdir($self->_get_config_dir(), "readline_history.txt");
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

sub get_pin_mode_sys {
    my ($self) = @_;
    return $self->{effective_config}->{pin_mode_sys} || 'vars';
}

sub get_pin_mode_user {
    my ($self) = @_;
    return $self->{effective_config}->{pin_mode_user} || 'concat';
}

sub get_pin_mode_ast {
    my ($self) = @_;
    return $self->{effective_config}->{pin_mode_ast} || 'concat';
}

sub get_pin_tpl_user {
    my ($self) = @_;
    return $self->{effective_config}->{pin_tpl_user};
}

sub get_pin_tpl_ast {
    my ($self) = @_;
    return $self->{effective_config}->{pin_tpl_ast};
}

sub set_system_candidate {
    # kv_optshr:
    # { file_or_persona => $name });
    # { system_file => $path });
    # { system_persona => $name });
    # { system_string => $text });
    # { system => $name });
    my ($self, $scope, $kv_optshr) = @_;
    $kv_optshr ||= {};
    die "set_system_candidate: scope required" unless defined $scope;
    die "set_system_candidate: exactly one key" unless keys(%{$kv_optshr}) == 1;
    my ($k) = keys %$kv_optshr;
    my $v = $kv_optshr->{$k};
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

sub _get_shell_session_id {
    my ($self) = @_;
    
    return $self->{_shell_session_id} if defined $self->{_shell_session_id};
    
    if (defined $self->{override_pproc}) {
        # User override - just use it directly
        $self->{_shell_session_id} = $self->{override_pproc};
    } else {
        # Use the robust cross-platform parent ID
        $self->{_shell_session_id} = get_parent_id();
    }
    
    return $self->{_shell_session_id};
}

sub _get_shell_config_file {
    my ($self) = @_;
    
    my $uid = $<;
    my $session_id = $self->_get_shell_session_id();
    my $filename = "/tmp/zchat-$uid-$session_id.yaml";
    return $filename;
}

sub _load_shell_config {
    my ($self) = @_;
    
    my $shell_config_file = $self->_get_shell_config_file();
    sel 2, "Checking shell config: $shell_config_file";
    my @stat = stat($shell_config_file);
    my $yaml;
    if (@stat > 0) {
        if ($stat[4] != $<) {
            serr "ERROR: Shell session file is not owned by me! ($shell_config_file)";
            exit 1;
        } else {
            $yaml = $self->{storage}->load_yaml($shell_config_file);
        }
    }
    return $yaml; # undef if !-e
}

sub store_shell_config {
    my ($self, $optshr) = @_;
    
    my $shell_config_file = $self->_get_shell_config_file();

    # Errors out on failure to create but not if exists. Validates ownership.
    file_create_secure($shell_config_file, 0660);
    
    # Shell config can store session name AND system prompt options
    my $config = {};
    
    # Always store session name
    $config->{session} = $optshr->{session} if defined $optshr->{session};
    
    # Store system prompt options if provided
    $config->{system_string}  = $optshr->{system_string}  if defined $optshr->{system_string};
    $config->{system_file}    = $optshr->{system_file}    if defined $optshr->{system_file};
    $config->{system_persona} = $optshr->{system_persona} if defined $optshr->{system_persona};
    $config->{system}         = $optshr->{system}         if defined $optshr->{system};
    
    sel 1, "Saving shell session config: $shell_config_file";
    return $self->{storage}->save_yaml($shell_config_file, $config);
}

## STATUS routines

sub get_status_info {
    my ($self) = @_;
    
    my $cfg = $self->{effective_config};
    my $info = {
        precedence => {},
        sources => {},
        file_locations => {},
    };
    
    # Build precedence chain for system prompt
    $info->{precedence}{system_prompt} = $self->_build_system_prompt_precedence($cfg);
    $info->{precedence}{session} = $self->_build_session_precedence($cfg);
    
    # Build sources view
    $info->{sources} = $self->_build_sources_view($cfg);
    
    # File locations
    $info->{file_locations} = $self->_get_file_locations();
    
    return $info;
}

sub _build_system_prompt_precedence {
    my ($self, $cfg) = @_;
    
    my @chain;
    my $active_found = 0;
    
    # CLI level (highest precedence)
    if (defined $cfg->{_cli_system_file}) {
        push @chain, {
            source => 'CLI',
            type => 'system_file', 
            value => $cfg->{_cli_system_file},
            active => !$active_found,
            location => 'command line'
        };
        $active_found = 1;
    }
    if (defined $cfg->{_cli_system_string}) {
        push @chain, {
            source => 'CLI',
            type => 'system_string',
            value => $cfg->{_cli_system_string}, 
            active => !$active_found,
            location => 'command line'
        };
        $active_found = 1;
    }
    if (defined $cfg->{_cli_system_persona}) {
        push @chain, {
            source => 'CLI',
            type => 'system_persona',
            value => $cfg->{_cli_system_persona},
            active => !$active_found, 
            location => 'command line'
        };
        $active_found = 1;
    }
    if (defined $cfg->{_cli_system}) {
        push @chain, {
            source => 'CLI',
            type => 'system',
            value => $cfg->{_cli_system},
            active => !$active_found,
            location => 'command line' 
        };
        $active_found = 1;
    }
    
    # Shell level (new - between CLI and SESSION)
    for my $field (qw(system_file_shell system_string_shell system_persona_shell system_shell)) {
        next unless defined $cfg->{$field};
        my ($type) = $field =~ /^(.+)_shell$/;
        push @chain, {
            source => 'SHELL',
            type => $type,
            value => $cfg->{$field},
            active => !$active_found,
            location => $self->_get_shell_config_file()
        };
        $active_found = 1;
    }
    
    # Session level
    for my $field (qw(system_file_session system_string_session system_persona_session system_session)) {
        next unless defined $cfg->{$field};
        my ($type) = $field =~ /^(.+)_session$/;
        push @chain, {
            source => 'SESSION',
            type => $type,
            value => $cfg->{$field},
            active => !$active_found,
            location => $self->_get_session_config_path()
        };
        $active_found = 1;
    }
    
    # User level  
    for my $field (qw(system_file_user system_string_user system_persona_user system_user)) {
        next unless defined $cfg->{$field};
        my ($type) = $field =~ /^(.+)_user$/;
        push @chain, {
            source => 'USER',
            type => $type, 
            value => $cfg->{$field},
            active => !$active_found,
            location => $self->_get_user_config_path()
        };
        $active_found = 1;
    }
    
    return \@chain;
}

sub _build_session_precedence {
    my ($self, $cfg) = @_;
    
    my @chain;
    my $active_found = 0;
    
    # CLI session
    if (defined $cfg->{_cli_session}) {
        push @chain, {
            source => 'CLI',
            type => 'session',
            value => $cfg->{_cli_session},
            active => !$active_found,
            location => 'command line'
        };
        $active_found = 1;
    }
    
    # SHELL (shell session)  
    my $shell_config = $self->_load_shell_config();
    if ($shell_config && $shell_config->{session}) {
        push @chain, {
            source => 'SHELL',
            type => 'session',
            value => $shell_config->{session},
            active => !$active_found,
            location => $self->_get_shell_config_file()
        };
        $active_found = 1;
    }
    
    # User session
    my $user_config = $self->_load_user_config();
    if ($user_config && $user_config->{session}) {
        push @chain, {
            source => 'USER', 
            type => 'session',
            value => $user_config->{session},
            active => !$active_found,
            location => $self->_get_user_config_path()
        };
        $active_found = 1;
    }
    
    # System default
    push @chain, {
        source => 'SYSTEM',
        type => 'session', 
        value => 'default',
        active => !$active_found,
        location => 'system defaults'
    };
    
    return \@chain;
}

sub _build_sources_view {
    my ($self, $cfg) = @_;
    
    my $sources = {};
    
    # CLI sources
    my $cli = {};
    $cli->{system_string} = $cfg->{_cli_system_string} if defined $cfg->{_cli_system_string};
    $cli->{system_file} = $cfg->{_cli_system_file} if defined $cfg->{_cli_system_file};
    $cli->{system_persona} = $cfg->{_cli_system_persona} if defined $cfg->{_cli_system_persona};
    $cli->{system} = $cfg->{_cli_system} if defined $cfg->{_cli_system};
    $cli->{session} = $cfg->{_cli_session} if defined $cfg->{_cli_session};
    $sources->{CLI} = $cli if keys %$cli;
    
    # Shell sources
    my $shell_config = $self->_load_shell_config();
    if ($shell_config && keys %$shell_config) {
        my $filtered = {};
        for my $key (qw(system_string system_file system_persona system session)) {
            $filtered->{$key} = $shell_config->{$key} if defined $shell_config->{$key};
        }
        $sources->{SHELL} = $filtered if keys %$filtered;
    }
    
    # Session sources
    my $session_config = $self->_load_session_config();
    if ($session_config && keys %$session_config) {
        my $filtered = {};
        for my $key (qw(system_string system_file system_persona system)) {
            $filtered->{$key} = $session_config->{$key} if defined $session_config->{$key};
        }
        $sources->{SESSION} = $filtered if keys %$filtered;
    }
    
    # User sources  
    my $user_config = $self->_load_user_config();
    if ($user_config && keys %$user_config) {
        my $filtered = {};
        for my $key (qw(system_string system_file system_persona system session)) {
            $filtered->{$key} = $user_config->{$key} if defined $user_config->{$key};
        }
        $sources->{USER} = $filtered if keys %$filtered;
    }
    
    # System defaults
    my $defaults = $self->_get_system_defaults();
    $sources->{SYSTEM} = { session => $defaults->{session} };
    
    return $sources;
}

sub _get_file_locations {
    my ($self) = @_;
    
    return {
        SESSION => $self->_get_session_config_path(),
        USER => $self->_get_user_config_path(), 
        SHELL => $self->_get_shell_config_file(),
        SYSTEM => 'built-in defaults'
    };
}

sub _get_session_config_path {
    my ($self) = @_;
    return undef unless $self->{session_name};
    my $session_dir = $self->_get_session_dir();
    return File::Spec->catfile($session_dir, 'session.yaml');
}

sub _get_user_config_path {
    my ($self) = @_;
    my $config_dir = $self->_get_config_dir();
    return File::Spec->catfile($config_dir, 'user.yaml');
}

# Add this method to ZChat 

sub show_status {
    my ($self, $verbose_level) = @_;
    $verbose_level //= 0;
    
    my $def_abbr_sysstr = 30;
    
    my $status_info = $self->{config}->get_status_info();
    
    say "${a_stat_actline}* Precedence:$rst";
    
    # System prompt precedence
    say "  - System prompt";
    my $indent = "   ";
    for my $item (@{$status_info->{precedence}{system_prompt}}) {
        my $active_marker = $item->{active} ? "${a_stat_acttag}[active]$rst" : "${a_stat_undeftag}[unused]$rst";
        my $value = $item->{value};
        
        # Truncate system strings unless -vv
        if ($item->{type} eq 'system_string' && $verbose_level < 2) {
            $value = substr($value, 0, $def_abbr_sysstr) . ".." if length($value) > $def_abbr_sysstr;
        }
        
        if ($item->{active}) {
            say "${indent}<- $item->{source}($item->{type}) = \"${a_stat_actval}${value}$rst\" $active_marker";
        } else {
            say "${indent} <- $item->{source}($item->{type}) = '$value' $active_marker";  
        }
        say "${indent}    Loc: $item->{location}" if $item->{location} ne 'command line';
        $indent .= " ";
    }
    
    # Session precedence
    say "  - Session";
    $indent = "   ";
    for my $item (@{$status_info->{precedence}{session}}) {
        my $active_marker = $item->{active} ? "${a_stat_acttag}[active]$rst" : "${a_stat_undeftag}[unused]$rst";
        
        if ($item->{active}) {
            say "${indent}<- $item->{source} = \"${a_stat_actval}$item->{value}$rst\" $active_marker";
        } else {
            say "${indent} <- $item->{source}($item->{type}) = '$item->{value}' $active_marker";
        }
        say "${indent}    Loc: $item->{location}" if $item->{location} ne 'command line' && $item->{location} ne 'system defaults';
        $indent .= " ";
    }
    
    say "${a_stat_actline}* Sources:$rst";
    
    # Sources view
    for my $source_name (qw(CLI SHELL SESSION USER SYSTEM)) {
        my $source_data = $status_info->{sources}{$source_name};
        next unless $source_data && keys %$source_data;
        
        my $location = $status_info->{file_locations}{$source_name} || '';
        say "  - $source_name" . ($location ? ": $location" : "");
        
        for my $key (sort keys %$source_data) {
            my $value = $source_data->{$key};
            
            # Truncate system strings unless -vv
            if ($key eq 'system_string' && $verbose_level < 2) {
                $value = substr($value, 0, $def_abbr_sysstr) . ".." if length($value) > $def_abbr_sysstr;
            }
            
            # Determine if this setting is actually being used
            my $is_used = $self->_is_setting_used($source_name, $key, $status_info);
            my $usage_tag = $is_used ? "${a_stat_acttag}[used]$rst" : "${a_stat_undeftag}[unused]$rst";
            
            say "    $key: '$value' $usage_tag";
        }
    }
}

sub _is_setting_used {
    my ($self, $source_name, $key, $status_info) = @_;
    
    # Check if this source/key combination is the active one in precedence
    for my $category (values %{$status_info->{precedence}}) {
        for my $item (@$category) {
            if ($item->{active} && $item->{source} eq $source_name) {
                return 1 if ($key eq $item->{type}) || ($key eq 'session' && $item->{type} eq 'session');
            }
        }
    }
    return 0;
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
    my $effective = $config->load_effective_config( {
       ??
    } );

    # Store configurations
    $config->store_user_config({preset => "default"});
    $config->store_session_config({preset => "coding"});

=head1 DESCRIPTION

Handles configuration loading and storage with proper precedence:
system defaults → user config → session config → CLI overrides

=cut

# vim: et
