use Text::Xslate;

my @a = (
    { user => 'blah1',  assistant => 'blah1' },
    { user => 'blah2', assistant => 'blah2'    },
);

my %xslate_opts = (
    ua => \@a,
);

my $tx = Text::Xslate->new();

my $template = <<'EOT';
: for $ua -> $m {
user: <: $m.user :>
assistant: <: $m.assistant :>
---
: }
EOT

print $tx->render_string($template, \%xslate_opts);
