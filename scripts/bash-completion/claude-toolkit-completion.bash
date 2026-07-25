# bash-completion for Claude Toolkit commands
# Source this file from your .bashrc or drop it into:
#   ~/.local/share/bash-completion/completions/
#
# Install:
#   mkdir -p ~/.local/share/bash-completion/completions/
#   ln -sf "$(pwd)/scripts/bash-completion/claude-toolkit-completion.bash" \
#     ~/.local/share/bash-completion/completions/claude-providers
#
# Then add to ~/.bashrc:
#   [ -f ~/.local/share/bash-completion/completions/claude-providers ] && source "$_"

_claude_toolkit_subcommands() {
  local cmd="$1"
  case "$cmd" in
    claude-providers)
      COMPREPLY=($(compgen -W "sync status list generate verify install reset
        health probe token-usage alias token token-reset resolve provider
        model tiering session-sync-hook bootstrap-install config
        semantic-search" -- "${COMP_WORDS[COMP_CWORD]}"))
      ;;
    claude-unify)
      COMPREPLY=($(compgen -W "--force --dry-run --help" -- "${COMP_WORDS[COMP_CWORD]}"))
      ;;
    claude-add-account)
      COMPREPLY=($(compgen -W "--name --help" -- "${COMP_WORDS[COMP_CWORD]}"))
      ;;
    claude-remove-account)
      local accounts
      accounts=$(ls -d "$HOME/.claude-"* 2>/dev/null | sed 's|.*/\.claude-||')
      if [ -n "$accounts" ]; then
        COMPREPLY=($(compgen -W "$accounts" -- "${COMP_WORDS[COMP_CWORD]}"))
      fi
      ;;
    claude-list-accounts)
      COMPREPLY=($(compgen -W "--json --help" -- "${COMP_WORDS[COMP_CWORD]}"))
      ;;
    claude-gc)
      COMPREPLY=($(compgen -W "--dry-run --aggressive --help" -- "${COMP_WORDS[COMP_CWORD]}"))
      ;;
    claude-session)
      COMPREPLY=($(compgen -W "save restore list delete" -- "${COMP_WORDS[COMP_CWORD]}"))
      ;;
    claude-rollback)
      local backups
      backups=$(ls -d "$HOME/.claude"-*.bak.* 2>/dev/null | sed 's|.*/\.claude-||; s|\.bak\..*||' | sort -u)
      if [ -n "$backups" ]; then
        COMPREPLY=($(compgen -W "$backups" -- "${COMP_WORDS[COMP_CWORD]}"))
      fi
      ;;
    ccr)
      COMPREPLY=($(compgen -W "version config serve routes stats health" -- "${COMP_WORDS[COMP_CWORD]}"))
      ;;
    cma-proxy)
      COMPREPLY=($(compgen -W "version config probe health stats" -- "${COMP_WORDS[COMP_CWORD]}"))
      ;;
  esac
}

_claude_toolkit_completion() {
  local cur prev words cword
  _init_completion || return
  local cmd
  cmd=$(basename "${COMP_WORDS[0]}")
  if [ "$cword" -eq 1 ]; then
    _claude_toolkit_subcommands "$cmd"
  fi
}

# Register completions for each toolkit command
complete -F _claude_toolkit_completion claude-providers
complete -F _claude_toolkit_completion claude-unify
complete -F _claude_toolkit_completion claude-add-account
complete -F _claude_toolkit_completion claude-remove-account
complete -F _claude_toolkit_completion claude-list-accounts
complete -F _claude_toolkit_completion claude-gc
complete -F _claude_toolkit_completion claude-session
complete -F _claude_toolkit_completion claude-rollback
complete -F _claude_toolkit_completion ccr
complete -F _claude_toolkit_completion cma-proxy
complete -F _claude_toolkit_completion claude-export-docs
complete -F _claude_toolkit_completion claude-bootstrap
complete -F _claude_toolkit_completion claude-install-verify
complete -F _claude_toolkit_completion claude-verify-providers
complete -F _claude_toolkit_completion claude-semantic-visibility
complete -F _claude_toolkit_completion claude-sync-state
complete -F _claude_toolkit_completion claude-release-gate
complete -F _claude_toolkit_completion claude-opencode-sync
complete -F _claude_toolkit_completion claude-ccr-build
complete -F _claude_toolkit_completion claude-proxy-build
