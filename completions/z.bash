# Bash completion for the `z` command

# z's "-t str" is special, specifying a tasktype/persona
# Because I'm moving away from tasktypes being specified
# in z's config (zchat.json (yuck)), this does not support
# tasktypes from it.
# Instead, it accepts a directory to search for files for
# completion
#  or
# It'll use the 'persona l' command to list known personas

# Optional: Set a personas directory manually (user can uncomment)
# dir_personas="/path/personas"

# Command to list personas dynamically
cmd_personas=(persona l)

_z() {
    local cur prev words cword
    _init_completion -s || return

    local opts="
        -d -D -n -E -g -h -I -i -L -P -u -C -H -r -s -S -t -T -v -w
        --cb --clipboard --ctx --def --default-all --dry_run
        --eh --edit-hist --grammar --help --history-input-file
        --img --image --input-only --int --interactive
        --list-tasktypes --metadata --n_predict --no-cache
        --no-color --no-history --play_resp --play_user
        --pr --probs --pu --raw --sfx --storage-sfx
        --store --system --tasktype --think --thought
        --token_count --tokens_full --verbose --verbose_resp --vr --wipe
    "

    case "${prev}" in
        -t|--tasktype)
            COMPREPLY=()
            local personas=()

            if [[ -n "$dir_personas" && -d "$dir_personas" ]]; then
                while IFS= read -r -d '' file; do
                    personas+=("$(basename "$file")")
                done < <(find "$dir_personas" -maxdepth 1 -type f -o -type l -exec test -f {} \; -print0)
            elif command -v "${cmd_personas[0]}" &>/dev/null; then
                if mapfile -t personas < <("${cmd_personas[@]}" 2>/dev/null); then
                    :
                fi
            fi

            local match
            for match in "${personas[@]}"; do
                if [[ "$match" == *"$cur"* ]]; then
                    COMPREPLY+=("$match")
                fi
            done
            return 0
            ;;
    esac

    if [[ "${cur}" == -* ]]; then
        COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
    fi
}
complete -F _z z
