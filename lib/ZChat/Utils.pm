package ZChat::Utils;
use v5.26.3;
use feature 'say';
use experimental 'signatures';
use strict;
use warnings;

use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use Errno qw(EEXIST);

use Exporter 'import';
use File::Slurper qw(write_text read_text read_binary);
use Encode qw(decode encode_utf8);
use File::Path qw(make_path);
use JSON::XS;
use ZChat::ansi; # ANSI color vars: $red, $gre (green), $gra (gray); prefix b* for bright (e.g. $bgre), bg* for backgrounds (e.g. $bgred), and $rst to reset; 24-bit via a24fg(r,g,b)/a24bg(r,g,b)
use Data::Dumper;
use utf8;
use Carp; $Carp::Verbose=1;
use Term::Size 'chars';

our @EXPORT_OK = qw(
	set_verbose get_verbose
	se sel pe pel
	cnfs
	printcon saycon
	saycon printcon
	pps
	dumps
	read_json_file
	write_json_file
	json_pretty_from_str_min
	json_pretty_from_data_min
	read_file
	write_file
	split_pipestr
	encode_pipestr_part
	_decode_pipestring_part
	sok swarn serr sultraerr
	sokl swarnl serrl sultraerrl
	pager pagerdone
	show_help_file
	$a_stat_actline $a_stat_actval $a_stat_acttag $a_stat_inactline
	$a_stat_exists
	$a_stat_undeftag
	file_create_secure
	json_pretty_from_str_min
	json_pretty_from_data_min
);
our %EXPORT_TAGS = (
    all => \@EXPORT_OK,
    glyphs => [qw(sok swarn serr sultraerr)],
);

our $json_compact = JSON::XS->new->utf8->canonical; # For our custom json formatting
our $verbose = $ENV{ZCHAT_VERBOSE} // 0;  # 0=quiet, 1,2,3...
our $uc_ok = "✔";  # Unicode "Good/OK/Checkmark"
our $uc_warn = "⚠";  # Unicode "Warning"
our $uc_err = "⚠️";  # Unicode "Error/Times"
our $uc_fail = "❌";  # CROSS MARK
our $uc_uerr = "⛔";  # Unicode "Ultra Error / No Entry"

my $PIPE_DELIM_RE = qr/(?<!\\)(?:\\\\){,20}\K\|\|\|/;

# Styles (24-bit color + attributes). Avoid 8-bit $b* colors; $rst remains OK.
# Example given: strong red, bold+italic for errors.
my $a_err      = a24fg(255,158,158) . $aa_boit;
my $a_warn     = a24fg(255,210,64)  . $aa_bo;            # vivid yellow, bold
my $a_ok       = a24fg(144,238,144) . $aa_bo;            # light green, bold
my $a_ultraerr = a24bg(100,0,0)     . a24fg(255,255,255) . $aa_boit; # white on toned-down strong red

our $a_stat_actline   = a24bg(0,50,100) . a24fg(255,255,255);   # blue bg, white text  
our $a_stat_actval    = a24fg(255,100,255) . $aa_bo;     # b magenta, bold
our $a_stat_acttag    = a24fg(100,255,100) . $aa_bo;     # b green, bold
our $a_stat_inactline = "";                              # normal text
our $a_stat_exists    = a24fg(0,178,0);                   # bright green, bold
our $a_stat_undeftag  = a24fg(100,100,100);              # gray


sub set_verbose($l) { $verbose = $l // 0 }
sub get_verbose { $verbose }
sub sel($lvl, @msg) { say STDERR @msg if $verbose >= $lvl }
sub se(@msg) { say STDERR @msg; }
sub pel($lvl, @msg) { print STDERR @msg if $verbose >= $lvl }
sub pe(@msg) { print STDERR @msg }

sub cnfs($str) { croak "$a_err$uc_err$str$rst" }

sub sok(@msg)      { se "$uc_ok $a_ok",       @msg, $rst; }
sub swarn(@msg)    { se "$uc_warn $a_warn",   @msg, $rst; }
sub serr(@msg)     { se "$uc_err $a_err",     @msg, $rst; }
sub sultraerr(@msg){ se "$uc_uerr $a_ultraerr", @msg, $rst; }

sub sokl($lvl, @msg)      { sok(@msg)      if $verbose >= $lvl }
sub swarnl($lvl, @msg)    { swarn(@msg)    if $verbose >= $lvl }
sub sultraerrl($lvl, @msg){ sultraerr(@msg)if $verbose >= $lvl }
sub serrl($lvl, @msg)     { serr(@msg)     if $verbose >= $lvl }


sub printcon(@msg) { # Force print to console
    if (open my $tty, '>>', '/dev/tty') {
        print $tty @msg;
        close $tty;
    }
}
sub saycon(@msg) { printcon(@msg, "\n"); }

sub pps($var) { print(dumps($var)) }

sub dumps($var) {
	local $Data::Dumper::Indent = 1;  # compact, less indentation
	local $Data::Dumper::Terse  = 1;  # no $VAR1 =
	local $Data::Dumper::Useqq  = 0;  # escaped strings
	return Dumper($var);
}

# Secure file creation to prevent TOCTTOU race attacks
# This prevents an attacker from creating the file between our check and creation
sub file_create_secure($path, $mode=0660) {
    # ATOMIC: Create file exclusively or fail - no race window
    my $fh;
    if (sysopen($fh, $path, O_WRONLY | O_CREAT | O_EXCL, $mode)) {
        close($fh);
        return 1; # We created it [with our mode] - safe to write sensitive data
    }

    # File existed upon creation - could be legitimate or an attack
    if ($! == EEXIST) {
        # Now we need to verify ownership before proceeding
        my @stat = stat($path); # Even if removed and re-created, if it's owned by us it's ok
        if (!@stat) {
            serr "Couldn't stat existing file: $path: $!";
            exit 1;
        }
        
        if ($stat[4] != $<) {
            serr "SECURITY: File ($path) owned by UID $stat[4], not us ($<). Possible attack?";
            exit 1;
        }
        
        # File exists and is owned by us - verify we can write
        if (!open(my $fh, ">>", $path)) {
            serr "Couldn't access our existing file: $path: $!";
            exit 1;
        }
        close($fh);
        return 0; # File already existed (and is safe)
    }
    
    # Any other error is fatal
    serr "Couldn't create file: $path: $!";
    exit 1;
}

sub json_pretty_from_str_min($str) {
    my $data;
    eval {
		$data = decode_json($str);
	};
	if ($@) {
		sel 0, "Failed to decode JSON string'";
		return undef;
	}
    return json_pretty_from_data_min($data);
}

sub json_pretty_from_data_min($data) {
    my $json = $json_compact->encode($data);
    my $indent = 0;
    my @result;
    my $in_string = 0;
    for my $char (split //, $json) {
        if ($char eq '"' && (@result && $result[-1] !~ /\\$/)) {
            $in_string = !$in_string;
        }
        if (!$in_string) {
            if ($char eq '{' || $char eq '[') {
                push @result, $char, "\n", "  " x ++$indent;
            } elsif ($char eq '}' || $char eq ']') {
                push @result, "\n", "  " x --$indent, $char;
            } elsif ($char eq ',') {
                push @result, $char, "\n", "  " x $indent;
            } else {
                push @result, $char;
            }
        } else {
            push @result, $char;
        }
    }
    return join '', @result;
}

# # This version is non-tolerant of utf8 encoding errors
# sub read_json_file($file) {
#     return {} unless -f $file;
#     open my $fh, '<', $file or die "Can't read $file: $!";
#     my $content = do { local $/; <$fh> };
#     close $fh;
#     return {} unless $content;
#     return decode_json($content);
# }

sub read_json_file {
    my ($filepath) = @_;

    return [] unless -e $filepath;

    my $result = [];
    eval {
        my $raw_content = read_binary($filepath);
        my $decoded = decode('UTF-8', $raw_content, Encode::FB_QUIET);

        # Handle trailing commas (lenient parsing)
        $decoded =~ s/,\s*(\]|\})/$1/g;

        if ($decoded =~ /^\s*$/) {
            $result = [];
        } else {
            my $json = JSON::XS->new->relaxed(1);
            my $parsed = $json->decode($decoded);
            $result = ref($parsed) eq 'ARRAY' ? $parsed : [];
        }
    };

    if ($@) {
        warn "Failed to load JSON file '$filepath': $@";
        return [];
    }

    return $result;
}

sub write_json_file($filepath, $data, $optshro=undef) {
    $optshro ||= {};
	# Important: Defaults to makepath=>1
	# (filepath, data, {options})
	# options
	#    min=> (indented, but minimalish; normal is fully one-lined,
	#       so min can only be this)
	#    prettymin (same as min)
	#    umask set your own umask. default is probably 0177;
	#       set umask=>undef to use current user default umask
	#    makepath=>0 to disable make_path()
    my $umask = exists($optshro->{umask}) ? $optshro->{umask} : 0177;
    my $pretty = $optshro->{pretty} // 0;
    my $prettymin = $optshro->{prettymin} // $optshro->{min} // 0; # Reduce indent
    my $makepath = $optshro->{makepath} // 0;

    # Ensure directory exists
    my $dir = (File::Spec->splitpath($filepath))[1];
    make_path($dir) if $makepath && $dir && !-d $dir;

    my $old_umask;
    $old_umask = umask($umask) if defined $umask; # Set only if set

    eval {
        my $json = JSON::XS->new->pretty(1)->space_after;
        my $json_text = $json->encode($data);
        write_text($filepath, $json_text);
    };

    umask($old_umask) if defined $umask; # Revert only if set

    if ($@) {
        warn "Failed to save JSON file '$filepath': $@";
        return 0;
    }

    return 1;
}

# Plain text operations
sub read_file {
    my ($filepath) = @_;
    return undef unless -e $filepath && -r $filepath;
    my $content;
    eval {
        $content = read_text($filepath);
    };
    if ($@) {
        warn "Failed to read file '$filepath': $@";
        return undef;
    }
    $content;
}

sub write_file($filepath, $content, $optshro=undef) {
    $optshro ||= {};
	# Important: Defaults to makepath=>1
	# options:
	#    umask set your own umask. default is probably 0177;
	#       set umask=>undef to use current user default umask
	#    makepath=>0 to disable make_path()
    my $umask = exists($optshro->{umask}) ? $optshro->{umask} : 0177;
    my $makepath = $optshro->{makepath} // 1;

    # Ensure directory exists
    my $dir = (File::Spec->splitpath($filepath))[1];
    make_path($dir) if $makepath && $dir && !-d $dir;

    my $old_umask;
    $old_umask = umask($umask) if defined $umask; # Set only if set

    eval {
        write_text($filepath, $content);
    };

    umask($old_umask) if defined $umask; # Revert only if set

    if ($@) {
        warn "Error writing file: '$filepath': $@";
        return 0;
    }

    return 1;
}

sub split_pipestr {
    my ($line) = @_;
    # 1) split at unescaped delimiters
    my @parts = split /$PIPE_DELIM_RE/, $line, -1;
    # 2) unescape only pipes; leave other backslashes intact
    # say '';
    # say "Inputs: ", (join ', ', map { "{{$_}}" } @parts);
    s#((\\\\)*)\\\|# ($1//'') . '|' #ge for @parts;
    $_ = decode_singleline($_) for @parts;
    # say "Unescaped: ", (join ', ', map { "{{$_}}" } @parts);
    return @parts;
}
sub _decode_pipestring_part {
    my ($s, $strict) = @_;
    my ($out, $k) = ('', 0);                       # k = run length of preceding backslashes
    for my $ch (split //, $s) {
        if ($ch eq "\\") { ++$k; next; }
        if ($ch eq "n" && ($k % 2)) {              # odd => last \ escapes n -> newline
            $out .= "\\" x int($k/2);
            $out .= "\n";
        } else {
            $out .= "\\" x $k;
            $out .= $ch;
        }
        $k = 0;
    }
    if ($strict && ($k % 2)) { die "dangling backslash at EOL" }  # policy choice
    $out .= "\\" x $k;                             # non-strict: keep trailing \ literally
    return $out;
}

# Encode one field so it’s safe to join with '|||' and later decode:
# 1) \\  -> \\\\   (make all literal '\' even so they never escape next char)
# 2) |   -> \|     (no '|||' can appear)
# 3) NL  -> \n     (visible line breaks)

sub encode_pipestr_part {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;   # backslashes first
    $s =~ s/\|/\\|/g;    # then pipes
    $s =~ s/\n/\\n/g;    # then newlines
    return $s;
}

sub pager { # $p = pager(); print $p "stuff"; pagerend();
    my $pager;
    open($pager, '|-', ($ENV{PAGER} // 'less -RF')) && return $pager;
    \*STDOUT;
}
sub pagerdone($p) {
    close $p;
}

sub show_file_md($path) {
	my ($cols, $rows) = chars;
	$cols //= 79;

    my @commands = (
        # "glow \Q$path\E --tui", # --tui doesn't honor -w width
        "glow \Q$path\E -p -w $cols", # 
        "mdcat \Q$path\E -p", # Low priority; doesn't handle tables
        "highlight -O truecolor -s base16/monokai \Q$path\E | less -FR", 
        "bat \Q$path\E --paging=always --language=markdown --style=plain", # no tables
		# Untested:
		"rich \Q$path\E --markdown --pager", # Python rich library
		"mdv \Q$path\E", # Terminal markdown viewer (has built-in pager)
		"pandoc \Q$path\E -t plain | less -FR", # Convert to plain text
		"markdown \Q$path\E | w3m -T text/html", # Convert to HTML, view in w3m
    );
    for my $cmd (@commands) {
        my ($prog) = $cmd =~ /^(\w+)/;
        next unless system("which $prog >/dev/null 2>&1") == 0;
        return 1 if system($cmd) == 0;
    }
    
    warn "No markdown viewers found, showing as plain text\n";
    my $pager = pager();
    print $pager read_text($path);
    pagerdone($pager);
    return 1;
}

sub show_help_file($f) {
    my $path = File::Spec->catfile($FindBin::RealBin, 'help', $f);
    if (! -e $path) { swarn "No help file found at $path"; return 0; }
    if ($path =~ /\.md$/) {
    	show_file_md($path);
	} else {
		my $pager = pager();
		print $pager read_text($path);
		pagerdone($pager);
	}
}

1;
