# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the package bash-doc)
# for examples

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# don't put duplicate lines or lines starting with space in the history.
# See bash(1) for more options
HISTCONTROL=ignoreboth

# append to the history file, don't overwrite it
shopt -s histappend

# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
HISTSIZE=1000
HISTFILESIZE=2000

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize

# If set, the pattern "**" used in a pathname expansion context will
# match all files and zero or more directories and subdirectories.
#shopt -s globstar

# make less more friendly for non-text input files, see lesspipe(1)
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# set variable identifying the chroot you work in (used in the prompt below)
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# set a fancy prompt (non-color, unless we know we "want" color)
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac

# uncomment for a colored prompt, if the terminal has the capability; turned
# off by default to not distract the user: the focus in a terminal window
# should be on the output of commands, not on the prompt
#force_color_prompt=yes

if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
	# We have color support; assume it's compliant with Ecma-48
	# (ISO/IEC-6429). (Lack of such support is extremely rare, and such
	# a case would tend to support setf rather than setaf.)
	color_prompt=yes
    else
	color_prompt=
    fi
fi

if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
fi
unset color_prompt force_color_prompt

# If this is an xterm set the title to user@host:dir
case "$TERM" in
xterm*|rxvt*)
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
    ;;
*)
    ;;
esac

# enable color support of ls and also add handy aliases
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    #alias dir='dir --color=auto'
    #alias vdir='vdir --color=auto'

    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

# colored GCC warnings and errors
#export GCC_COLORS='error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01'

# some more ls aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# Add an "alert" alias for long running commands.  Use like so:
#   sleep 10; alert
alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'

# enable programmable completion features (you don't need to enable

# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# --- Load personal aliases/functions ---
# Guard against Windows CRLF/BOM issues: keep files edited inside WSL.

# Load aliases first (so you can override them later if needed)
[ -r "$HOME/.bash_aliases" ]   && source "$HOME/.bash_aliases"

# Load functions after aliases (so functions win)
[ -r "$HOME/.bash_functions" ] && source "$HOME/.bash_functions"

# === tiny safe helper: source_if_exists ===
source_if_exists() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  # shellcheck disable=SC1090
  source "$f"
}

# === unified runtime loader for interactive shells ===
load_runtime_env() {
  # 1) provider/session env persisted by autorun
  source_if_exists "/root/.secrets/env.current"

  # 2) project env + helpers (if not already loaded)
  source_if_exists "/workspace/comfyui-mirror/.env"
  source_if_exists "/workspace/comfyui-mirror/helpers.sh"

  # 3) sane defaults
  export COMFY_HOME="${COMFY_HOME:-/workspace/ComfyUI}"

  if [[ "${1:-}" == "--summary" ]]; then
    echo "--- runtime environment ---"
    printf '%-20s = %s\n' "COMFY_HOME" "$COMFY_HOME"
    [[ -n "${GPU_ARCH:-}" ]] && printf '%-20s = %s\n' "GPU_ARCH" "$GPU_ARCH"
    [[ -n "${GPU_NAME:-}" ]] && printf '%-20s = %s\n' "GPU_NAME" "$GPU_NAME"
    echo "---------------------------"
  fi
}

save_session_env() {
  local SECRET_DIR="/root/.secrets"
  local SESSION_ENV="${SECRET_DIR}/env.current"
  mkdir -p "$SECRET_DIR"; chmod 700 "$SECRET_DIR"; umask 077
  local VARS=(  HF_TOKEN CIVITAI_TOKEN LORAS_IDS_TO_DOWNLOAD CHECKPOINT_IDS_TO_DOWNLOAD PUSH_SAGE_BUNDLE PUSH_CUSTOM_BUNDLE TORCH_CHANNEL TORCH_CUDA TORCH_STABLE_VER TORCH_NIGHTLY_VER HF_REPO HF_REPO_TYPE HF_REMOTE_URL COMFY_HOME CACHE_DIR GPU_ARCH GPU_NAME)
  { echo "# Autogenerated $(date -Is)"; for k in "${VARS[@]}"; do v="${!k:-}"; [[ -n "$v" ]] && printf 'export %s=%q\n' "$k" "$v"; done; } > "$SESSION_ENV"
  echo "[save_session_env] Saved: $SESSION_ENV"
}

use_session_env() {
  local f="${1:-/root/.secrets/env.current}"
  [[ -f "$f" ]] || { echo "[use_session_env] No env file at $f"; return 1; }
  # shellcheck disable=SC1090
  source "$f"
  echo "[use_session_env] Loaded env from $f"
}

# --- End of personal aliases/functions ---

# Make sure mouse wheel behaves

bind -r "\e[A"
bind -r "\e[B"

# Try to line up this shell with the running job
load_runtime_env 2>/dev/null || true

# handy aliases
alias mirror='/workspace/mirror'
alias rebase='/workspace/rebase'

export PATH="/workspace:$PATH"
