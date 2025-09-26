#!/usr/bin/perl
use strict;
use warnings;
use LWP::UserAgent;
use HTTP::Request;
use JSON;

my $ua = LWP::UserAgent->new;
my $endpoint = 'http://127.0.0.1:8080/v1/completions';
my $auth = 'na';

my $prompt = <<'PROMPT';
<|im_start|>system
# Tools

You may call one or more functions to assist with the user query.

You are provided with function signatures within <tools></tools> XML tags:
<tools>
{"type":"function","function":{"name":"search","description":"Full-text search over project docs.","parameters":{"type":"object","properties":{"q":{"type":"string"},"top_k":{"type":"integer","minimum":1,"default":1}},"required":["q"]}}}
{"type":"function","function":{"name":"open_document","description":"Open a document by ID.","parameters":{"type":"object","properties":{"doc_id":{"type":"string"}},"required":["doc_id"]}}}
</tools>

For each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:
<tool_call>
{"name": <function-name>, "arguments": <args-json-object>}
</tool_call><|im_end|>
<|im_start|>user
Briefly, was Apollo considered a satellite? Just one sentence explanation. Then, find the latest Apollo status, then open last week's brief with doc id "53". If needed, call multiple tools in sequence.
<|im_end|>
<|im_start|>assistant
PROMPT

my $payload = {
  model       => "le-moo",
  prompt      => $prompt,
  max_tokens  => 4096,
  stream      => JSON::false,
};

my $req = HTTP::Request->new(POST => $endpoint);
$req->header('Content-Type' => 'application/json');
$req->header('Authorization' => "Bearer $auth");
$req->content(encode_json($payload));

my $res = $ua->request($req);
if ($res->is_success) {
  print $res->decoded_content, "\n";
} else {
  warn $res->status_line, "\n", $res->decoded_content, "\n";
}
