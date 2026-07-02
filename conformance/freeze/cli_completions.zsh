#compdef skein
# zsh completions for skein. Generate and install with:
#   mkdir -p ~/.zfunc && skein completions zsh > ~/.zfunc/_skein
#   # in ~/.zshrc, before compinit: fpath=(~/.zfunc $fpath)

_skein() {
  local -a commands
  commands=(
    'compile:Compile a single .skein file'
    'new:Scaffold a new Skein project'
    'build:Compile all .skein files in a project'
    'test:Run all tests in a project'
    'run:Start the Skein service'
    'agents:Create or refresh AGENTS.md'
    'mcp:Start the MCP server (stdio, for coding agents)'
    'lsp:Start the language server (stdio, for editors)'
    'trace:View recent trace spans'
    'completions:Print a shell completion script'
    'version:Print version'
    'help:Show help'
  )

  if (( CURRENT == 2 )); then
    _describe -t commands 'skein command' commands
    return
  fi

  case $words[2] in
    compile)
      _files -g '*.skein'
      ;;
    new)
      _arguments \
        '--backend[LLM backend for skein.toml (default anthropic)]:backend:(anthropic bedrock openai_compatible test)' \
        '--no-agents[Skip generating AGENTS.md / CLAUDE.md]' \
        '--no-git[Skip git init (a .gitignore is always written)]' \
        '*:project directory:_directories'
      ;;
    build)
      _arguments \
        '--output[Write .beam files to directory]:output directory:_directories' \
        '*:project directory:_directories'
      ;;
    run)
      _arguments \
        '--port[Server port (default 4000)]:port:' \
        '--no-persist[Skip SQLite event persistence]' \
        '*:project directory:_directories'
      ;;
    test|agents)
      _directories
      ;;
    trace)
      _arguments \
        '--last[Number of traces (default 10)]:count:' \
        '--kind[Filter by span kind]:kind:(http llm tool memory store queue topic schedule handler)'
      ;;
    completions)
      compadd zsh
      ;;
  esac
}

_skein "$@"
