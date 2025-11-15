# ~/.bashrc: executed by bash(1) for non-login shells.

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# -------------------------
# History behaviour
# -------------------------
# don't put duplicate lines or lines starting with space in the history.
HISTCONTROL=ignoreboth
# append to the history file, don't overwrite it
shopt -s histappend
# big-ish shared history across shells
HISTSIZE=50000
HISTFILESIZE=200000
PROMPT_COMMAND='history -a; history -n; '"${PROMPT_COMMAND:-:}"

# -------------------------
# Prompt (keep your style)
# -------------------------
# set variable identifying the chroot you work in (used in the prompt below)
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# set a fancy prompt (non-color, unless we know we "want" color)
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac

#force_color_prompt=yes
if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
        color_prompt=yes
    else
        color_prompt=
    fi
fi

if [ "$color_prompt" = yes ]; then
    # same style you had: green user@host, blue cwd, single line
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
fi
unset color_prompt force_color_prompt

# If this is an xterm, set the title to user@host:dir
case "$TERM" in
  xterm*|rxvt*)
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
    ;;
  *)
    ;;
esac

# -------------------------
# LS colors & common tools
# -------------------------
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
fi

# grep with color
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# -------------------------
# Mouse wheel sanity (no scroll hijack)
# -------------------------
# Disable terminal mouse tracking modes that can steal scroll events
# but keep arrow keys fully functional.
printf '\e[?1000l\e[?1002l\e[?1003l\e[?1005l\e[?1006l' 2>/dev/null || true

# Arrow keys for plain history navigation (what you ended up with)
bind '"\e[A": previous-history'
bind '"\e[B": next-history'

# -------------------------
# Load extra functions & aliases (if present)
# -------------------------
if [ -f "$HOME/.bash_functions" ]; then
  # shellcheck disable=SC1090
  . "$HOME/.bash_functions"
fi

if [ -f "$HOME/.bash_aliases" ]; then
  # shellcheck disable=SC1090
  . "$HOME/.bash_aliases"
fi

SCRIPT_PATH="${BASH_SOURCE[0]}"
if [[ -L "$SCRIPT_PATH" ]]; then
  SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
fi
repo_root="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

# -------------------------
# Vast / ComfyUI environment wiring
# -------------------------

# Make sure /workspace etc. is on PATH for mirror/rebase helpers etc.
case ":$PATH:" in
  *:/workspace:*) ;;
  *) export PATH="/workspace:$repo_root:$repo_root/scripts:$PATH" ;;
esac

# Try to align this interactive shell with the bootstrap/autorun environment
if type -t load_runtime_env >/dev/null 2>&1; then
  load_runtime_env 2>/dev/null || true
fi

cd /workspace