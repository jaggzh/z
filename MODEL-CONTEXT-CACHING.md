## Model Context Caching and Stats Functionality

See: `z --ctx-info`

ZChat's context management system automatically handles the tricky problem of fitting conversations into your model's context window. It learns from your actual usage patterns to make semi-intelligent decisions about what to keep and what to drop when conversations get long.

The primary goal is to allow queries to properly assemble

1. System Prompt (in full)
2. Pins
3. Message history (tail end, as many messages that'll fit)

We do this within a reserve capacity (85% reported context) so the model has some room to respond.

## The Problem

LLMs have a fixed context window (e.g., 8192, 16384, 32768 tokens). When your conversation history + system prompt + pinned messages exceed this limit, the model simply fails. ZChat attempts to prevent this by intelligently trimming older messages while preserving:
- Your system prompt
- All pinned messages
- Recent conversation context

## How It Works

### 1. Context Size Discovery

When you first use a model, ZChat:
- Queries the model for its context size (via `/props` endpoint)
- Caches this information for 24 hours
- Uses 85% of the total context as "safe space" (leaving room for the model's response)

### 2. Token Estimation

Counting tokens for every message is slow (can take 500ms+). Instead, ZChat:
- Starts with a reasonable estimate: 3.5 characters = 1 token
- Learns your actual ratio from real usage
- Updates its estimate using a rolling average

### 3. The Learning Algorithm

Every time you complete a query, ZChat:
1. Gets the actual token count from the model's response
2. Calculates the real character-to-token ratio for that query
3. Updates its estimate using: `new_estimate = (0.7 × old_estimate) + (0.3 × new_ratio)`

This exponential moving average means:
- Recent data has more weight than old data
- Estimates smooth out over time
- Model-specific patterns are learned (code-heavy chats have different ratios than prose)

### 4. Message Fitting

When building a query, ZChat:
1. Calculates fixed overhead (system prompt + pins)
2. Works backwards through history, adding messages until space runs out
3. Always keeps at least 4 recent messages (2 exchanges) for context
4. Logs when messages are dropped

## Cache Structure

The cache file (`~/.config/zchat/model_cache.yaml`) stores:

```yaml
# Context size cache (24-hour TTL)
ctx_model-name:
  n_ctx: 32768
  timestamp: 1703123456
  model: "SomeModel-13b"

# Token ratio cache (updated continuously)
ratio_model-name:
  ratio: 3.28      # Characters per token for this model
  samples: 47      # Number of queries used to calculate
  timestamp: 1703123456
```

## Viewing Context Information

```bash
# Show current model's context info
z --ctx-info

# Output:
Model: SomeModel-13b
Context size: 32768 tokens
Usable (85%): 27852 tokens
Char/token ratio: 3.28
Based on 47 samples
```

## What This Means for You

### The Good
- **No more context errors**: Conversations automatically fit within limits
- **Smart trimming**: Only old messages are dropped, recent context is preserved
- **Fast queries**: No token counting delays after the first usage
- **Model-aware**: Each model gets its own learned ratios

### The Limitations
- **First query is slightly slower**: Needs to fetch context size
- **Estimates aren't perfect**: Safety margin prevents edge cases
- **Old messages disappear**: Very long conversations lose early context

### Tuning

You can adjust behavior by modifying `ContextManager.pm`:
- `safety_margin`: Default 0.85 (use 85% of context)
- `char_token_ratio`: Default 3.5 (initial estimate)
- `min_history_messages`: Default 4 (minimum to keep)

## Technical Details

### Why Not Count Tokens Every Time?

Token counting requires a server round-trip and can add 500ms+ to every query. By learning ratios over time, we get "good enough" estimates with zero latency.

### Why Exponential Moving Average?

This algorithm (0.7 × old + 0.3 × new) provides:
- **Stability**: One outlier doesn't break estimates
- **Adaptability**: Gradually adjusts to usage patterns
- **Recency bias**: Recent patterns matter more than old ones

### Why 85% Safety Margin?

Models need space for:
- Their response (can be lengthy)
- Internal formatting tokens
- Safety buffer for estimation errors

## Troubleshooting

**Q: My messages are being cut off too early**
- The model might be returning inflated token counts
- Try reducing `safety_margin` to 0.9

**Q: I'm getting context errors**
- Check `--ctx-info` to verify detected context size
- Ensure your model properly reports context size
- Try manually setting a lower context limit

**Q: Token estimates seem wrong**
- Delete the cache file to reset learning: `rm ~/.config/zchat/model_cache.yaml`
- Check if your content type (code vs prose) matches typical usage
