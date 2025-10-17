# --- z completion (install-friendly, relocatable) ---

# Optional: persona l
cmd_personas=(persona l)
dir_sessions_user=~/.config/zchat/sessions

# Fallback mini initializer if bash-completion isn't present
__z_init_completion_fallback() {
  COMPREPLY=()
  _get_comp_words_by_ref() { :; } 2>/dev/null
  cur=${COMP_WORDS[COMP_CWORD]}
  prev=${COMP_WORDS[COMP_CWORD-1]}
  words=("${COMP_WORDS[@]}")
  cword=${COMP_CWORD}
}

# Portable realpath (works if neither readlink -f nor realpath exists)
__z_realpath() {
  local target="$1" dir base link
  if command -v readlink >/dev/null 2>&1; then
    if readlink -f / >/dev/null 2>&1; then
      readlink -f -- "$target"
      return
    fi
  fi
  if command -v realpath >/dev/null 2>&1; then
    realpath -- "$target" 2>/dev/null && return
  fi
  # manual resolve
  target="${target%/}"
  if [[ "$target" != /* ]]; then target="$PWD/$target"; fi
  while [[ -L "$target" ]]; do
    link=$(readlink "$target") || break
    case "$link" in
      /*) target="$link" ;;
      *)  dir="${target%/*}"; target="$dir/$link" ;;
    esac
  done
  printf '%s\n' "$target"
}

__z_collect_presets() {
  local -n _out=$1
  _out=()

  # Files under $ZCHAT_DATADIR/sys as relative paths (any depth)
  if [[ -n "$ZCHAT_DATADIR" ]]; then
    local root="${ZCHAT_DATADIR%/}/sys"
    if [[ -d "$root" ]]; then
      while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        _out+=("$rel")
      done < <(
        cd "$root" && \
        find . \( -type f -o \( -type l -a -exec test -f {} \; \) \) -print0 2>/dev/null
      )
    fi
  fi

  # personas (append)
  if command -v "${cmd_personas[0]}" &>/dev/null; then
    local persona_lines=()
    if mapfile -t persona_lines < <("${cmd_personas[@]}" 2>/dev/null); then
      local line
      for line in "${persona_lines[@]}"; do
        [[ -n "$line" ]] && _out+=("$line")
      done
    fi
  fi
}

__z_opts() {
  cat <<'OPTS'
-h --help
-v --verbose --verbose_resp --vr
--image --img --clipboard --cb
-i --interactive --int
-e --echo1 --echo-delineated --echod --ee
-r --raw
--tokens_full
-T --token_count
--ctx --metadata
-P --n_predict
--pu --play_user
--pr --play_resp
--probs
--no-color --nc
-g --grammar
--think --thought

--session -n
--store-user --su -S
--store-session --ss
--store-pproc --sp

--system-string --system-str --sstr
--system-file --sfile
--system-persona --spersona --persona
--system --sys -s


--del-user --du
--del-session --ds
--del-pproc --del-shell --dp

--clear-user-system --cus
--clear-session-system --cns
--clear-pproc-system --clear-shell-system --cps

--clear-user-session --cun
--clear-pproc-session --clear-shell-session --cpn

-w --wipe
--wipeold --wipeexp --we --wo
-H --no-history
-I --input-only
-E --edit-hist --eh
--owrite-last
--conv-last --cl
--output-last --ol

-L --list-sys --sys-list
--fallbacks-ok
--status --stat
--print-session-dir --pssd

--help-pins
--pin
--pins-file
--pins-list
--pins-sum
--pins-cnt
--pin-sum-len
--pin-write
--pins-clear
--pin-rm
--pins-sys-max
--pins-user-max
--pins-ast-max

--pin-sys
--pin-user
--pin-ast
--pin-ua-pipe
--pin-ua-json
--pins-clear-user
--pins-clear-ast
--pins-clear-sys
--pin-shim
--pin-tpl-user
--pin-tpl-ast
--pin-mode-sys
--pin-mode-user
--pin-mode-ast

--tool-result
--append-tool-calls
--append-ast
--no-complete

--help-sys-pin-vars
--help-pins
--help-cli
--help-cli-adv
--version

OPTS
}

_z() {
  local cur prev words cword
  if declare -F _init_completion >/dev/null; then
    _init_completion -s || __z_init_completion_fallback
  else
    __z_init_completion_fallback
  fi

  # Keep completing after "/" and treat token like a path when relevant
  compopt -o nospace 2>/dev/null
  compopt -o filenames 2>/dev/null

  __complete_systems() {
    local token="$1" prefix="" needle="$1"
    if [[ "$needle" == *=* ]]; then
      prefix="${needle%%=*}="
      needle="${needle#*=}"
    elif [[ "$needle" == -p* ]]; then
      needle="${needle#-p}"
    elif [[ "$needle" == -t* ]]; then
      needle="${needle#-t}"
    fi
    local presets=()
    __z_collect_presets presets
    local m
    for m in "${presets[@]}"; do
      [[ "$m" == *"$needle"* ]] && COMPREPLY+=("${prefix}${m}")
    done
  }

  __complete_sessions() {
    local -a names
    mapfile -t names < <(cd "$dir_sessions_user" && find . -type d | grep -v '^\.$' | sed -e 's#^./##')
    COMPREPLY=("${names[@]}")
  }

  case "$prev" in
    -s|--sys|--system|--system-persona|--preset|-t|--tasktype)
      COMPREPLY=()
      __complete_systems "$cur"
      return 0
      ;;
    --session|-n)
      COMPREPLY=()
      __complete_sessions "$cur"
      return 0
      ;;
  esac

  if [[ "$cur" == --preset=* || "$cur" == --tasktype=* || "$cur" == -p* || "$cur" == -t* ]]; then
    COMPREPLY=()
    __complete_systems "$cur"
    return 0
  fi

  if [[ "$cur" == -* ]]; then
    local opts; opts="$(__z_opts)"
    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    return 0
  fi
}

# -------- Binding helper (callable by users or your installer) --------
# Usage:
#   __z_bind_completions          # bind sensible defaults (z, ./z, resolved paths)
#   __z_bind_completions z /opt/bin/z ~/dev/proj/z  # custom names/paths
__z_bind_completions() {
  local targets=("$@")
  if [[ ${#targets[@]} -eq 0 ]]; then
    targets+=(z)
    [[ -x ./z ]] && targets+=(./z)
    if command -v z &>/dev/null; then
      targets+=("$(command -v z)")
    fi
    if [[ -x ./z ]]; then
      targets+=("$(__z_realpath ./z)")
    fi
  fi

  local t rp
  for t in "${targets[@]}"; do
    # resolve to absolute if possible (so completion still triggers via symlinks)
    if [[ "$t" == /* ]]; then
      rp="$t"
    else
      rp="$(__z_realpath "$t" 2>/dev/null || printf '%s' "$t")"
    fi
    # bind both the literal token (z / ./z) and the absolute path when sensible
    complete -o bashdefault -o default -o filenames -o nospace -F _z "$t" 2>/dev/null
    [[ -n "$rp" ]] && complete -o bashdefault -o default -o filenames -o nospace -F _z "$rp" 2>/dev/null
  done
}

# Default binding when the file is sourced (safe to re-source)
__z_bind_completions

# --- end z completion ---
