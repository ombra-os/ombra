# ~/.zshrc — personal shell setup; the system /etc/zsh/zshrc owns the session greeting.

# ---- history ---------------------------------------------------------------
HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
setopt SHARE_HISTORY          # sessions see each other's history live
setopt EXTENDED_HISTORY       # timestamps per entry
setopt HIST_IGNORE_ALL_DUPS   # no duplicate lines
setopt HIST_IGNORE_SPACE      # commands starting with space = off record
setopt HIST_REDUCE_BLANKS

# ---- completion ------------------------------------------------------------
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'  # case-insensitive

# ---- line editing ----------------------------------------------------------
bindkey -e                                           # emacs keys
bindkey '^[[A' history-search-backward               # arrows search by prefix
bindkey '^[[B' history-search-forward

# ---- plugins ---------------------------------------------------------------
[ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ] && \
    source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
# syntax highlighting MUST be last among plugins
[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && \
    source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# ---- modern CLI wiring ------------------------------------------------------
command -v starship >/dev/null && eval "$(starship init zsh)"
command -v zoxide    >/dev/null && eval "$(zoxide init zsh)"
[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ] && \
    source /usr/share/doc/fzf/examples/key-bindings.zsh
[ -f /usr/share/doc/fzf/examples/completion.zsh ] && \
    source /usr/share/doc/fzf/examples/completion.zsh

# ---- small, opinionated defaults -------------------------------------------
alias ls='eza --group-directories-first --icons'
alias ll='eza -l --group-directories-first --icons --git'
alias la='ll -a'
alias tree='eza --tree --icons'
alias cat='bat --paging=never'
alias grep='rg'
# cd keeps working; zoxide's `z` jumps to frequent dirs

# ombra: connectivity panel on demand (it also greets each session)
alias ombra='/usr/local/bin/ombra'
