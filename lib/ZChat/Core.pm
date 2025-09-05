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
        api_base => ($opts{api_base} // $ENV{LLM_API_URL} // 'http://127.0.0.1:8080'),
        model_info => undef,
        model_info_loaded => 0,
    };
    
    bless $self, $class;
    return $self;
}

sub complete_request {
    my ($self, $messages, $opts) = @_;
    
    sel(2, "Making completion request with " . @$messages . " messages");
    
    # Debug: show message summary
    if (get_verbose() >= 3) {
    	sel 3, "=== Message history: ===";
        for my $i (0..$#$messages) {
            my $msg = $messages->[$i];
            my $content_len = length($msg->{content});
            sel(3, "Message $i: role=$msg->{role}, length=$content_len");
            sel(4, "Message $i content: $msg->{content}");
        }
    }
    
    # Default options
    my $temperature = $opts->{temperature} || 0.7;
    my $top_k = $opts->{top_k} || 40;
    my $top_p = $opts->{top_p} || 0.9;
    my $min_p = $opts->{min_p} || 0.08;
    my $n_predict = $opts->{n_predict} || 8192;
    my $stream = $opts->{stream} // 1;
    my $raw = $opts->{raw} || 0;
    my $show_thought = $opts->{show_thought} || 0;
    my $remove_pattern = $opts->{remove_pattern};
    
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
    $data->{grammar} = $opts->{grammar} if $opts->{grammar};
    $data->{n_probs} = int($opts->{n_probs}) if $opts->{n_probs};
    
    sel(3, "API request data: " . dumps($data));

    if ($stream) {
        return $self->_stream_completion($data, $opts);
    } else {
        return $self->_sync_completion($data, $opts);
    }
}

sub _stream_completion {
    my ($self, $data, $opts) = @_;
    
    my $raw = $opts->{raw} || 0;
    my $remove_pattern = $opts->{remove_pattern};
    my $show_thought = $opts->{show_thought} || 0;
    my $live_output = !$raw && (!$remove_pattern || $show_thought);
    
    my $ua = Mojo::UserAgent->new(max_response_size => 0);
    my $tx = $ua->build_tx(
        POST => "$self->{api_base}/v1/chat/completions",
        { 'Content-Type' => 'application/json' },
        json => $data
    );
    
    my $answer = '';
    my $token_count = 0;
    my $buffer = '';
    
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
                
                # Check for completion
                my $choice = $decoded->{choices}[0];
                last if $choice->{finish_reason};
                
                # Extract content from delta
                if (defined $choice->{delta} && defined $choice->{delta}{content}) {
                    my $chunk = $choice->{delta}{content};
                    
                    # Clean up first token
                    $chunk =~ s/^\s+// unless $token_count;
                    
                    # Output if live mode
                    print $chunk if $live_output && $chunk ne '';
                    
                    $answer .= $chunk;
                    $token_count++;
                }
            }
        }
    });
    
    # Execute request
    $ua->start($tx);
    
    # Post-process if needed
    if (!$live_output) {
        if ($remove_pattern && !$show_thought) {
            $answer =~ s/$remove_pattern//s;
        }
        print $answer;
    }
    
    # Ensure newline at end
    print "\n" if $answer && $answer !~ /\n$/;
    
    return $answer;
}

sub _sync_completion {
    my ($self, $data, $opts) = @_;
    
    my $ua = Mojo::UserAgent->new();
    my $tx = $ua->post(
        "$self->{api_base}/v1/chat/completions",
        { 'Content-Type' => 'application/json' },
        json => $data
    );
    
    unless ($tx->res->is_success) {
        die "API request failed: " . $tx->res->message;
    }
    
    my $response = $tx->res->json;
    my $content = $response->{choices}[0]{message}{content} || '';
    
    # Post-process if needed
    my $remove_pattern = $opts->{remove_pattern};
    my $show_thought = $opts->{show_thought} || 0;
    
    if ($remove_pattern && !$show_thought) {
        $content =~ s/$remove_pattern//s;
    }
    
    return $content;
}

sub get_model_info {
    my ($self) = @_;
    
    return $self->{model_info} if $self->{model_info_loaded};
    
    my $url = "$self->{api_base}/props";
    my $ua = LWP::UserAgent->new(timeout => 5);
    
    my $response = $ua->get($url);
    unless ($response->is_success) {
        die "Failed to get model props: " . $response->status_line;
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
    
    my $props = $self->get_model_info();
    return $props->{default_generation_settings}{n_ctx} || 8192;
}

sub tokenize {
    my ($self, $text, $opts) = @_;
    
    my $with_pieces = $opts->{with_pieces} || 0;
    
    my $ua = LWP::UserAgent->new(timeout => 5);
    my $url = "$self->{api_base}/tokenize";
    
    my $request_data = { content => $text };
    $request_data->{with_pieces} = JSON::XS::true if $with_pieces;
    
    my $json = encode_json($request_data);
    my $req = HTTP::Request->new('POST', $url);
    $req->content_type('application/json');
    $req->content($json);
    
    my $res = $ua->request($req);
    unless ($res->is_success) {
        warn "Tokenization request failed: " . $res->status_line;
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
    my $response = $ua->get("$self->{api_base}/health");
    
    return {
        status => $response->is_success,
        code => $response->code,
        message => $response->message,
    };
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
