# **z / ZChat**: System Prompt Specification

ZChat supports three types of system prompts: files, literal strings, and personas managed by the `persona` project.

All system prompts support `<: foo :>` Text::Xslate template variables. See README.md for details on available variables and usage patterns.

## System Prompt Types

### **System Files** (`--system-file path`)

A *path* can be either:
- **Filename**: Contents are used directly as the system prompt
- **Directory**: Must contain `directory/system` file with the prompt content, plus optional `directory/meta.yaml`

#### Search Order for System Files

1. **Relative paths**: Resolved relative to current execution directory (`..` is allowed)
2. **Absolute paths**: Used directly (e.g., `/absolute/path/to/prompt`)  
3. **System directory**: `~/.config/zchat/system/{path}` (Note: `..` not accepted in system directory paths)

**IMPORTANT**: Upon successful resolution, the full absolute path is stored for optimization and consistency. This ensures the system file remains accessible even if `z` is later invoked from a different directory.

### **System Strings** (`--system-string text`)

Raw string content stored as-provided. Also supports Xslate template variable processing.

### **System Personas** (`--system-persona name`)

Managed by the `persona` project (currently unpublished but may be included in ZChat in the future).

## Resolution Logic

### `--system-file` Resolution

**For absolute paths:**
- Use directly as file or directory
- Error on failure unless `--fallbacks-ok` is set (then warn and try next precedence level)

**For relative paths:**
- Attempt relative resolution (allowing `..`)
- If found: expand to absolute path and store as `system_file`
- If not found:
  - **Contains `..`**: 
    - `--fallbacks-ok`: Try next precedence level
    - No fallbacks: Error out
  - **No `..`**: Check `~/.config/zchat/system/{path}`
    - If found: Load and store absolute path
    - If not found:
      - `--fallbacks-ok`: Try next precedence level  
      - No fallbacks: Error out

### `--system-persona` Resolution

- Resolve using `persona` binary only
- **Not found**: Fallback behavior or error based on `--fallbacks-ok`
- **Multiple found**: 
  - `--fallbacks-ok`: Use first available
  - No fallbacks: Error out
- **None found**: Fallback behavior or error based on `--fallbacks-ok`

### `--system` (Auto-resolve) Resolution

Attempts file resolution first, then persona resolution:

1. **Try as system file** using the same process as `--system-file` 
   - Display attempted paths when `-vv` specified
   - Do not error if not found (continue to persona resolution)

2. **If file resolution fails:**
   - **Contains `..` or absolute path**:
     - `--fallbacks-ok`: Try next precedence level (skip persona resolution)
     - No fallbacks: Error out
   - **No `..` and relative**: Continue to persona resolution

3. **Try as persona** using `--system-persona` logic

## Precedence Integration

This resolution logic operates within ZChat's precedence system. When fallbacks are enabled and resolution fails, the system moves up the precedence chain (CLI → shell → session → user → system defaults) to find a usable system prompt.

See `PRECEDENCE.md` for complete details on how CLI options override stored configurations.
