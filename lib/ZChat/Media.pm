package ZChat::Media;
use v5.26.3;
use feature 'say';
use experimental 'signatures';
use strict;
use warnings;

use utf8;
use File::Spec;
use File::Path qw(make_path);
use File::Basename qw(basename dirname);
use File::Copy;
use Cwd qw(abs_path realpath);
use MIME::Base64;
use Time::HiRes qw(time);

use ZChat::Utils ':all';

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        storage => ($opts{storage} // die "storage required"),
        session_name => ($opts{session_name} // die "session_name required"),
        media_data => [],
        loaded => 0,
    };
    
    bless $self, $class;
    return $self;
}

sub set_session_name {
    my ($self, $name) = @_;
    $self->{session_name} = $name;
    $self->{loaded} = 0;
    return $self;
}

sub _load_media_yaml {
    my ($self) = @_;
    return if $self->{loaded};
    
    my $session_dir = $self->{storage}->get_session_dir($self->{session_name});
    return unless $session_dir;
    
    my $media_file = File::Spec->catfile($session_dir, 'media.yaml');
    
    if (-f $media_file) {
        $self->{media_data} = $self->{storage}->load_yaml($media_file);
        $self->{media_data} = [] unless ref($self->{media_data}) eq 'ARRAY';
    }
    
    $self->{loaded} = 1;
}

sub _save_media_yaml {
    my ($self) = @_;
    
    my $session_dir = $self->{storage}->get_session_dir($self->{session_name});
    return 0 unless $session_dir;
    
    make_path($session_dir) unless -d $session_dir;
    
    my $media_file = File::Spec->catfile($session_dir, 'media.yaml');
    return $self->{storage}->save_yaml($media_file, $self->{media_data});
}

sub _generate_id {
    my ($self) = @_;
    
    $self->_load_media_yaml();
    
    my $timestamp = sprintf("%.3f", time);
    $timestamp =~ s/\.//;  # Remove decimal point: 1704380422123
    
    # Find collision index
    my $idx = 0;
    my $id_base = substr($timestamp, 0, 10);  # Use first 10 digits
    
    for my $media (@{$self->{media_data}}) {
        if ($media->{id} =~ /^$id_base\.(\d+)$/) {
            my $existing_idx = $1;
            $idx = $existing_idx + 1 if $existing_idx >= $idx;
        }
    }
    
    return "$id_base.$idx";
}

sub _sanitize_basename {
    my ($self, $name) = @_;
    
    # Escape % as %%
    $name =~ s/%/%%/g;
    
    # Replace spaces and weird chars with _
    $name =~ s/[^\w\-\.%]/_/g;
    
    return $name;
}

sub _get_mime_type {
    my ($self, $path) = @_;
    
    # Simple extension-based detection
    my %mime_map = (
        # Images
        'jpg'  => 'image/jpeg',
        'jpeg' => 'image/jpeg',
        'png'  => 'image/png',
        'gif'  => 'image/gif',
        'webp' => 'image/webp',
        'bmp'  => 'image/bmp',
        'svg'  => 'image/svg+xml',
        
        # Audio
        'mp3'  => 'audio/mpeg',
        'wav'  => 'audio/wav',
        'ogg'  => 'audio/ogg',
        'flac' => 'audio/flac',
        'm4a'  => 'audio/mp4',
        'aac'  => 'audio/aac',
    );
    
    my ($ext) = $path =~ /\.([^.]+)$/;
    return 'application/octet-stream' unless $ext;
    
    $ext = lc($ext);
    return $mime_map{$ext} || 'application/octet-stream';
}

sub add_media {
    my ($self, $type_major, $path, $opts) = @_;
    $opts ||= {};
    
    die "Media type must be 'image' or 'audio'" unless $type_major =~ /^(image|audio)$/;
    die "Path required" unless defined $path && length $path;
    
    # Resolve path
    my $abs_path = realpath($path);
    die "Media file not found: $path\n" unless $abs_path && -f $abs_path;
    
    # Check if replacing by name
    my $name = $opts->{name};
    my $external = $opts->{external} || 0;
    
    $self->_load_media_yaml();
    
    # Look for existing by name
    my $existing;
    if (defined $name) {
        for my $media (@{$self->{media_data}}) {
            if (($media->{type_major} eq $type_major) && 
                (defined $media->{name}) && 
                ($media->{name} eq $name)) {
                $existing = $media;
                last;
            }
        }
    }
    
    my $id;
    my $base = basename($abs_path);
    my $sanitized_base = $self->_sanitize_basename($base);
    
    if ($existing) {
        # Replace existing
        $id = $existing->{id};
        sel(1, "Replacing existing $type_major '$name' (ID: $id)");
        
        # Remove old file
        my $old_stored = $existing->{stored};
        my $session_dir = $self->{storage}->get_session_dir($self->{session_name});
        my $old_path = File::Spec->catfile($session_dir, "${type_major}s", $old_stored);
        unlink $old_path if -e $old_path || -l $old_path;
        
    } else {
        # New media
        $id = $self->_generate_id();
        sel(1, "Adding new $type_major (ID: $id)");
    }
    
    # Determine storage name
    my $prefix = $external ? 'ext_' : '';
    my $stored_name = "${prefix}${id}_${sanitized_base}";
    
    # Copy or link
    my $session_dir = $self->{storage}->get_session_dir($self->{session_name});
    my $media_dir = File::Spec->catdir($session_dir, "${type_major}s");
    make_path($media_dir) unless -d $media_dir;
    
    my $dest_path = File::Spec->catfile($media_dir, $stored_name);
    
    if ($external) {
        symlink($abs_path, $dest_path) or die "Failed to create symlink: $!\n";
        sel(2, "Created symlink: $dest_path -> $abs_path");
    } else {
        File::Copy::copy($abs_path, $dest_path) or die "Failed to copy media: $!\n";
        sel(2, "Copied to: $dest_path");
    }
    
    # Get media info
    my $mime_type = $self->_get_mime_type($abs_path);
    my $size = -s $abs_path;
    
    # Update or create metadata
    my $media_entry = {
        id => $id,
        type_major => $type_major,
        name => $name,
        mime_type => $mime_type,
        size => $size,
        stored => $stored_name,
        external => $external ? 1 : 0,
        original_path => $abs_path,
        updated_at => time,
    };
    
    if ($existing) {
        # Update existing entry
        %$existing = %$media_entry;
    } else {
        # Add new entry
        push @{$self->{media_data}}, $media_entry;
    }
    
    $self->_save_media_yaml();
    
    return $id;
}

sub add_image {
    my ($self, $path, $opts) = @_;
    return $self->add_media('image', $path, $opts);
}

sub add_audio {
    my ($self, $path, $opts) = @_;
    return $self->add_media('audio', $path, $opts);
}

sub alias_media {
    my ($self, $type_major, $name_spec) = @_;
    
    die "Name specification required (format: <name>path or <newname><oldname>)" 
        unless defined $name_spec && length $name_spec;
    
    $self->_load_media_yaml();
    
    # Parse name spec
    if ($name_spec =~ /^<([^>]+)><([^>]+)>$/) {
        # Rename: <newname><oldname>
        my ($new_name, $old_name) = ($1, $2);
        
        # Find by old name
        my $media;
        for my $m (@{$self->{media_data}}) {
            if (($m->{type_major} eq $type_major) && 
                (defined $m->{name}) && 
                ($m->{name} eq $old_name)) {
                $media = $m;
                last;
            }
        }
        
        die "No $type_major found with name '$old_name'\n" unless $media;
        
        # Check if new name already exists
        for my $m (@{$self->{media_data}}) {
            if (($m->{type_major} eq $type_major) && 
                (defined $m->{name}) && 
                ($m->{name} eq $new_name)) {
                die "$type_major name '$new_name' already exists\n";
            }
        }
        
        sel(1, "Renaming $type_major '$old_name' to '$new_name'");
        $media->{name} = $new_name;
        
        # Rename file
        $self->_rename_media_file($media);
        
        $self->_save_media_yaml();
        return $media->{id};
        
    } elsif ($name_spec =~ /^<([^>]+)>(.+)$/) {
        # Assign name to path: <name>path
        my ($name, $path) = ($1, $2);
        
        my $abs_path = realpath($path);
        die "Media file not found: $path\n" unless $abs_path && -f $abs_path;
        
        # Find by path
        my $media;
        for my $m (@{$self->{media_data}}) {
            if (($m->{type_major} eq $type_major) && 
                ($m->{original_path} eq $abs_path)) {
                $media = $m;
                last;
            }
        }
        
        die "No $type_major found with path '$path'\n" unless $media;
        
        # Check if name already exists
        for my $m (@{$self->{media_data}}) {
            if (($m->{type_major} eq $type_major) && 
                (defined $m->{name}) && 
                ($m->{name} eq $name)) {
                die "$type_major name '$name' already exists\n";
            }
        }
        
        sel(1, "Assigning name '$name' to $type_major (ID: $$media{id})");
        $media->{name} = $name;
        
        # Rename file
        $self->_rename_media_file($media);
        
        $self->_save_media_yaml();
        return $media->{id};
        
    } else {
        die "Invalid name specification format\n";
    }
}

sub _rename_media_file {
    my ($self, $media) = @_;
    
    my $session_dir = $self->{storage}->get_session_dir($self->{session_name});
    my $media_dir = File::Spec->catdir($session_dir, "$$media{type_major}s");
    
    my $old_path = File::Spec->catfile($media_dir, $media->{stored});
    
    # Build new filename
    my $base = basename($media->{original_path});
    my $sanitized_base = $self->_sanitize_basename($base);
    my $prefix = $media->{external} ? 'ext_' : '';
    my $new_stored = "${prefix}$$media{id}_${sanitized_base}";
    
    my $new_path = File::Spec->catfile($media_dir, $new_stored);
    
    return if $old_path eq $new_path;  # No change needed
    
    if (-e $old_path || -l $old_path) {
        rename($old_path, $new_path) or warn "Failed to rename media file: $!\n";
        sel(2, "Renamed: $$media{stored} -> $new_stored");
        $media->{stored} = $new_stored;
    }
}

sub get_media_by_id {
    my ($self, $id) = @_;
    
    $self->_load_media_yaml();
    
    for my $media (@{$self->{media_data}}) {
        return $media if $media->{id} eq $id;
    }
    
    return undef;
}

sub get_media_full_path {
    my ($self, $id) = @_;
    
    my $media = $self->get_media_by_id($id);
    return undef unless $media;
    
    my $session_dir = $self->{storage}->get_session_dir($self->{session_name});
    my $media_dir = File::Spec->catdir($session_dir, "$$media{type_major}s");
    
    return File::Spec->catfile($media_dir, $media->{stored});
}

sub list_media {
    my ($self, $type_filter) = @_;
    
    $self->_load_media_yaml();
    
    my @result;
    for my $media (@{$self->{media_data}}) {
        next if defined $type_filter && $media->{type_major} ne $type_filter;
        
        push @result, {
            id => $media->{id},
            type => $media->{type_major},
            name => $media->{name},
            mime => $media->{mime_type},
            size => $media->{size},
            external => $media->{external},
            path => $media->{original_path},
            stored => $media->{stored},
        };
    }
    
    return \@result;
}

1;

__END__

=head1 NAME

ZChat::Media - Unified media management (images, audio) for ZChat

=head1 SYNOPSIS

    use ZChat::Media;
    
    my $media = ZChat::Media->new(
        storage => $storage,
        session_name => 'myproject'
    );
    
    # Add media
    my $id1 = $media->add_image('/path/to/image.jpg', {name => 'header'});
    my $id2 = $media->add_audio('/path/to/audio.mp3', {external => 1});
    
    # Alias existing media
    $media->alias_media('image', '<thumb>/path/to/existing.jpg');
    
    # List all media
    my $list = $media->list_media();

=head1 DESCRIPTION

Handles all media operations including storage, linking, aliasing, and metadata management.

=cut