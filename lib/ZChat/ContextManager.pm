package ZChat::ContextManager;
use v5.26.3;
use experimental 'signatures';
use strict;
use warnings;
use File::Path qw(make_path);
use File::Spec;
use YAML::XS qw(LoadFile DumpFile);

use ZChat::Utils ':all';

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
        char_token_ratio => 3.5,  # Default estimate: 3.5 chars per token
        safety_margin => 0.85,    # Use 85% of context to leave room for response
        min_history_messages => 4, # Keep at least last 2 exchanges
        cache => {},              # Initialize empty cache
        models => {},             # Persistent per-model settings (non-expiring)
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
    my ($self) = @_;
    eval {
        DumpFile($self->{cache_file}, $self->{cache});
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

sub get_model_context_size {
    my ($self) = @_;
    
    my $model_name = $self->{core}->get_model_name();
    my $cache_key = "ctx_$model_name";
    my $model_key = eval { $self->{core}->get_model_key() } // $model_name;

    if (my $forced = $self->{models}{$model_key}{max_ctx}) {
        $self->{cache}{$cache_key} = {
            n_ctx => $forced,
            timestamp => time,
            model => $model_name,
        };
        $self->_save_cache();
        return $forced;
    }
    
    # Check cache first (valid for 24 hours)
    if (my $cached = $self->{cache}{$cache_key}) {
        if (time - $cached->{timestamp} < 86400) {
            return $cached->{n_ctx};
        }
    }
    
    # Fetch fresh
    my $n_ctx = $self->{core}->get_n_ctx();
    
    # Cache it
    $self->{cache}{$cache_key} = {
        n_ctx => $n_ctx,
        timestamp => time,
        model => $model_name,
    };
    $self->_save_cache();
    
    return $n_ctx;
}

sub set_persistent_max_ctx {
    my ($self, $model_key, $n) = @_;
    $self->{models}{$model_key} = {
        max_ctx => int($n),
        set_at  => time,
    };
    $self->_save_models();
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
    
    $self->_save_cache() if ($self->{cache}{$ratio_key}{samples} % 10) == 0;
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

1;
