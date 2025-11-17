# ~/.bash_functions - shared helpers for Vast pod shells

# Safely source a file if it exists
source_if_exists() {
  local f="$1"
  [[ -f "$f" ]] && # shellcheck disable=SC1090
  . "$f"
}

# Load the "runtime env" so an SSH shell matches the autorun context
load_runtime_env() {
  
  secrets="/root/.secrets/env.current"

  # Tokens & session env
  source_if_exists "$secrets"

  # ComfyUI repo env + helpers
  source_if_exists "$repo_root/.env"
  source_if_exists "$repo_root/helpers.sh"

  # If helpers defined some higher-level summaries, show them briefly
  if type -t auto_channel_detect >/dev/null 2>&1; then
    auto_channel_detect || true
  fi
  if type -t show_env_summary >/dev/null 2>&1; then
    show_env_summary || true
  fi
}

# Quick Git identity helper (does NOT run automatically)
git_identity() {
  cat <<'EOF'
git_identity usage:

  # One-time global setup:
  git config --global user.name  "Mark Richards"
  git config --global user.email "mark.david.richards@gmail.com"

  # Optional per-repo override (run inside repo):
  git config user.name  "Mark Richards"
  git config user.email "mark.david.richards@pgmail.com"

Current effective Git identity:
EOF
  git config --global user.name  2>/dev/null | sed 's/^/  global name:  /'  || true
  git config --global user.email 2>/dev/null | sed 's/^/  global email: /'   || true
}

# Small helper: show current git branch + status in a compact way
git_prompt_info() {
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local branch dirty mark
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  if ! git diff --quiet --ignore-submodules -- 2>/dev/null; then
    dirty='*'
  else
    dirty=''
  fi
  printf '(%s%s)' "$branch" "$dirty"
}

# Example: if you ever want to add git info to PS1, you can drop this
# into .bashrc after PS1 is set:
#   PS1="${PS1%\$ } \$(git_prompt_info) \$ "
#
# For now, we leave your PS1 unchanged to keep the current simple style.
