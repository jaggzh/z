package ZChat::ContextManager;
use v5.26.3;
use experimental 'signatures';
use strict;
use warnings;
use File::Path qw(make_path);
use File::Spec;
use YAML::XS qw(LoadFile DumpFile);

use ZChat::Utils ':all';
use ZChat::Defaults qw(
    CACHE_MODEL_INFO_TTL
    CACHE_MIN_UPDATE_INTERVAL
    DEFAULT_N_CTX
    CONTEXT_SAFETY_MARGIN
    MIN_HISTORY_MESSAGES
    DEFAULT_CHARS_PER_TOKEN
);

sub new {
    my ($class, %opts) = @_;
    
    # Build cache file path properly
    my $home = $ENV{HOME} || die "HOME environment variable not set";
    my $config_dir = File::Spec->catdir($home, '.config', 'zchat');
    
    # Ensure directory exists
    make_path($config_dir) unless -d $config_dir;
    
    my $self = {
        core => ($opts{core} // die "core required"),
        cache_file => File::Spec->catfile($config_dir, 'model_cache.yaml'),
        models_file => File::Spec->catfile($config_dir, 'models.yaml'),
        char_token_ratio => DEFAULT_CHARS_PER_TOKEN,
        safety_margin => CONTEXT_SAFETY_MARGIN,
        min_history_messages => MIN_HISTORY_MESSAGES,
        cache => {},              # Initialize empty cache
        models => {},             # Persistent per-model settings (non-expiring)
        cache_dirty => 0,         # Track if cache needs writing
    };
    
    bless $self, $class;
    $self->_load_cache();
    $self->_load_models();
    return $self;
}

sub _load_cache {
    my ($self) = @_;
    
    # Skip if file doesn't exist
    return unless -f $self->{cache_file};
    
    eval {
        $self->{cache} = LoadFile($self->{cache_file}) || {};
    };
    if ($@) {
        warn "Failed to load cache: $@\n";
        $self->{cache} = {};
    }
}

sub _save_cache {
    my ($self, $force) = @_;
    
    return unless $self->{cache_dirty} || $force;
    
    # Check if enough time has passed since last write (throttle writes)
    my $last_write = $self->{cache}{_last_write_time} // 0;
    my $now = time;
    
    unless ($force || ($now - $last_write) >= CACHE_MIN_UPDATE_INTERVAL) {
        sel(3, "Throttling cache write (last write " . ($now - $last_write) . "s ago)");
        return;
    }
    
    $self->{cache}{_last_write_time} = $now;
    
    eval {
        DumpFile($self->{cache_file}, $self->{cache});
        $self->{cache_dirty} = 0;
        sel(3, "Wrote cache to disk");
    };
    warn "Failed to save cache: $@\n" if $@;
}

sub _load_models {
    my ($self) = @_;
    return unless -f $self->{models_file};
    eval {
        $self->{models} = LoadFile($self->{models_file}) || {};
    };
    if ($@) {
        warn "Failed to load models: $@\n";
        $self->{models} = {};
    }
}

sub _save_models {
    my ($self) = @_;
    eval {
        DumpFile($self->{models_file}, $self->{models});
    };
    warn "Failed to save models: $@\n" if $@;
}

sub _get_cached_model_name {
    my ($self) = @_;
    
    my $api_url = $self->{core}{api_url} // '';
    my $backend = $self->{core}{backend} // 'llama.cpp';
    
    my $last_known = $self->{cache}{last_known_model};
    return undef unless $last_known;
    
    # Verify it matches our current connection
    if (($last_known->{api_url} // '') eq $api_url &&
        ($last_known->{backend} // '') eq $backend) {
        
        my $age = time - ($last_known->{timestamp} || 0);
        if ($age < CACHE_MODEL_INFO_TTL) {
            sel(2, "Using cached model name: $$last_known{name} (age: ${age}s)");
            return $last_known->{name};
        } else {
            sel(2, "Cached model name expired (age: ${age}s)");
        }
    }
    
    return undef;
}

sub _update_cached_model_name {
    my ($self, $model_name) = @_;
    
    my $api_url = $self->{core}{api_url} // '';
    my $backend = $self->{core}{backend} // 'llama.cpp';
    
    my $last_known = $self->{cache}{last_known_model} // {};
    
    # Only update if name changed or doesn't exist
    if (!$last_known->{name} || $last_known->{name} ne $model_name) {
        sel(2, "Updating cached model name: $model_name");
        $self->{cache}{last_known_model} = {
            name => $model_name,
            timestamp => time,
            api_url => $api_url,
            backend => $backend,
        };
        $self->{cache_dirty} = 1;
        
        # If model changed, invalidate old ctx cache
        if ($last_known->{name} && $last_known->{name} ne $model_name) {
            my $old_key = "ctx_$$last_known{name}";
            delete $self->{cache}{$old_key};
            sel(2, "Invalidated ctx cache for old model: $$last_known{name}");
        }
    }
}

sub get_model_context_size {
    my ($self, $force_refresh) = @_;
    
    my $model_name;
    my $model_key;
    
    # Try to get model name from cache first (fast path - no server hit)
    unless ($force_refresh) {
        $model_name = $self->_get_cached_model_name();
        if ($model_name) {
            $model_key = join(':', 
                $self->{core}{backend} // 'llama.cpp',
                $self->{core}{api_url} // '',
                $model_name
            );
        }
    }
    
    # Need to hit server to get model name
    unless ($model_name) {
        sel(2, "Fetching model name from server");
        $model_name = $self->{core}->get_model_name($force_refresh);
        $model_key = eval { $self->{core}->get_model_key() } // $model_name;
        
        # Cache the model name for next time
        $self->_update_cached_model_name($model_name);
    }
    
    my $cache_key = "ctx_$model_name";

    # Check for forced max_ctx
    if (my $forced = $self->{models}{$model_key}{max_ctx}) {
        sel(2, "Using forced max_ctx for model $model_key: $forced");
        $self->{cache}{$cache_key} = {
            n_ctx => $forced,
            timestamp => time,
            model => $model_name,
        };
        $self->{cache_dirty} = 1;
        $self->_save_cache();
        return $forced;
    }
    
    # Check cache first (valid for 24 hours) unless force_refresh
    if (!$force_refresh && (my $cached = $self->{cache}{$cache_key})) {
        my $age = time - $cached->{timestamp};
        if ($age < CACHE_MODEL_INFO_TTL) {
            sel(2, "Using cached n_ctx for $model_name: $$cached{n_ctx} (age: ${age}s)");
            return $cached->{n_ctx};
        } else {
            sel(2, "Cached n_ctx expired (age: ${age}s)");
        }
    }
    
    # Fetch fresh - but model_info may already be loaded if we got model_name above
    sel(2, "Fetching fresh n_ctx from server for $model_name");
    my $n_ctx = $self->{core}->get_n_ctx($force_refresh);
    
    # Cache it
    $self->{cache}{$cache_key} = {
        n_ctx => $n_ctx,
        timestamp => time,
        model => $model_name,
    };
    $self->{cache_dirty} = 1;
    $self->_save_cache();
    
    return $n_ctx;
}

sub estimate_tokens {
    my ($self, $text) = @_;
    
    # Use cached ratio if available for this model
    my $model_name = $self->{core}->get_model_name();
    my $ratio_key = "ratio_$model_name";
    
    my $ratio = $self->{cache}{$ratio_key}{ratio} // $self->{char_token_ratio};
    
    return int(length($text) / $ratio);
}

sub update_ratio_from_actual {
    my ($self, $text, $actual_tokens) = @_;
    
    return if $actual_tokens == 0;
    
    my $model_name = $self->{core}->get_model_name();
    my $ratio_key = "ratio_$model_name";
    
    my $new_ratio = length($text) / $actual_tokens;
    
    # Exponential moving average to smooth updates
    my $old_ratio = $self->{cache}{$ratio_key}{ratio} // $self->{char_token_ratio};
    my $updated_ratio = (0.7 * $old_ratio) + (0.3 * $new_ratio);
    
    $self->{cache}{$ratio_key} = {
        ratio => $updated_ratio,
        samples => ($self->{cache}{$ratio_key}{samples} // 0) + 1,
        timestamp => time,
    };
    
    $self->{cache_dirty} = 1;
    
    # Throttled save - only every 10 samples
    $self->_save_cache() if ($self->{cache}{$ratio_key}{samples} % 10) == 0;
}

sub update_model_from_response {
    my ($self, $response_metadata) = @_;
    
    return unless $response_metadata && $response_metadata->{model};
    
    my $model_name = $response_metadata->{model};
    $self->_update_cached_model_name($model_name);
    $self->_save_cache();  # Save immediately on model name updates
}

sub fit_messages_to_context {
    my ($self, $messages, $system_content, $pins_messages) = @_;
    
    my $n_ctx = $self->get_model_context_size();
    my $max_tokens = int($n_ctx * $self->{safety_margin});
    
    # Calculate fixed overhead
    my $overhead_tokens = 0;
    
    # System prompt
    $overhead_tokens += $self->estimate_tokens($system_content) if $system_content;
    
    # Pins
    for my $pin (@$pins_messages) {
        $overhead_tokens += $self->estimate_tokens($pin->{content});
        $overhead_tokens += 10; # Role/format overhead
    }
    
    my $available_for_history = $max_tokens - $overhead_tokens;
    
    # Build history from most recent backwards
    my @fitted_messages;
    my $used_tokens = 0;
    
    # Reverse iterate through messages (newest first)
    my $kept_count = 0;
    for my $i (reverse 0..$#$messages) {
        my $msg = $messages->[$i];
        my $msg_tokens = $self->estimate_tokens($msg->{content}) + 10;
        
        # Always keep minimum history
        if ($kept_count < $self->{min_history_messages}) {
            unshift @fitted_messages, $msg;
            $used_tokens += $msg_tokens;
            $kept_count++;
            next;
        }
        
        # Check if we can fit more
        if ($used_tokens + $msg_tokens < $available_for_history) {
            unshift @fitted_messages, $msg;
            $used_tokens += $msg_tokens;
        } else {
            # Can't fit more, we're done
            last;
        }
    }
    
    # Log if we had to truncate
    if (@fitted_messages < @$messages) {
        my $dropped = @$messages - @fitted_messages;
        sel(1, "Context limit: kept " . @fitted_messages . " messages, dropped $dropped");
    }
    
    return \@fitted_messages;
}

sub set_persistent_max_ctx {
    my ($self, $model_key, $n) = @_;
    $self->{models}{$model_key} = {
        max_ctx => int($n),
        set_at  => time,
    };
    $self->_save_models();
}

# Destructor to ensure cache is written on exit
sub DESTROY {
    my ($self) = @_;
    $self->_save_cache(1) if $self->{cache_dirty};  # Force write on exit
}

1;
