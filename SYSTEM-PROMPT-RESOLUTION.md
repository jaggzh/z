# **z / ZChat**: Providing system prompts

We allow system prompts to be specified as files, strings, or 'persona's managed by the `persona` project.

All system prompts, at present, are subject to `<: foo :>` Text::Xslate variables.
See README.md for more info on that. These are also usable for customizing pinned content presentation.

* **System file**: (Provided as a `path`)
  A *path* may be a **filename** -- contents are the system prompt.
  Or a **directory**, where `**directory**/system` contains the contents of the system prompt. The directory may contain an optional `meta.yaml`.

  System files are looked for in this order:
    1. **Relative** to current execution (`..` is allowed)
    2. **Absolute** /paths
    3. **~/.config/zchat/system/{path}**: `..` not accepted for now (ie. if the path contains `/../` we do not attempt to locate it in the system prompts dir **for now**.

  *IMPORTANT:* Upon resolution of the path, **it is stored as a full absolute path** to the file, for optimization as well as consistency (e.g. if 'z' is later invoked from another directory the system file must still be found).

* **System string**:
  This is stored as the raw string as-provided (and is also subject to Xslate variable processing)

* **System "personas"**: This is my presently-unpublished persona manager. I likely will just include it in this project in the future.


## How the system locates your system prompt

Note that this is the stage of resolving a system prompt, and is not detailing priorities of how CLI will override the current session, etc.

That is the *"precedence"* system, and is ideally a LOT more intuitive than the underlying logic hides.

Briefly, as an example, if you store a default system prompt, like `z --system-file myassistant.txt --store-user` (can also use `--su`), great. But if you specify another system prompt on the CLI in a future run, it'll "obviously" override that. See PRECEDENCE.md for details.

I have not re-written the rest of this yet. But

### Logic of system resolution

if --system-file:
  if /absolute, use directly (as file or dir) and error if failure. If fallbacks-ok we warn and go up precedence to try to resolve  as any usable default.
  if not absolute: Attempt to resolve as a relative path (allowing '..').
    If found as a file or dir we expand path and store as system_file. Done.
    If not found as a file:
       If '..' is in the path:
           if fallbacks-ok: Go up precedence to resolve as any usable default
           if not fallbacks-ok: error out
        if '..' is not in the path, check the ~/config/zchat/system/{their system_file string, which may include slashes/subdirs}:
          if found as a file or a dir, load as system prompt (possibly with meta data) and resolve path and store as system-file full path
          if not found:
                   If fallbacks-ok: go up precedence to resolve as any usable default
                   If not fallbacks-ok: error out

if system-persona:  Do with persona bin only.
   If not found at all:
        If fallbacks-ok: go up precedence ....
        if not fallbacks-ok: Error out
   if more than one found:
        if fallbacks-ok: Use first available
        if not fallbacks-ok: Error out
   if none found:
        if fallbacks-ok: go up precedence
        if not fallbacks-ok: error out

If --system:
   Attempt to resolve using the same process of resolving system *files*, EXCEPT, we do not error out, but we do display what was tried when -v -v specified.
   If not found as a system file:
       If it has '..' in it, or it's an absolute path.
            if fallbacks-ok: do NOT resolve through 'persona' (because it's invalid): Go up precedence
            if not fallbacks-ok: error out
       if no '..' in it and not an absolute path:

# vim: et ts=2 sw=2 sts=2
