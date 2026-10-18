# ~/.zshrc — the interactive shell (system /etc/zsh/zshrc runs the ombra panel on the first terminal of a session).

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

# ---- plugins --------------------------------------------------------------
[ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ] && \
    source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
# syntax highlighting MUST be last among plugins
[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && \
    source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# ---- palette ---------------------------------------------------------------
typeset -A ZSH_HIGHLIGHT_STYLES
ZSH_HIGHLIGHT_STYLES[command]='fg=#56d68a'
ZSH_HIGHLIGHT_STYLES[alias]='fg=#56d68a'
ZSH_HIGHLIGHT_STYLES[builtin]='fg=#8f9bff'
ZSH_HIGHLIGHT_STYLES[function]='fg=#8f9bff'
ZSH_HIGHLIGHT_STYLES[precommand]='fg=#8f9bff,underline'
ZSH_HIGHLIGHT_STYLES[reserved-word]='fg=#c39bff'
ZSH_HIGHLIGHT_STYLES[unknown-token]='fg=#f0716b'
ZSH_HIGHLIGHT_STYLES[path]='fg=#f4f3ef,underline'
ZSH_HIGHLIGHT_STYLES[globbing]='fg=#6fd4d4'
ZSH_HIGHLIGHT_STYLES[single-quoted-argument]='fg=#f2c260'
ZSH_HIGHLIGHT_STYLES[double-quoted-argument]='fg=#f2c260'
ZSH_HIGHLIGHT_STYLES[dollar-quoted-argument]='fg=#f2c260'
ZSH_HIGHLIGHT_STYLES[back-quoted-argument]='fg=#c39bff'
ZSH_HIGHLIGHT_STYLES[commandseparator]='fg=#c39bff'
ZSH_HIGHLIGHT_STYLES[redirection]='fg=#c39bff'
ZSH_HIGHLIGHT_STYLES[comment]='fg=#5c6070'
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=#5c6070'

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

# ombra: connectivity panel on demand (it also greets each session)
alias ombra='/usr/local/bin/ombra'
