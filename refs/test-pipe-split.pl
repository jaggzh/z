#!/usr/bin/env perl
use v5.36;
use Test::More;

my $sec = "\033[44;37;1m";
my $rst = "\033[0m";
# I want to split a string with '|||' as the delimiter, while allowing escaped newlines.
# Escaping one or more of those pipes, eg: '\|||' or '|\||' suppresses that split.
#
# Ex:
#   field0|||field1
#   field0|||field1_line0\nfield1_line1
#      -> field0
#      -> field1_line0
#         field1_line1
#   field0\|||field0_continued
#      -> field0|||field0_continued
#   field0\|||field0_continued
#      -> field0|||field0_continued
#   field\0
#      -> field0
#   field\\0
#      -> field\0
#
# A final version `str_pipesplit()` should handle the newline and \\ escaping
# It should then 
# Bounded lookbehind avoids Perl's variable-LB limits; bump {,20} if you need longer runs.
my $DELIM_RE;
# $DELIM_RE = qr/(?<=^|[^\\](?:\\{2}){,20})\K\|\|\|/;
# $DELIM_RE = qr/(?<=^|[^\\](?:(?<=\\{2}){,20}))\|\|\|/;
# $DELIM_RE = qr/(?<!\\)(?<!(?:\\\\))*\|\|\|/;
$DELIM_RE = qr/(?<!\\)(?:\\\\){,20}\K\|\|\|/;

sub str_pipesplit_plain {
    my ($line) = @_;
    # 1) split at unescaped delimiters
    my @parts = split /$DELIM_RE/, $line, -1;
    return @parts;
}
sub str_pipesplit {
    my ($line) = @_;
    # 1) split at unescaped delimiters
    my @parts = split /$DELIM_RE/, $line, -1;
    # 2) unescape only pipes; leave other backslashes intact
    # say '';
    # say "Inputs: ", (join ', ', map { "{{$_}}" } @parts);
    s#((\\\\)*)\\\|# ($1//'') . '|' #ge for @parts;
    $_ = decode_singleline($_) for @parts;
    # say "Unescaped: ", (join ', ', map { "{{$_}}" } @parts);
    return @parts;
}
sub decode_singleline {
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


my @tests_splitonly = (
  [ 'abc|||def',          [ 'abc', 'def' ] ],
  [ 'abc|||def|||ghi',    [ qw(abc def ghi) ] ],
  [ 'abc\|||def',    [ 'abc\|||def' ] ],       # \ prevents split
  [ 'abc\\\\|||def',   [ 'abc\\\\', 'def' ] ],    # \ is part of [0] (\\ necessary in perl before closing ')
  [ 'x|\||y|||\|z',       [ 'x|\\||y', '\\|z' ] ],   # extra sanity: escaped pipe near delim
  [ 'x|\||y||||z',       [ 'x|\\||y', '|z' ] ],    # pipe near delim
  [ '|||lead||tail|||',   [ '', 'lead||tail', '' ] ], # leading/trailing empties
);

my $bs_in = '\\\\' x 10;
my @tests_split_and_unescape = (
  [ 'abc|||def',          [ 'abc', 'def' ] ],
  [ 'abc|||def|||ghi',    [ qw(abc def ghi) ] ],
  [ 'abc\|||def',    [ 'abc|||def' ] ],       # \ prevents split
  [ 'abc\\\\|||def',   [ 'abc\\\\', 'def' ] ],    # \ is part of [0] (\\ necessary in perl before closing ')
  [ 'x|\||y|||\|z',       [ 'x|||y', '|z' ] ],   # extra sanity: escaped pipe near delim
  [ 'x|\||y||||z',       [ 'x|||y', '|z' ] ],    # pipe near delim
  [ '|||lead||tail|||',   [ '', 'lead||tail', '' ] ], # leading/trailing empties
  [ $bs_in, [ $bs_in ] ], # 10 => 10 backslashes
  [ 'abc\ndef', [ "abc\ndef" ] ], # Newline handled
  [ 'abc\\\\\ndef', [ "abc\\\ndef" ] ], # Newline handled and bs retained
);

say "$sec===== 8 backslashes to 4 =====";
say decode_singleline('\\\\\\\\');
my @a = ('\\\\\\\\');
$_ = decode_singleline($_) for @a;
say join ' ', @a;

say "$sec===== Split only =====$rst";
for my $t (@tests_splitonly) {
    my ($in, $expect) = @$t;
    my @got = str_pipesplit_plain($in);
    is_deeply(\@got, $expect, $in);
}

say "$sec===== Split and unescape only =====$rst";
for my $t (@tests_split_and_unescape) {
    my ($in, $expect) = @$t;
    my @got = str_pipesplit($in);
    is_deeply(\@got, $expect, $in);
}

done_testing();

# vim: et ts=2 sw=2
