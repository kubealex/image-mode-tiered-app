_demo_completions() {
  local commands="show-containerfiles infra build-baseos deploy-vms build-db build-apps release-app upgrade-baseos upgrade-db upgrade-vms all prebuild cleanup"
  COMPREPLY=($(compgen -W "$commands" -- "${COMP_WORDS[COMP_CWORD]}"))
}
complete -F _demo_completions im-train-demo
complete -F _demo_completions ./im-train-demo
