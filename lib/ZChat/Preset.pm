package ZChat::Preset;
use ZChat::Utils ':all';

use v5.34;
use warnings;
use utf8;

use File::Spec;
use File::Basename;
use FindBin;
use String::ShellQuote;
use Text::Xslate;
use POSIX qw(strftime);

sub new {
    my ($class, %opts) = @_;
    
    my $persona_bin = $opts{persona_bin};
    $persona_bin = 'persona' unless defined $persona_bin && $persona_bin ne '';
    
    se "Here: $persona_bin";
    my $self = {
        storage => ($opts{storage} || die "storage required"),
        data_dir => ($opts{data_dir} || File::Spec->catdir($FindBin::Bin, '..', 'data', 'sys')),
        persona_bin => $persona_bin,
        template_engine => undef,
    };
    se $self->{persona_bin} . " -- this is not defined";
    $DB::single=1;
    
    bless $self, $class;
    
    # Initialize template engine
    $self->{template_engine} = Text::Xslate->new(
        verbose => 0,
        type => 'text',
    );
    
    return $self;
}

sub resolve_preset {
    my ($self, $preset_name, %opts) = @_;
    
    return '' unless defined $preset_name && $preset_name ne '';
    
    sel(1, "Resolving preset '$preset_name'");
    
    # Try built-in config first
    my $config_content = $self->_try_config_preset($preset_name);
    if (defined $config_content) {
        sel(1, "Loaded preset '$preset_name' from config");
        return $config_content;
    }
    
    # Try data directory (file or directory)
    my $data_content = $self->_try_data_preset($preset_name);
    if (defined $data_content) {
        sel(1, "Loaded preset '$preset_name' from data directory");
        return $data_content;
    }
    
    # Try persona command
    se "We r here: $$self{persona_bin}";
    $DB::single=1;
    my $persona_content = $self->_try_persona_preset($preset_name, %opts);
    if (defined $persona_content) {
        sel(1, "Loaded preset '$preset_name' from persona command");
        return $persona_content;
    }
    
    # Fallback to default
    sel(1, "Preset '$preset_name' not found, trying 'default'");
    if ($preset_name ne 'default') {
        return $self->resolve_preset('default', %opts);
    }
    
    # Ultimate fallback
    sel(1, "Using ultimate fallback preset");
    return "You are a helpful AI assistant.";
}

sub _try_config_preset {
    my ($self, $preset_name) = @_;
    
    # This would load from zchat.json config if we had one
    # For now, return undef to fall through to other methods
    return undef;
}

sub _try_data_preset {
    my ($self, $preset_name) = @_;
    
    return undef unless $self->{data_dir} && -d $self->{data_dir};
    
    # Try directory-based preset first
    my $preset_dir = File::Spec->catdir($self->{data_dir}, $preset_name);
    if (-d $preset_dir) {
        return $self->_load_directory_preset($preset_dir);
    }
    
    # Try single file preset
    my $preset_file = File::Spec->catfile($self->{data_dir}, $preset_name);
    if (-e $preset_file && -r $preset_file) {
        return $self->_load_file_preset($preset_file);
    }
    
    return undef;
}

sub _try_persona_preset {
    my ($self, $preset_name, %opts) = @_;
    
    return undef if $opts{skip_persona};
    return undef unless $self->{persona_bin};
    
    my @cmd = ($self->{persona_bin}, '--path', 'find', $preset_name);
    my $cmd = shell_quote(@cmd);
    
    sel(1, "Loading Persona from disk with persona command");
    sel(1, "  Command: $cmd");
    
    my $output;
    eval {
        $output = `$cmd 2>/dev/null`;
        chomp $output if defined $output;
    };
    
    if ($? != 0) {
        sel(1, "persona command wasn't found or errored");
        return undef;
    }
    
    sel(2, "  persona provided:");
    sel(2, "{{$output}}");
    
    # Check if command succeeded and found files
    return undef if !defined $output || $output eq '';
    
    my @files = split /\n/, $output;
    return undef unless @files;
    
    if (@files > 1) {
        sel(1, "Multiple persona files found for '$preset_name':");
        sel(1, "  $_") for @files;
        sel(1, "Using first: $files[0]");
    }
    
    my $persona_file = $files[0];
    return undef unless -e $persona_file && -r $persona_file;
    
    sel(1, "Preset (persona file) found: $persona_file");
    my ($persona_name) = $persona_file =~ m|/([^/]+)$|;
    sel(1, "Preset persona name: $persona_name");
    
    my $content = $self->_load_file_preset($persona_file);
    sel(2, "Preset persona content length: " . length($content)) if defined $content;
    
    return $content;
}

sub _load_directory_preset {
    my ($self, $preset_dir) = @_;
    
    # Load main prompt file
    my $prompt_file = File::Spec->catfile($preset_dir, 'prompt');
    return undef unless -e $prompt_file && -r $prompt_file;
    
    my $content = $self->{storage}->read_file($prompt_file);
    return undef unless defined $content;
    
    # TODO: Load metadata from meta.yaml if needed
    # my $meta_file = File::Spec->catfile($preset_dir, 'meta.yaml');
    # my $metadata = $self->{storage}->load_yaml($meta_file) if -e $meta_file;
    
    return $self->_process_preset_content($content);
}

sub _load_file_preset {
    my ($self, $preset_file) = @_;
    
    my $content = $self->{storage}->read_file($preset_file);
    return undef unless defined $content;
    
    return $self->_process_preset_content($content);
}

sub _process_preset_content {
    my ($self, $content) = @_;
    
    # Remove === z metadata sections (for single-file compatibility)
    $content =~ s/\s*^===+\s*z\s+.*$//gm;
    
    # Trim whitespace
    $content =~ s/^\s+|\s+$//g;
    
    # Process templates
    $content = $self->_render_template($content);
    
    return $content;
}

sub _render_template {
    my ($self, $template) = @_;
    
    return '' unless defined $template && $template ne '';
    
    my %template_vars = (
        datenow => $self->_make_datenow(),
        modelname => 'unknown', # Will be filled by caller if needed
    );
    
    my $result = $template;
    eval {
        $result = $self->{template_engine}->render_string($template, \%template_vars);
    };
    
    if ($@) {
        warn "Template rendering failed: $@";
        return $template;  # Return unprocessed on error
    }
    
    return $result;
}

sub _make_datenow {
    my ($self, %opts) = @_;
    
    if ($opts{yyyymmdd}) {
        return strftime('%Y-%m-%d', localtime);
    } else {
        return strftime('%a %Y-%m-%d %H:%M:%S%z', localtime);
    }
}

# List available presets
sub list_presets {
    my ($self) = @_;
    
    my @presets;
    
    # Get from data directory
    if (-d $self->{data_dir}) {
        opendir(my $dh, $self->{data_dir}) or return [];
        
        while (my $entry = readdir($dh)) {
            next if $entry =~ /^\./;  # Skip hidden files
            
            my $path = File::Spec->catfile($self->{data_dir}, $entry);
            
            # Add files and directories
            if (-f $path || -d $path) {
                push @presets, $entry;
            }
        }
        
        closedir($dh);
    }
    
    # Get from persona command (if available)
    my @persona_presets = $self->_list_persona_presets();
    push @presets, @persona_presets;
    
    # Remove duplicates and sort
    my %seen;
    @presets = grep { !$seen{$_}++ } @presets;
    @presets = sort @presets;
    
    return \@presets;
}

sub _list_persona_presets {
    my ($self) = @_;
    
    my @cmd = ($self->{persona_bin}, 'list');
    
    my $output;
    eval {
        $output = `@cmd 2>/dev/null`;
    };
    
    return () if $? != 0 || !defined $output;
    
    my @names;
    for my $line (split /\n/, $output) {
        chomp $line;
        next if $line =~ /^\s*$/;
        
        # Extract just the name (assuming format like "name: /path/to/file")
        if ($line =~ /^([^:]+):/) {
            push @names, $1;
        } else {
            push @names, $line;
        }
    }
    
    return @names;
}

# Validate preset exists
sub preset_exists {
    my ($self, $preset_name) = @_;
    
    return 0 unless defined $preset_name && $preset_name ne '';
    
    # Check data directory
    my $preset_dir = File::Spec->catdir($self->{data_dir}, $preset_name);
    my $preset_file = File::Spec->catfile($self->{data_dir}, $preset_name);
    
    return 1 if -d $preset_dir || -f $preset_file;
    
    # Check persona command
    my @cmd = ($self->{persona_bin}, '--path', 'find', $preset_name);
    my $output = `@cmd 2>/dev/null`;
    
    return ($? == 0 && defined $output && $output ne '');
}

# Get preset metadata (for directory-based presets)
sub get_preset_metadata {
    my ($self, $preset_name) = @_;
    
    return {} unless defined $preset_name;
    return {} unless $self->{data_dir} && -d $self->{data_dir};
    
    my $preset_dir = File::Spec->catdir($self->{data_dir}, $preset_name);
    return {} unless -d $preset_dir;
    
    my $meta_file = File::Spec->catfile($preset_dir, 'meta.yaml');
    return {} unless -e $meta_file;
    
    return $self->{storage}->load_yaml($meta_file) || {};
}

# Create a new preset (simple file-based)
sub create_preset {
    my ($self, $preset_name, $content, %opts) = @_;
    
    return 0 unless defined $preset_name && $preset_name ne '';
    return 0 unless defined $content && $content ne '';
    
    # Validate preset name
    if ($preset_name =~ m{[/\\]}) {
        warn "Invalid preset name '$preset_name' (contains path separators)";
        return 0;
    }
    
    my $preset_file = File::Spec->catfile($self->{data_dir}, $preset_name);
    
    # Check if already exists
    if (-e $preset_file && !$opts{overwrite}) {
        warn "Preset '$preset_name' already exists (use overwrite => 1 to replace)";
        return 0;
    }
    
    return $self->{storage}->write_file($preset_file, $content);
}

1;

__END__

=head1 NAME

ZChat::Preset - System prompt/persona handling for ZChat

=head1 SYNOPSIS

    use ZChat::Preset;
    
    my $preset_mgr = ZChat::Preset->new(
        storage => $storage,
        data_dir => '/path/to/presets'
    );
    
    # Resolve preset content
    my $content = $preset_mgr->resolve_preset('helpful-assistant');
    
    # List available presets
    my $presets = $preset_mgr->list_presets();
    
    # Check if preset exists
    if ($preset_mgr->preset_exists('coding-assistant')) {
        # Use it
    }
    
    # Create new preset
    $preset_mgr->create_preset('my-preset', $prompt_text);

=head1 DESCRIPTION

Handles system prompt/persona resolution from multiple sources:
data directory files, directory-based presets, and external persona command.
Supports template processing with date/model variables.

=cut
