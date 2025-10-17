package ZChat::Defaults;
use v5.26.3;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
    CACHE_MODEL_INFO_TTL
    CACHE_MIN_UPDATE_INTERVAL
    DEFAULT_N_CTX
    CONTEXT_SAFETY_MARGIN
    MIN_HISTORY_MESSAGES
    DEFAULT_CHARS_PER_TOKEN
    DEFAULT_PIN_MAX
    DEFAULT_N_PREDICT
    DEFAULT_TEMPERATURE
    DEFAULT_TOP_K
    DEFAULT_TOP_P
    DEFAULT_MIN_P
);

use constant {
    # Cache timeouts (seconds)
    CACHE_MODEL_INFO_TTL => 86400,        # 24 hours
    CACHE_MIN_UPDATE_INTERVAL => 28800,   # 8 hours (24/3) - throttle cache writes
    
    # Context management
    DEFAULT_N_CTX => 22000,
    CONTEXT_SAFETY_MARGIN => 0.85,        # Use 85% of context
    MIN_HISTORY_MESSAGES => 4,            # Keep at least last 2 exchanges
    
    # Token estimation
    DEFAULT_CHARS_PER_TOKEN => 3.5,
    
    # Pin limits
    DEFAULT_PIN_MAX => 50,
    
    # API request defaults
    DEFAULT_N_PREDICT => 8192,
    DEFAULT_TEMPERATURE => 0.7,
    DEFAULT_TOP_K => 40,
    DEFAULT_TOP_P => 0.9,
    DEFAULT_MIN_P => 0.08,
};

1;

__END__

=head1 NAME

ZChat::Defaults - Centralized default values and constants

=head1 SYNOPSIS

    use ZChat::Defaults qw(CACHE_MODEL_INFO_TTL DEFAULT_N_CTX);
    
    my $ttl = CACHE_MODEL_INFO_TTL;
    my $ctx = DEFAULT_N_CTX;

=head1 DESCRIPTION

Centralized location for all default values, timeouts, and constants
used throughout ZChat. As code is touched, constants should be migrated
here from their scattered locations.

=cut
