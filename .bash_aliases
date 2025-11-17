# ~/.bash_aliases - aliases for Vast pod shells

# Shortcuts for navigation
alias ..='cd ..'
alias ...='cd ../..'
alias c='clear'

# Safer rm/cp/mv
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# LS helpers
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# -------------------------
# Git aliases & defaults
# -------------------------
# Nice short git commands
alias g='git'
alias gst='git status -sb'
alias ga='git add'
alias gaa='git add -A'
alias gc='git commit'
alias gcm='git commit -m'
alias gco='git checkout'
alias gsw='git switch'
alias gb='git branch'
alias gl='git log --oneline --graph --decorate --max-count=30'
alias gll='git log --oneline --graph --decorate --all --max-count=100'
alias gd='git diff'
alias gds='git diff --stat'

# These are safe global defaults to run once manually if you like:
#   git config --global color.ui auto
#   git config --global init.defaultBranch main
#   git config --global pull.rebase false

# -------------------------
# Pod / ComfyUI helpers
# -------------------------

# Common locations
alias cwork='cd /workspace'
alias cmirror="cd $repo_root"
alias ccomfy='cd /workspace/ComfyUI'

# Log helpers
alias blog='cd /workspace && tail -f /workspace/bootstrap_run.log'
alias clog='cd /workspace/logs && ls -ltr'
alias slogs='cd /workspace/logs && ls -ltr'

# Python shortcuts inside the venv (if present)
if [ -x /opt/venv/bin/python3 ]; then
  alias py='/opt/venv/bin/python3'
  alias pip='/opt/venv/bin/pip'
fi
