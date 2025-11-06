# ── Git QoL Pack (aliases + prompt + completion) ──

# Only for interactive shells
[[ $- != *i* ]] && return

# Colors
if tput setaf 1 &>/dev/null; then
  RESET="$(tput sgr0)"; BOLD="$(tput bold)"
  FG_G="$(tput setaf 2)"; FG_B="$(tput setaf 4)"; FG_Y="$(tput setaf 3)"
  FG_R="$(tput setaf 1)"; FG_M="$(tput setaf 5)"; FG_C="$(tput setaf 6)"; FG_W="$(tput setaf 7)"
else
  RESET="\e[0m"; BOLD="\e[1m"
  FG_G="\e[32m"; FG_B="\e[34m"; FG_Y="\e[33m"; FG_R="\e[31m"
  FG_M="\e[35m"; FG_C="\e[36m"; FG_W="\e[37m"
fi

# bash-completion (incl. git)
for f in /usr/share/bash-completion/bash_completion /etc/bash_completion; do
  [[ -r "$f" ]] && source "$f" && break
done

# git completion/prompt (best-effort)
for f in \
  /usr/share/bash-completion/completions/git \
  /usr/share/git/completion/git-completion.bash \
  /etc/bash_completion.d/git \
  /opt/homebrew/etc/bash_completion.d/git-completion.bash \
  /usr/local/etc/bash_completion.d/git-completion.bash; do
  [[ -r "$f" ]] && source "$f" && break
done
for f in \
  /usr/share/git/completion/git-prompt.sh \
  /opt/homebrew/etc/bash_completion.d/git-prompt.sh \
  /usr/local/etc/bash_completion.d/git-prompt.sh; do
  [[ -r "$f" ]] && source "$f" && break
done

# Fallback __git_ps1 if not provided
if ! declare -F __git_ps1 &>/dev/null; then
  __git_ps1() {
    git rev-parse --is-inside-work-tree &>/dev/null || return 0
    local b a u dirty stashcount ahead behind ab
    b="$(git symbolic-ref --short -q HEAD 2>/dev/null || git describe --tags --always 2>/dev/null)"
    a=0; u=0
    if git rev-parse --abbrev-ref @{u} &>/dev/null; then
      ab="$(git rev-list --left-right --count HEAD...@{u} 2>/dev/null)"
      a="${ab%%	*}"; u="${ab##*	}"
    fi
    dirty=""
    git diff --quiet --ignore-submodules --cached || dirty="*"
    git diff --quiet --ignore-submodules || dirty="*"
    stashcount="$(git rev-list --walk-reflogs --count refs/stash 2>/dev/null || echo 0)"
    [[ "$a" -gt 0 ]] && ahead="↑$a" || ahead=""
    [[ "$u" -gt 0 ]] && behind="↓$u" || behind=""
    local abtxt=""; [[ -n "$ahead$behind" ]] && abtxt="$ahead$behind"
    local stashtxt=""; [[ "$stashcount" -gt 0 ]] && stashtxt="|$stashcount"
    printf " (%s%s%s%s)" "$b" "$abtxt" "$dirty" "$stashtxt"
  }
fi

export GIT_PS1_SHOWUPSTREAM=auto
export GIT_PS1_SHOWDIRTYSTATE=1
export GIT_PS1_SHOWSTASHSTATE=1
export GIT_PS1_SHOWUNTRACKEDFILES=1

# --- Multi-line Git prompt ---------------------------------------------
#_PROMPT_GIT() { __git_ps1; }
#PS1="\n${BOLD}${FG_B}\u@\h${RESET} ${FG_C}\w${RESET}${FG_Y}\$(_PROMPT_GIT)${RESET}\n\$ "

# ─── Single-line Git prompt ────────────────────────────────────────────
_PROMPT_GIT() { __git_ps1; }

# Colors
if tput setaf 1 &>/dev/null; then
  RESET="$(tput sgr0)"; BOLD="$(tput bold)"
  FG_B="$(tput setaf 4)"   # blue for user@host
  FG_C="$(tput setaf 6)"   # cyan for path
  FG_Y="$(tput setaf 3)"   # yellow for git info
else
  RESET="\e[0m"; BOLD="\e[1m"
  FG_B="\e[34m"; FG_C="\e[36m"; FG_Y="\e[33m"
fi

# Compact single-line prompt
PS1="${BOLD}${FG_B}\u@\h${RESET}:${FG_C}\w${RESET}${FG_Y}\$(_PROMPT_GIT)${RESET} \$ "

# Confirm helper
_confirm() { read -r -p "${1:-Are you sure?} [y/N] " ans; [[ "$ans" == [yY] ]]; }

# Aliases
alias g='git'
alias gs='git status -sb'
alias ga='git add'; alias gaa='git add -A'
alias gb='git branch -vv'
alias gco='git checkout'; alias gcb='git checkout -b'
alias gc='git commit -v'; alias gca='git commit -v -a'; alias gcm='git commit -am'
alias gd='git diff'; alias gdc='git diff --cached'
alias gl='git log --oneline --decorate --graph --all'
alias gll='git log --stat -p --decorate'
alias gshow='git show --stat'
alias gpr='git pull --rebase --autostash'
alias gp='git push'; alias gpf='git push --force-with-lease'
alias gcl='git clone'; alias gmv='git mv'; alias grm='git rm'
alias gtag='git tag -n'
alias gfetch='git fetch -p'
alias gsr='git submodule update --init --recursive'
alias gprune='git fetch -p'

# Functions (POSIX-safe definition style)
gclean() { _confirm "Remove ALL untracked files/dirs (git clean -fdx)?" && git clean -fdx; }
gbclean() {
  local main_branch
  main_branch="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo main)"
  git branch --merged | grep -vE "^\*|${main_branch}|main|master" | xargs -r git branch -d
}
gbdelr() { [ -n "$1" ] && git push origin --delete "$1"; }
gsummary() {
  echo -e "${BOLD}${FG_W}Branch:${RESET} $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
  echo; git status -sb; echo; git log --oneline -5
}
gfile() { git log -p -1 -- "$@"; }
gfind() { git grep -n --full-name "$@"; }
gundo() { git reset --soft HEAD~1; }
gamendmsg() { git commit --amend -m "${*:-fixups}"; }
gfix() { git add -A && git commit --amend --no-edit; }
gwip() { git add -A && git commit -m "WIP: $(date +%F-%T)"; }
grb() { git for-each-ref --count="${1:-10}" --sort=-committerdate refs/heads --format='%(refname:short)'; }
glg() { git log --oneline --graph --decorate --all | grep -E "${1:-.}"; }
gout() { git rev-parse --abbrev-ref @{u} &>/dev/null || { echo "No upstream set."; return 1; }; git log --oneline --decorate --graph @{u}..HEAD; }
gdefaults() {
  git config --global pull.rebase true
  git config --global rebase.autoStash true
  git config --global push.default simple
  git config --global fetch.prune true
  git config --global init.defaultBranch main
  echo "Global Git defaults applied."
}
greword() {
  local n="${1:-3}"
  GIT_SEQUENCE_EDITOR="sed -i -e '1,${n}s/^pick/reword/'" git rebase -i HEAD~"$n"
}
gsquash() {
  local n="${1:-2}"
  GIT_SEQUENCE_EDITOR="sed -i -e '2,${n}s/^pick/squash/'" git rebase -i HEAD~"$n"
}
gfp() { local cur; cur="$(git rev-parse --abbrev-ref HEAD)"; git push --force-with-lease origin "$cur"; }
gbrowse() {
  local url; url="$(git config --get remote.origin.url | sed -E 's#^git@([^:]+):#https://\1/#; s#\.git$##')"
  [ -z "$url" ] && { echo "No origin remote."; return 1; }
  if command -v xdg-open >/dev/null; then xdg-open "$url"
  elif command -v open >/dev/null; then open "$url"
  else echo "$url"
  fi
}

# Git check: see local + remote differences and file changes
gck() {
  echo "🔍 Checking repo status..."
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "❌ Not a git repository."; return 1; }

  # Fetch latest info from remote
  git fetch origin >/dev/null 2>&1 || { echo "⚠️  Couldn't fetch from remote."; return 1; }

  local LOCAL=$(git rev-parse @ 2>/dev/null)
  local REMOTE=$(git rev-parse @{u} 2>/dev/null || echo "")
  local BASE=$(git merge-base @ @{u} 2>/dev/null || echo "")
  local changed=0

  # --- 1. Local uncommitted changes ---
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "🧩 You have local uncommitted changes:"
    git status -s
    echo
    changed=1
  fi

  # --- 2. Check for remote updates ---
  if [ -z "$REMOTE" ]; then
    echo "⚠️  No upstream branch set. Use: git push -u origin main"
    return 1
  fi

  if [ "$LOCAL" = "$REMOTE" ]; then
    echo "✅ Up to date with remote."
  elif [ "$LOCAL" = "$BASE" ]; then
    echo "⬇️  Remote has new commits you don't have. Files changed since your last pull:"
    git diff --stat $LOCAL..$REMOTE
    changed=1
  elif [ "$REMOTE" = "$BASE" ]; then
    echo "⬆️  You have local commits not pushed yet:"
    git log --oneline @{u}..@
    changed=1
  else
    echo "⚠️  Local and remote have diverged (both changed). You’ll need to pull/rebase carefully."
    changed=1
  fi

  # --- 3. Summary ---
  echo
  if [ "$changed" -eq 0 ]; then
    echo "✨ Everything clean and up to date!"
  else
    echo "📋 Summary: some changes detected — review above before pulling."
  fi
}

# Simple confirm helper (reuse if you already have one)
_confirm() {
  read -r -p "${1:-Are you sure?} [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# gup: update (pull --rebase) with safety checks
# Usage:
#   gup          # pulls/rebases if needed
#   gup more     # pulls + then shows short “what changed” summary
gup() {
  local show_more=0
  [[ "$1" == "more" ]] && show_more=1

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "❌ Not a git repo."; return 1; }

  # Refresh knowledge of remote
  git fetch origin >/dev/null 2>&1 || { echo "⚠️ Unable to fetch remote."; return 1; }

  # Snapshot state
  local LOCAL REMOTE BASE
  LOCAL=$(git rev-parse @ 2>/dev/null) || return 1
  REMOTE=$(git rev-parse @{u} 2>/dev/null || echo "")
  BASE=$(git merge-base @ @{u} 2>/dev/null || echo "")

  if [[ -z "$REMOTE" ]]; then
    echo "⚠️  No upstream set. First time push:"
    echo "    git push -u origin $(git rev-parse --abbrev-ref HEAD)"
    return 1
  fi

  # Detect local un/staged edits (these will be autostashed, but warn anyway)
  local has_local_edits=0
  if ! git diff --quiet || ! git diff --cached --quiet; then
    has_local_edits=1
    echo "🧩 Local uncommitted changes detected:"
    git status -s
    echo
  fi

  # Decide situation
  if [[ "$LOCAL" == "$REMOTE" ]]; then
    echo "✅ Already up to date."
    return 0
  elif [[ "$LOCAL" == "$BASE" ]]; then
    echo "⬇️  Remote has new commits (fast-forward)."
    # Safe; optional confirm only if local edits present
    if (( has_local_edits )); then
      _confirm "Proceed with pull (your uncommitted changes will be autostashed)?" || { echo "Canceled."; return 1; }
    fi
  elif [[ "$REMOTE" == "$BASE" ]]; then
    echo "⬆️  You are ahead (local commits not pushed). No pull needed."
    return 0
  else
    echo "⚠️  Diverged: both you and remote have commits."
    echo "    A rebase will rewrite your local commits on top of remote."
    git log --oneline --decorate --graph --boundary @{u}..@ 2>/dev/null | sed 's/^/  local: /'
    git log --oneline --decorate --graph --boundary @..@{u} 2>/dev/null | sed 's/^/  remote: /'
    echo
    _confirm "Rebase your local commits onto the updated upstream now?" || { echo "Canceled."; return 1; }
  fi

  # Do the pull (rebase + autostash)
  local BEFORE AFTER
  BEFORE=$(git rev-parse HEAD)
  echo "⬇️  Pulling (rebase + autostash)…"
  if ! git pull --rebase --autostash; then
    echo "❌ Pull/rebase failed. Resolve conflicts, then:  git rebase --continue"
    echo "   Or abort with:                               git rebase --abort"
    return 1
  fi
  AFTER=$(git rev-parse HEAD)

  # Optional “more” report
  if (( show_more )); then
    if [[ "$BEFORE" != "$AFTER" ]]; then
      echo
      echo "📦 Updated to: $(git rev-parse --short HEAD)"
      echo "📝 Commits pulled:"
      git log --oneline --decorate "${BEFORE}..${AFTER}"
      echo
      echo "📊 File changes (diffstat):"
      git diff --stat --color "${BEFORE}..${AFTER}"
    else
      echo "ℹ️  No changes applied by pull."
    fi
  fi
}

