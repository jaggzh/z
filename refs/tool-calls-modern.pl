#!/usr/bin/perl
use strict;
use warnings;
use LWP::UserAgent;
use HTTP::Request;
use JSON;

my $ua = LWP::UserAgent->new;

my $endpoint = 'http://127.0.0.1:8080/v1/chat/completions';
my $auth_token = 'na';

my $payload = {
    model => "le-moo",
    messages => [
        { role => "system", content => "You are a helpful assistant." },
        { role => "user", content => "Explain if Apollo was ever considered a satellite (one-sentence). Then find the latest Apollo status and open last week's brief for doc id 53." }
    ],
    max_tokens  => 4000,
    stream      => JSON::false,
    tools => [
        {
            type => "function",
            function => {
                name => "search",
                description => "Full-text search over project docs.",
                parameters => {
                    type => "object",
                    properties => {
                        q => { type => "string" },
                        top_k => { type => "integer", minimum => 1, default => 5 }
                    },
                    required => ["q"]
                }
            }
        },
        {
            type => "function",
            function => {
                name => "open_document",
                description => "Open a document by ID.",
                parameters => {
                    type => "object",
                    properties => {
                        doc_id => { type => "string" }
                    },
                    required => ["doc_id"]
                }
            }
        }
    ],
    tool_choice => "auto"
};

my $json_payload = encode_json($payload);

my $req = HTTP::Request->new(POST => $endpoint);
$req->header('Content-Type' => 'application/json');
$req->header('Authorization' => "Bearer $auth_token");
$req->content($json_payload);

my $res = $ua->request($req);

if ($res->is_success) {
    print $res->decoded_content, "\n";
} else {
    print STDERR "Error: ", $res->status_line, "\n";
    print $res->decoded_content, "\n";
}
