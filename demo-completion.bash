_demo_completions() {
  local commands="infra build-baseos deploy-vms build-db build-apps release-app upgrade-baseos upgrade-vms all prebuild cleanup"
  COMPREPLY=($(compgen -W "$commands" -- "${COMP_WORDS[COMP_CWORD]}"))
}
complete -F _demo_completions demo.sh
complete -F _demo_completions ./demo.sh
