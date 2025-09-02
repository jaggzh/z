#!/usr/bin/perl
#!/usr/bin/env perl
use strict;
use warnings;
use feature 'say';
use Text::Xslate;

# In Text::Xslate Kolon syntax:
# - Control statements (if/for/else/end) start with a leading colon at line start.
# - Expressions you want to print go inside <: ... :>.

my $tpl = <<'XSLATE';
: if $ar.size {
:   for $ar -> $x {
* <: $x :>
:   }
: } else {
No ar values provided
: }
XSLATE

my $tx = Text::Xslate->new();

# Demo 1: non-empty array
say "--- non-empty ---";
my $out_nonempty = $tx->render_string($tpl, { ar => [qw(a b c)] });
say $out_nonempty;

# Demo 2: empty array
say "--- empty ---";
my $out_empty = $tx->render_string($tpl, { ar => [] });
say $out_empty;

# Bonus: a ternary variant that inlines the "No values" message,
# and only expands the loop if array has elements.
my $tpl_ternary = <<'XSLATE_T';
<: $ar.size ? '' : 'No ar values provided' :>
: if $ar.size {
:   for $ar -> $x {
* <: $x :>
:   }
: }
XSLATE_T

say "--- ternary variant (non-empty) ---";
say $tx->render_string($tpl_ternary, { ar => [qw(a b c)] });

say "--- ternary variant (empty) ---";
say $tx->render_string($tpl_ternary, { ar => [] });

