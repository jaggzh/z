package ZChat::Storage;

use v5.34;
use warnings;
use utf8;

use YAML::XS qw(LoadFile DumpFile);
use JSON::XS;
use File::Slurper qw(write_text read_text read_binary);
use File::Spec;
use File::Path qw(make_path);
use Encode qw(decode encode_utf8);

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        umask => 0177,  # Secure file permissions
    };
    
    bless $self, $class;
    return $self;
}

# YAML operations
sub load_yaml {
    my ($self, $filepath) = @_;
    
    return undef unless -e $filepath;
    
    eval {
        return LoadFile($filepath);
    };
    
    if ($@) {
        warn "Failed to load YAML file '$filepath': $@";
        return undef;
    }
}

sub save_yaml {
    my ($self, $filepath, $data) = @_;
    
    # Ensure directory exists
    my $dir = (File::Spec->splitpath($filepath))[1];
    make_path($dir) if $dir && !-d $dir;
    
    my $old_umask = umask($self->{umask});
    
    eval {
        DumpFile($filepath, $data);
    };
    
    umask($old_umask);
    
    if ($@) {
        warn "Failed to save YAML file '$filepath': $@";
        return 0;
    }
    
    return 1;
}

# JSON operations (for conversation history)
sub load_json {
    my ($self, $filepath) = @_;
    
    return [] unless -e $filepath;
    
    my $raw_content;
    eval {
        $raw_content = read_binary($filepath);
        my $decoded = decode('UTF-8', $raw_content, Encode::FB_QUIET);
        
        # Handle trailing commas (lenient parsing)
        $decoded =~ s/,\s*(\]|\})/$1/g;
        
        return [] if $decoded =~ /^\s*$/;
        
        my $json = JSON::XS->new->relaxed(1);
        my $result = $json->decode($decoded);
        return ref($result) eq 'ARRAY' ? $result : [];
    };
    
    if ($@) {
        warn "Failed to load JSON file '$filepath': $@";
        return [];
    }
}

sub save_json {
    my ($self, $filepath, $data) = @_;
    
    # Ensure directory exists
    my $dir = (File::Spec->splitpath($filepath))[1];
    make_path($dir) if $dir && !-d $dir;
    
    my $old_umask = umask($self->{umask});
    
    eval {
        my $json = JSON::XS->new->pretty(1)->utf8->space_after;
        my $json_text = $json->encode($data);
        write_text($filepath, $json_text);
    };
    
    umask($old_umask);
    
    if ($@) {
        warn "Failed to save JSON file '$filepath': $@";
        return 0;
    }
    
    return 1;
}

# Plain text operations
sub read_file {
    my ($self, $filepath) = @_;
    
    return undef unless -e $filepath && -r $filepath;
    
    eval {
        my $content = read_text($filepath);
        return $content;
    };
    
    if ($@) {
        warn "Failed to read file '$filepath': $@";
        return undef;
    }
}

sub write_file {
    my ($self, $filepath, $content) = @_;
    
    # Ensure directory exists
    my $dir = (File::Spec->splitpath($filepath))[1];
    make_path($dir) if $dir && !-d $dir;
    
    my $old_umask = umask($self->{umask});
    
    eval {
        write_text($filepath, $content);
    };
    
    umask($old_umask);
    
    if ($@) {
        warn "Failed to write file '$filepath': $@";
        return 0;
    }
    
    return 1;
}

# Session-specific operations
sub get_session_dir {
    my ($self, $session_name) = @_;
    
    return undef unless $session_name;
    
    my $home = $ENV{HOME} || die "HOME environment variable not set";
    my $config_dir = File::Spec->catdir($home, '.config', 'zchat');
    my @session_parts = split('/', $session_name);
    
    return File::Spec->catdir($config_dir, 'sessions', @session_parts);
}

sub load_history {
    my ($self, $session_name) = @_;
    
    return [] unless $session_name;
    
    my $session_dir = $self->get_session_dir($session_name);
    return [] unless $session_dir;
    
    my $history_file = File::Spec->catfile($session_dir, 'history.json');
    my $history = $self->load_json($history_file);
    
    return [] unless $history && ref($history) eq 'ARRAY';
    
    # Convert to message format if needed
    my @messages;
    for my $entry (@$history) {
        if (exists $entry->{user}) {
            push @messages, { role => 'user', content => $entry->{user} };
        }
        if (exists $entry->{assistant}) {
            push @messages, { role => 'assistant', content => $entry->{assistant} };
        }
    }
    
    return \@messages;
}

sub save_history {
    my ($self, $session_name, $history) = @_;
    
    return 0 unless $session_name && $history;
    
    my $session_dir = $self->get_session_dir($session_name);
    return 0 unless $session_dir;
    
    make_path($session_dir) unless -d $session_dir;
    
    my $history_file = File::Spec->catfile($session_dir, 'history.json');
    
    # Convert from message format if needed
    my @entries;
    my $current_entry = {};
    
    for my $msg (@$history) {
        if ($msg->{role} eq 'user') {
            # Start new entry
            push @entries, $current_entry if keys %$current_entry;
            $current_entry = { user => $msg->{content} };
        } elsif ($msg->{role} eq 'assistant') {
            $current_entry->{assistant} = $msg->{content};
        }
    }
    
    # Add final entry
    push @entries, $current_entry if keys %$current_entry;
    
    return $self->save_json($history_file, \@entries);
}

sub append_to_history {
    my ($self, $session_name, $user_input, $assistant_response) = @_;
    
    return 0 unless $session_name;
    
    my $session_dir = $self->get_session_dir($session_name);
    return 0 unless $session_dir;
    
    my $history_file = File::Spec->catfile($session_dir, 'history.json');
    
    # Load existing history
    my $history = $self->load_json($history_file);
    $history = [] unless ref($history) eq 'ARRAY';  # Ensure it's always an array ref
    
    # Add new entry
    push @$history, {
        user => $user_input,
        assistant => $assistant_response,
    };
    
    return $self->save_json($history_file, $history);
}

# Pin operations
sub load_pins {
    my ($self, $session_name) = @_;
    
    return [] unless $session_name;
    
    my $session_dir = $self->get_session_dir($session_name);
    return [] unless $session_dir;
    
    my $pins_file = File::Spec->catfile($session_dir, 'pins.yaml');
    my $pin_data = $self->load_yaml($pins_file);
    
    return $pin_data ? ($pin_data->{pins} || []) : [];
}

sub save_pins {
    my ($self, $session_name, $pins) = @_;
    
    return 0 unless $session_name;
    
    my $session_dir = $self->get_session_dir($session_name);
    return 0 unless $session_dir;
    
    make_path($session_dir) unless -d $session_dir;
    
    my $pins_file = File::Spec->catfile($session_dir, 'pins.yaml');
    
    # Load existing pin data to preserve metadata
    my $existing = $self->load_yaml($pins_file) || {};
    
    # Update pins and ensure created timestamp
    $existing->{pins} = $pins;
    $existing->{created} = time() unless exists $existing->{created};
    
    return $self->save_yaml($pins_file, $existing);
}

# Utility methods
sub file_exists {
    my ($self, $filepath) = @_;
    return -e $filepath;
}

sub is_readable {
    my ($self, $filepath) = @_;
    return -r $filepath;
}

sub create_session_if_needed {
    my ($self, $session_name) = @_;
    
    return 0 unless $session_name;
    
    my $session_dir = $self->get_session_dir($session_name);
    return 0 unless $session_dir;
    
    unless (-d $session_dir) {
        make_path($session_dir);
        
        # Create initial session config
        my $session_config_file = File::Spec->catfile($session_dir, 'session.yaml');
        my $initial_config = {
            created => time(),
        };
        $self->save_yaml($session_config_file, $initial_config);
    }
    
    return 1;
}

1;

__END__

=head1 NAME

ZChat::Storage - File I/O operations for ZChat

=head1 SYNOPSIS

    use ZChat::Storage;
    
    my $storage = ZChat::Storage->new();
    
    # YAML operations
    my $config = $storage->load_yaml('/path/to/config.yaml');
    $storage->save_yaml('/path/to/config.yaml', $data);
    
    # History operations  
    my $history = $storage->load_history('session_name');
    $storage->append_to_history('session_name', $user_input, $response);
    
    # Pin operations
    my $pins = $storage->load_pins('session_name');
    $storage->save_pins('session_name', $pins);

=head1 DESCRIPTION

Handles all file I/O operations for ZChat including YAML configs,
JSON history files, and pin storage with secure file permissions.

=cut
