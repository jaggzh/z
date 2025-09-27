#!/usr/bin/perl
#!/usr/bin/perl -d
use v5.36;

use String::ShellQuote;
use bansi; # ANSI color vars: $red, $gre (green), $gra (gray); prefix b* for bright/bold (e.g. $bgre), bg* for backgrounds (e.g. $bgred), and $rst to reset; supports 24-bit truecolor via a24fg(r,g,b)/a24bg(r,g,b)


my $SESSION = "work/records";
my $SYSTEM_PROMPT = <<EOT;
You are a records management assistant. You help users interact with a database of records through specific tool calls.
You are brief and efficient with your tool calls; that is, when you request information, like with records.get or
records.search tools, you are done.

## Example 1 messages:
User:
Get me information on record 2
Assistant:
I have to find available records to ensure I get the right ID.
records.list()

## Example 2 messages:
Tool:
Records list: 001, 002, 003, 004, 005
Assistant:
It appears record 2 would be formatted as 002
records.get(id: "002")

## Example 3 messages:
Tool:
{Sample record contents for record 002}
Assistant:
I located what seems to be your requested record "2" as "002".
Its contents are as follows:
Sample record contents for record 002


## Available Tools

### Record Management
```
records.list() -> string
# Returns JSON array of all record IDs
# Example: records.list()

records.get(id: "record_id") -> string  
# Returns full record details as JSON
# Example: records.get(id: "rec001")

records.search(query: "search_terms") -> string
# Search records by content, returns matching record IDs
# Example: records.search(query: "project alpha")
```

### User Communication
```
user.tell(message: "text") -> void
# Display important information to the user
# Use this to communicate findings, summaries, or status updates
# Example: user.tell(message: "Found 3 matching records")

user.get() -> void
# Wait for user input (ends your turn)
# Use when you need additional information from the user
# Example: Always call after user.tell() when expecting a response
```

## Instructions

1. **Tool Call Format**: Use exact syntax shown above, one call per line
2. **Always call tools first** when data is needed, then provide analysis
3. **Use user.tell()** to communicate important findings or summaries
4. **Be concise** but thorough in your responses
5. **Handle errors gracefully** if tool calls fail

## Example Interaction

[Initial interaction:]
User: "Show me details for record 50"
Assistant response:
records.get(id: "rec050")
[Assistant ends message and waits for tool results.]

[After receiving the tool results:]
Assistant response:
user.tell(message: "Retrieved record 50's details - it's a project status report from January")

[User may now continue if they wish.]

EOT

# Function to execute record tools
sub execute_record_tool($tool_call) {
	# Returns return status and result.
	#  ( 1,  "response")  # Success
	#  (-1,  anything)  # Tool returns no data
	#  ( 0, undef|"response" [, "Optional internal error msg" ])
	#
	# Errors being provided *to the LLM* can only be sent as a "response"
	# -1: Caller may ignore and not pass "no response" tool call to LLM.
	#  1: Caller should send response to LLM
	#  0: ERROR: Caller should send "response" if it's defined, to the LLM
	#                    NOT send anything to LLM and may report error to user
    if ($tool_call =~ /records\.list\(\)/) {
        return (1, '["rec001", "rec002", "rec003", "rec004", "rec005"]');
        
    } elsif ($tool_call =~ /records\.get\(id:\s*"([^"]+)"\)/) {
        my $rec_id = $1;
        return (1, qq|{
    "id": "$rec_id",
    "title": "Record $rec_id", 
    "status": "active",
    "created": "2024-01-15",
    "data": "Sample data for record $rec_id"
}|);
        
    } elsif ($tool_call =~ /user\.tell\(message:\s*"([^"]+)"\)/) {
        my $message = $1;
        warn ">> $message\n";
        return (-1);
        
    } else {
        warn "ERROR: Unknown tool call: $tool_call\n";
        return (0, undef, "Unknown tool call: $tool_call");
    }
}

# Function to parse and execute tool calls from LLM response
sub handle_tool_calls($response) {
    my @tool_results;
    
    # Look for instruction-based tool calls (lines that look like function calls)
    for my $line (split /\n/, $response) {
        if ($line =~ /^[a-zA-Z_]+\.[a-zA-Z_]+\(.*\)$/) {
			my ($tool_name) = $line =~ /^([^(]+)/;
            warn "Executing tool: $line\n";
            
            # Execute the tool and get result
            my ($status, $response, $interrstr) = execute_record_tool($line);
            if ($status == -1) { # No response
			} elsif ($status == 0) { # Error
				if (defined $response) {
					push @tool_results, "--tool-result", "${tool_name}:${response}";
				} # Or we ignore it
			} else { # Success
				push @tool_results, "--tool-result", "${tool_name}:${response}";
			}
        }
    }
    
    return @tool_results;
}

sub main(@ARGV) {
    my $query = join(' ', @ARGV);
    
    die "Usage: $0 <query>\n" unless $query;
    
    say "Query: $query";
    say "Session: $SESSION";
    say "";
    
    # Make initial request
    say "=== Initial LLM Response ===";
    system('z', '-w', '-n', $SESSION, '--sp'); # Store session active in our parent shell
    system('z', '--system-string', $SYSTEM_PROMPT, '--ss'); # Store our system prompt with tool defs in this session
    my @cmd = ('z', $query); # Perform initial query
    my $cmd_str = shell_quote(@cmd);
    say "COMMAND: $cya$cmd_str$rst";
    my $response = `$cmd_str`;
    chomp $response;
    say "RAW LLM OUTPUT: $yel$response$rst";
    say "";
    
    # Check if response contains tool calls
    if ($response =~ /^[a-zA-Z_]+\.[a-zA-Z_]+\(.*\)$/m) {
        say "=== Tool calls detected, executing... ===";
        
        # Parse and execute tools
        my @tool_args = handle_tool_calls($response);
        
        if (@tool_args) {
            say "Tool arguments: " . join(' ', @tool_args);
            say "";
            
            # Continue conversation with tool results
            say "=== Continuing conversation with tool results ===";
            my @final_cmd = ('z', ('-v')x3, '-n', $SESSION, @tool_args); # , '--debug'); # Just making sure our session is active
            my $final_cmd_str = shell_quote(@final_cmd);
            say "COMMAND: $cya$final_cmd_str$rst";
            my $final_response = `$final_cmd_str`;
            chomp $final_response;
			say "RAW LLM OUTPUT: $yel$final_response$rst";
        } else {
            say "No executable tools found";
        }
    } else {
        say "No tool calls detected - conversation complete";
    }
}

main(@ARGV);
