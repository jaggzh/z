package ZChat::Core;
use v5.26.3;
use feature 'say';
use experimental 'signatures';
use strict;
use warnings;

use utf8;
use Mojo::UserAgent;
use JSON::XS;
use LWP::UserAgent;
use HTTP::Request;
use Encode qw(decode encode_utf8);

use ZChat::Utils ':all';

sub new {
    my ($class, %opts) = @_;

    my $self = {
        api_base => _resolve_api_base($opts{api_base}),
        api_key  => _first_defined($opts{api_key}, _resolve_api_key()),
        fallback_api_key => $opts{fallback_api_key} // 'na',
        backend  => _resolve_backend($opts{backend}),
        model_info => undef,
        model_info_loaded => 0,
        host_url => '', # Derived from api_base without URI
    };
    my ($tmp_url) = ($self->{api_base} =~ m#^(.+?//.+?)(?:/|$)#);
    if (!defined $tmp_url) {
    	swarn 0, <<~"EOT";
			Couldn't derive plain base URL (with URI stripped) from
			  api_base: $$self{api_base}.
			Potential misconfiguration in provided API URL.
			If your api base functions, somehow, okay, but we won't be able to build
			tokenization and n_ctx requests.
			EOT
	} else {
		$self->{host_url} = $tmp_url // undef;
	}

    bless $self, $class;
    return $self;
}

# Build standard headers for API requests
sub _build_headers {
    my ($self, %extra_headers) = @_;
    
    my %headers = (
        'Content-Type' => 'application/json',
        %extra_headers
    );
    
    # Use provided API key, or fallback if none provided
    my $api_key = $self->{api_key} || $self->{fallback_api_key};
    if ($api_key) {
        $headers{'Authorization'} = "Bearer $api_key";
    }
    
    return \%headers;
}
sub complete_request($self, $messages, $optshro=undef) {
    $optshro ||= {};

    sel(2, "Making completion request with " . @$messages . " messages");

    # Debug: show message summary
    if (get_verbose() >= 3) {
    	sel 3, "=== Message history: ===";
        for my $i (0..$#$messages) {
            my $msg = $messages->[$i];
            my $content_len = length($msg->{content});
            sel(3, "Message $i: role=$$msg{role}, length=$content_len");
            sel(4, "Message $i content: $$msg{content}");
        }
    }

    # Default options
    my $temperature = $optshro->{temperature} || 0.7;
    my $top_k = $optshro->{top_k} || 40;
    my $top_p = $optshro->{top_p} || 0.9;
    my $min_p = $optshro->{min_p} || 0.08;
    my $n_predict = $optshro->{n_predict} || 8192;
    my $stream = $optshro->{stream} // 1;

    # Get model info
    my $model_info = $self->get_model_info();
    my $model_name = $self->_extract_model_name($model_info);

    sel(2, "Using model: $model_name");

    # Build API request
    my $data = {
        messages => $messages,
        temperature => $temperature,
        top_k => int($top_k),
        top_p => $top_p,
        min_p => $min_p,
        n_predict => int($n_predict),
        cache_prompt => JSON::XS::true,
        model => $model_name,
        stream => $stream ? JSON::XS::true : JSON::XS::false,
    };

    # Add grammar if specified
    $data->{grammar} = $optshro->{grammar} if $optshro->{grammar};
    $data->{n_probs} = int($optshro->{n_probs}) if $optshro->{n_probs};

    sel(3, "API request data: " . dumps($data));

    if ($stream) {
        return $self->_stream_completion($data, $model_name, $optshro);
    } else {
        return $self->_sync_completion($data, $model_name, $optshro);
    }
}

sub _stream_completion($self, $data, $model_name, $optshro=undef) {
    $optshro ||= {};
    my $on_chunk = $optshro->{on_chunk};

    my $ua = Mojo::UserAgent->new(max_response_size => 0);
    my $headers = $self->_build_headers();

    my $tx = $ua->build_tx(
        POST => "$$self{api_base}/chat/completions",
        $headers,
        json => $data
    );

    my $answer = '';
    my $token_count = 0;
    my $buffer = '';
    my $usage_info = {};
    my @collected_tool_calls;

    $tx->res->content->unsubscribe('read')->on(read => sub {
        my ($content, $bytes) = @_;
        $buffer .= $bytes;

        # Process complete lines
        while ($buffer =~ s/^(.*?\n)//) {
            my $line = $1;
            chomp $line;
            sel 4, "[LLM OUTPUT] $line";

            next if $line =~ /^\s*$/;

            # Handle SSE format: "data: {json}"
            if ($line =~ /^data:\s*(.+)$/) {
                my $json_str = $1;

                # Handle end marker
                last if $json_str eq '[DONE]';

                # Parse JSON chunk
                my $decoded;
                eval { $decoded = decode_json($json_str); };
                next if $@;

                # Extract usage info if present (usually in final chunk)
                if ($decoded->{usage}) {
                    $usage_info = $decoded->{usage};
                }

                # Collect tool calls for appending
                my $choice = $decoded->{choices}[0];
                if ($optshro->{append_tool_calls} && $choice->{delta} && $choice->{delta}{tool_calls}) {
                    push @collected_tool_calls, @{$choice->{delta}{tool_calls}};
                }

                # Check for completion
                last if $choice->{finish_reason};

                # Extract content from delta
                if (defined $choice->{delta} && defined $choice->{delta}{content}) {
                    my $chunk = $choice->{delta}{content};

                    # Clean up first token
                    $chunk =~ s/^\s+// unless $token_count;

                    # Send chunk to callback if provided
                    if ($on_chunk && $chunk ne '') {
                        $on_chunk->($chunk);
                    }

                    $answer .= $chunk;
                    $token_count++;
                }
            }
        }
    });

    # Execute request
    $ua->start($tx);

    # Append collected tool calls if requested
    if ($optshro->{append_tool_calls} && @collected_tool_calls) {
        my $tool_calls_text = '';
        for my $tool_call (@collected_tool_calls) {
            if ($tool_call->{function}) {
                my $tool_json = encode_json({
                    id => $tool_call->{id},
                    name => $tool_call->{function}{name},
                    arguments => $tool_call->{function}{arguments}
                });
                $tool_calls_text .= "\nTOOL_CALL: $tool_json";
            }
        }
        
        if ($tool_calls_text) {
            $answer .= $tool_calls_text;
            if ($on_chunk) {
                $on_chunk->($tool_calls_text);
            }
        }
    }

    # Return both content and metadata
    return {
        content => $answer,
        metadata => {
            model => $model_name,
            tokens_input => $usage_info->{prompt_tokens} || 0,
            tokens_output => $usage_info->{completion_tokens} || 0,
            tokens_total => $usage_info->{total_tokens} || 0,
            finish_reason => 'stop', # Default for streaming
            request_time => time,
        }
    };
}

sub _sync_completion($self, $data, $model_name, $optshro=undef) {
    $optshro ||= {};

    my $start_time = time;
    my $ua = Mojo::UserAgent->new();
    my $headers = $self->_build_headers();

    my $tx = $ua->post(
        "$$self{api_base}/chat/completions",
        $headers,
        json => $data
    );

    unless ($tx->res->is_success) {
        die "API request failed: " . $tx->res->message;
    }

    my $response = $tx->res->json;
    my $content = $response->{choices}[0]{message}{content} || '';
    my $usage = $response->{usage} || {};
    my $choice = $response->{choices}[0] || {};

    # Handle tool calls appending if requested
    if ($optshro->{append_tool_calls}) {
        my $tool_calls = $response->{choices}[0]{message}{tool_calls};
        if ($tool_calls && @$tool_calls) {
            for my $tool_call (@$tool_calls) {
                my $tool_json = encode_json({
                    id => $tool_call->{id},
                    name => $tool_call->{function}{name},
                    arguments => $tool_call->{function}{arguments}
                });
                $content .= "\nTOOL_CALL: $tool_json";
            }
        }
    }

    # Post-process if needed
    my $remove_pattern = $optshro->{remove_pattern};
    my $show_thought = $optshro->{show_thought} || 0;

    if ($remove_pattern && !$show_thought) {
        $content =~ s/$remove_pattern//s;
    }

    # Return both content and metadata
    return {
        content => $content,
        metadata => {
            model => $model_name,
            tokens_input => $usage->{prompt_tokens} || 0,
            tokens_output => $usage->{completion_tokens} || 0,
            tokens_total => $usage->{total_tokens} || 0,
            finish_reason => $choice->{finish_reason} || 'stop',
            request_time => $start_time,
            response_time => time - $start_time,
        }
    };
}

sub get_model_info {
    my ($self) = @_;
	# Undefined backend will try llama.cpp then ollama
	# "" disables the hits entirely

    return $self->{model_info} if $self->{model_info_loaded};

	# Backend was disabled by caller (ie. set to '')
	return undef if exists $self->{backend} && defined $self->{backend} && $self->{backend} eq '';

    my $backend = $self->{backend};
    my $url;

	# If it's undefined we try each...
    if (!defined $backend || $backend eq 'llama.cpp') {
        $url = "$$self{host_url}/props";
    } elsif (!defined $backend || $backend eq 'ollama') {
        $url = "$$self{host_url}/api/show";
    } else {
    	$backend //= "Undefined"; 
        swarnl(0, "Unknown backend '$backend'. Use 'llama.cpp', 'ollama', or leave unset.");
        return undef;
    }

	sel 1, "get_model_info() hitting $url";
    my $ua = LWP::UserAgent->new(timeout => 5);
    
    # Build request with proper headers
    my $req = HTTP::Request->new('GET', $url);
    my $headers = $self->_build_headers();
    for my $header_name (keys %$headers) {
        $req->header($header_name => $headers->{$header_name});
    }
    
    my $response = $ua->request($req);
    unless ($response->is_success) {
        sel(2, "Model info fetch failed from $url: " . $response->status_line);
        $self->{model_info_loaded} = 1;
        $self->{model_info} = undef;
        return undef;
    }

    my $data = decode_json($response->decoded_content);
    $self->{model_info} = $data;
    $self->{model_info_loaded} = 1;

    return $data;
}

sub _extract_model_name {
    my ($self, $props) = @_;

    my $model_path = $props->{model_path} || '';
    $model_path =~ s#^.*/##;        # Remove path
    $model_path =~ s#\.[^.]+$##;    # Remove extension

    return $model_path || 'unknown';
}

sub get_n_ctx {
    my ($self) = @_;

    my $def_n_ctx = 1024;
    my $props = $self->get_model_info();
    return $def_n_ctx unless $props;

    if (($self->{backend}//'') eq 'ollama') { # '' to prevent error
        return $props->{model_info}{num_ctx} // $def_n_ctx;
    }

    return $props->{default_generation_settings}{n_ctx} // $def_n_ctx;
}

sub tokenize {
    my ($self, $text, $opts) = @_;
    $opts ||= {};

    my $with_pieces = $opts->{with_pieces} || 0;

    my $ua = LWP::UserAgent->new(timeout => 5);
    my $url = "$$self{host_url}/tokenize";

    my $request_data = { content => $text };
    $request_data->{with_pieces} = JSON::XS::true if $with_pieces;

    my $json = encode_json($request_data);
    my $req = HTTP::Request->new('POST', $url);
    
    # Use consistent header building
    my $headers = $self->_build_headers();
    for my $header_name (keys %$headers) {
        $req->header($header_name => $headers->{$header_name});
    }
    
    $req->content($json);

    my $res = $ua->request($req);
    unless ($res->is_success) {
        warn "Tokenization request failed: " . $res->status_line . "\n" .
			" URL: $url";
        return wantarray ? () : 0;
    }

    my $response_data = decode_json($res->decoded_content);
    my @tokens = @{$response_data->{tokens} || []};

    return wantarray ? @tokens : scalar @tokens;
}

sub count_tokens {
    my ($self, $text) = @_;

    return $self->tokenize($text);
}

# Estimate tokens for message array (for context management)
sub estimate_message_tokens {
    my ($self, $messages) = @_;

    my $total = 0;

    for my $msg (@$messages) {
        # Rough estimation: 3 chars per token, plus overhead per message
        $total += int(length($msg->{content}) / 3) + 4; # 4 token overhead per message
    }

    return $total;
}

sub get_model_name {
    my ($self) = @_;

    my $props = $self->get_model_info();
    return '' unless $props;

    return $self->_extract_model_name($props);
}

# Test connection
sub ping {
    my ($self) = @_;

    my $res = 0;
    eval {
        $self->get_model_info();
        $res = 1;
    };

    return $res;
}

# Get server health
sub health_check {
    my ($self) = @_;

    my $ua = LWP::UserAgent->new(timeout => 2);
    
    # Build request with headers for consistency
    my $req = HTTP::Request->new('GET', "$$self{api_base}/health");
    my $headers = $self->_build_headers();
    for my $header_name (keys %$headers) {
        $req->header($header_name => $headers->{$header_name});
    }
    
    my $response = $ua->request($req);

    return {
        status => $response->is_success,
        code => $response->code,
        message => $response->message,
    };
}

# Connection URL helpers
sub _first_defined {
    my @vals = @_;
    for my $v (@vals) {
        return $v if defined($v) && $v ne '';
    }
    return undef;
}

sub _normalize_base_with_v1 {
    my ($u) = @_;
    $u ||= 'http://127.0.0.1:8080';
    $u =~ s{\s+}{}g;
    $u = "http://$u" unless $u =~ m{^https?://}i;
    $u =~ s{/$}{};
    $u =~ s{/v1$}{};
    return "$u/v1";
}

sub _resolve_backend {
    my ($opt_val) = @_;
    my $backend = _first_defined(
    	$opt_val,
    	$ENV{ZCHAT_BACKEND},
    	defined _get_llama_envval() ? 'llama.cpp' : undef,
    );
    return $backend;
}

sub _get_llama_envval {
    return _first_defined(
        $ENV{LLAMA_URL},
        $ENV{LLAMA_API_URL},
        $ENV{LLAMACPP_SERVER},
        $ENV{LLAMA_CPP_SERVER},
        $ENV{LLM_API_URL},
	);
}

sub _get_openai_envval {
    return _first_defined(
        $ENV{OPENAI_BASE_URL},
        $ENV{OPENAI_API_BASE},
        $ENV{OPENAI_URL},
	);
}

sub _resolve_api_base {
    my ($opt_val) = @_;
    my $env_val = _first_defined(
    	_get_llama_envval(),
    	_get_openai_envval(),
    );
    return _normalize_base_with_v1(_first_defined($opt_val, $env_val));
}

sub _resolve_api_key {
    return _first_defined(
        $ENV{OPENAI_API_KEY},
        $ENV{LLAMA_API_KEY},
        $ENV{AZURE_OPENAI_API_KEY},
    );
}

1;

__END__

=head1 NAME

ZChat::Core - LLM API communication for ZChat

=head1 SYNOPSIS

    use ZChat::Core;

    my $core = ZChat::Core->new(
        api_base => 'http://localhost:8080'
    );

    # Complete with messages
    my $response = $core->complete_request($messages,
        temperature => 0.7,
        stream => 1
    );

    # Get model information
    my $model_info = $core->get_model_info();
    my $n_ctx = $core->get_n_ctx();

    # Tokenization
    my $token_count = $core->count_tokens($text);
    my @tokens = $core->tokenize($text, with_pieces => 1);

=head1 DESCRIPTION

Handles all LLM API communication including streaming completions,
model information, tokenization, and health checks.

=cut
