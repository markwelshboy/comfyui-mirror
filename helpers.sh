#!/usr/bin/env bash
# ======================================================================
# helpers.sh — Golden edition
#   - No hardcoded /workspace paths (respects COMFY_HOME/CACHE_DIR/etc.)
#   - Minimal, consistent Hugging Face vars (HF_REPO_ID, HF_REPO_TYPE, HF_TOKEN, CN_BRANCH)
#   - Clear function groups with docs
#   - Safe, idempotent, parallel node installation
#   - Bundle pull-or-build logic keyed by CUSTOM_NODES_BUNDLE_TAG + PINS
# ======================================================================

# ----------------------------------------------------------------------
# Guard: avoid double-sourcing
# ----------------------------------------------------------------------
#if [[ -n "${HELPERS_SH_LOADED:-}" ]]; then
#  return 0 2>/dev/null || exit 0
#fi
#HELPERS_SH_LOADED=0
shopt -s extglob

# ----------------------------------------------------------------------
# Expected environment (usually set in .env)
# ----------------------------------------------------------------------
# Required (paths):
#   COMFY_HOME           - e.g. /workspace/ComfyUI
#   CUSTOM_DIR           - usually "$COMFY_HOME/custom_nodes"
#   CACHE_DIR            - e.g. "$COMFY_HOME/cache"
#   CUSTOM_LOG_DIR       - e.g. "$COMFY_HOME/logs/custom_nodes"
#   BUNDLES_DIR          - e.g. "$COMFY_HOME/bundles"
# Required (python):
#   PY, PIP              - venv python/pip
# Optional (misc tooling):
#   COMFY_REPO_URL       - ComfyUI repo URL (default comfyanonymous/ComfyUI)
#   GIT_DEPTH            - default 1
#   MAX_NODE_JOBS        - default 6..8
# Hugging Face:
#   HF_REPO_ID           - e.g. user/comfyui-bundles
#   HF_REPO_TYPE         - dataset | model (default dataset)
#   HF_TOKEN             - auth token
#   CN_BRANCH            - default main
#   HF_API_BASE          - default https://huggingface.co
#   CUSTOM_NODES_BUNDLE_TAG           - logical “set” name (e.g. WAN2122_Baseline)
# Pins/signature:
#   PINS                 - computed by pins_signature() if not set

# Provide reasonable fallbacks if .env forgot any
: "${COMFY_REPO_URL:=https://github.com/comfyanonymous/ComfyUI}"
: "${GIT_DEPTH:=1}"
: "${MAX_NODE_JOBS:=8}"
: "${HF_API_BASE:=https://huggingface.co}"
: "${CN_BRANCH:=main}"
: "${CACHE_DIR:=${COMFY_HOME:-/tmp}/cache}"
: "${CUSTOM_LOG_DIR:=${COMFY_HOME:-/tmp}/logs/custom_nodes}"
: "${BUNDLES_DIR:=${COMFY_HOME:-/tmp}/bundles}"

PY_BIN="${PY:-/opt/venv/bin/python}"
PIP_BIN="${PIP:-/opt/venv/bin/pip}"

# ---------- .env loader (optional) ----------
helpers_load_dotenv() {
  local file="${1:-.env}"
  [ -f "$file" ] || return 0
  # export all non-comment lines
  set -a
  # shellcheck disable=SC1090
  . "$file"
  set +a
}

# ------------------------- #
#  Logging & guard helpers  #
# ------------------------- #

# log MSG
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }

# die MSG
die(){ echo "FATAL: $*" >&2; exit 1; }

# ensure CMD exists or die
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing tool: $1"; }

# -------------------------- #
#  System package helpers    #
# -------------------------- #

ensure_base_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends              \
    aria2 ffmpeg                                          \
    ninja-build build-essential cmake gcc g++             \
    libgl1 libglib2.0-0 pkg-config                        \
    python3.12 python3.12-venv python3.12-dev python3-pip \
    jq git-lfs                                            \
    ca-certificates unzip tmux gawk nano coreutils        \
    net-tools ncurses-base bash-completion
  git lfs install --system || true

}

# -------------------------- #
#  Path + directory helpers  #
# -------------------------- #

ensure_dirs(){
  mkdir -p \
    "${COMFY_HOME:?}" \
    "${CUSTOM_DIR:?}" \
    "${CUSTOM_LOG_DIR:?}" \
    "${OUTPUT_DIR:?}" \
    "${CACHE_DIR:?}" \
    "${BUNDLES_DIR:?}" \
    "${COMFY_LOGS:?}"

  mkdir -p \
    "${MODELS_DIR:-${COMFY_HOME}/models}" \
    "${CHECKPOINTS_DIR:?}" \
    "${DIFFUSION_MODELS_DIR:?}" \
    "${TEXT_ENCODERS_DIR:?}" \
    "${CLIP_VISION_DIR:?}" \
    "${VAE_DIR:?}" \
    "${LORAS_DIR:?}" \
    "${DETECTION_DIR:?}" \
    "${CTRL_DIR:?}" \
    "${UPSCALE_DIR:?}"

}

# ------------------------- #
#  Workflows / Icons import #
# ------------------------- #
copy_hearmeman_assets_if_any(){
  local repo="${HEARMEMAN_REPO:-}"
  if [ -z "$repo" ]; then return 0; fi
  local tmp="${CACHE_DIR}/.hearmeman.$$"
  rm -rf "$tmp"
  git clone "$repo" "$tmp" || return 0
  # Workflows
  if [ -d "$tmp/src/workflows" ]; then
    mkdir -p "${COMFY_HOME}/workflows"
    cp -rf "$tmp/src/workflows/"* "${COMFY_HOME}/workflows/" || true
  fi
  # Icons / scripts (e.g., start.sh images)
  if [ -d "$tmp/src/assets" ]; then
    mkdir -p "${COMFY_HOME}/assets"
    cp -rf "$tmp/src/assets/"* "${COMFY_HOME}/assets/" || true
  fi
  rm -rf "$tmp"
}

# ======================================================================
# Generic utilities
# ======================================================================

# tg: Telegram notify (best-effort)
tg() {
  if [ -n "${TELEGRAM_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=$1" >/dev/null || true
  fi
}

# ======================================================================
# ComfyUI core management
# ======================================================================

# ensure_comfy: Install or hard-reset ComfyUI at COMFY_HOME
ensure_comfy() {
  if [[ -d "$COMFY_HOME/.git" && -f "$COMFY_HOME/main.py" ]]; then
    git -C "$COMFY_HOME" fetch --depth=1 origin || true
    git -C "$COMFY_HOME" reset --hard origin/master 2>/dev/null \
      || git -C "$COMFY_HOME" reset --hard origin/main 2>/dev/null || true
  else
    rm -rf "$COMFY_HOME"
    git clone --depth=1 "$COMFY_REPO_URL" "$COMFY_HOME"
  fi

  "$PIP_BIN" install -U pip wheel setuptools
  [ -f "$COMFY_HOME/requirements.txt" ] && "$PIP_BIN" install -r "$COMFY_HOME/requirements.txt" || true
  ln -sfn "$COMFY_HOME" /ComfyUI
}

# ======================================================================
# OpenCV Cleanup / "Pin" Numeric Stack
# ======================================================================

# Remove stray OpenCV wheels and cv2 dirs to avoid namespace collisions.
cleanup_opencv_namespace() {
  echo "[numeric-cleanup] Cleaning up legacy OpenCV wheels and cv2 namespace…" >&2

  # 1) Uninstall common OpenCV wheels quietly (ignore errors)
  env -u PIP_REQUIRE_HASHES -u PIP_CONSTRAINT \
    "$PIP" uninstall -y \
      opencv-python \
      opencv-python-headless \
      opencv-contrib-python \
      opencv-contrib-python-headless >/dev/null 2>&1 || true

  # 2) Remove dangling cv2 dirs/files from site-packages
  "$PY" - <<'PY'
import sys, os, glob, shutil

site = [p for p in sys.path if p.endswith("site-packages")]
if not site:
    print("[numeric-cleanup] No site-packages found; skipping cv2 cleanup.")
else:
    site = site[0]
    paths = [os.path.join(site, "cv2")] + glob.glob(os.path.join(site, "cv2*"))
    for p in paths:
        try:
            if os.path.isdir(p):
                shutil.rmtree(p, ignore_errors=True)
                print("[numeric-cleanup] Removed dir:", p)
            elif os.path.isfile(p):
                os.remove(p)
                print("[numeric-cleanup] Removed file:", p)
        except Exception as e:
            print("[numeric-cleanup] Skip:", p, "->", e)
PY
}

# Install and verify the pinned numeric stack (numpy / cupy / opencv).
# Uses NUMPY_VER / CUPY_VER / OPENCV_VER from .env as single source of truth.
lock_in_numeric_stack() {
  echo "[numeric-stack] Pinning numeric stack…" >&2
  echo "[numeric-stack]  NUMPY_VER  = ${NUMPY_VER:-<unset>}" >&2
  echo "[numeric-stack]  CUPY_VER   = ${CUPY_VER:-<unset>}" >&2
  echo "[numeric-stack]  OPENCV_VER = ${OPENCV_VER:-<unset>}" >&2
  echo ""
  echo "[numeric-stack] pins_signature: $(pins_signature 2>/dev/null || echo '<n/a>')" >&2

  # Safety: make sure we actually have pins
  if [[ -z "${NUMPY_VER:-}" || -z "${CUPY_VER:-}" || -z "${OPENCV_VER:-}" ]]; then
    echo "[numeric-stack] FATAL: NUMPY_VER/CUPY_VER/OPENCV_VER must be set in .env" >&2
    return 1
  fi

  # We *want* these to be authoritative, so ignore any global constraints/hashes.
  env -u PIP_REQUIRE_HASHES -u PIP_CONSTRAINT \
    "$PIP" install -U \
      "$NUMPY_VER" \
      "$CUPY_VER" \
      "$OPENCV_VER"

  # Quick sanity check and version report
  "$PY" - <<'PY'
import sys

print("[numeric-stack] Python:", sys.version.split()[0])

try:
    import numpy
    print("[numeric-stack] numpy :", numpy.__version__)
except Exception as e:
    print("[numeric-stack] numpy ERROR:", repr(e))

try:
    import cupy
    print("[numeric-stack] cupy  :", cupy.__version__)
except Exception as e:
    print("[numeric-stack] cupy ERROR:", repr(e))

try:
    import cv2
    v = getattr(cv2, "__version__", None)
    if v is None and hasattr(cv2, "cv2"):
        v = getattr(cv2.cv2, "__version__", "<unknown>")
    print("[numeric-stack] opencv:", v)
except Exception as e:
    print("[numeric-stack] opencv ERROR:", repr(e))
PY
}

# ======================================================================
# Custom node installation (parallel + cache)
# ======================================================================

# pins_signature: Build an identifier from numpy/cupy/opencv versions
pins_signature() {
  "$PY_BIN" - <<'PY'
import importlib, re
def v(mod, attr="__version__"):
    try:
        m = importlib.import_module(mod)
        return getattr(m, attr, "0.0.0")
    except Exception:
        return "0.0.0"

np = v("numpy")
cp = v("cupy")
try:
    import cv2 as _cv
    cv = getattr(_cv, "__version__", "0.0.0")
    if not isinstance(cv, str):
        cv = "0.0.0"
except Exception:
    cv = "0.0.0"

norm = lambda s: re.sub(r'[^0-9\.]+','-',s).replace('.','d')
print(f"np{norm(np)}_cupy{norm(cp)}_cv{norm(cv)}")
PY
}

# python_abi_tag: returns e.g. "312" for CPython 3.12
python_abi_tag() {
  "$PY" - << 'PY'
import sys
print(f"{sys.version_info.major}{sys.version_info.minor}")
PY
}

# pip_cache_key: combine ABI + pins_signature
pip_cache_key() {
  local abi sig
  abi="$(python_abi_tag)"
  sig="$(pins_signature)"
  echo "py${abi}_${sig}"
}

# bundle_ts: Sorting-friendly timestamp
bundle_ts() { date +%Y%m%d-%H%M; }

# bundle_base: Canonical bundle base name (without extension)
#   $1 tag, $2 pins, [$3 ts]
bundle_base() {
  local tag="${1:?tag}" pins="${2:?pins}" ts="${3:-$(bundle_ts)}"
  echo "custom_nodes_bundle_${tag}_${pins}_${ts}"
}

# Name helpers
manifest_name()   { echo "custom_nodes_manifest_${1:?tag}.json"; }
reqs_name()       { echo "consolidated_requirements_${1:?tag}.txt"; }
sha_name()        { echo "${1}.sha256"; }

# repo_dir_name: Stable dir name from repo URL
repo_dir_name() { basename "${1%.git}"; }

# needs_recursive: mark repos that need --recursive based on env config
# CUSTOM_NODES_RECURSIVE_REPOS is a space-separated list of substrings.
needs_recursive() {
  local repo_name="$1"
  local patterns="${CUSTOM_NODES_RECURSIVE_REPOS:-}"

  for pat in $patterns; do
    [[ -n "$pat" && "$repo_name" == *"$pat"* ]] && {
      echo "true"
      return 0
    }
  done

  echo "false"
}

# clone_or_pull: shallow clone or fast-forward reset
clone_or_pull() {
  local repo="$1" dst="$2" recursive="$3"
  if [[ -d "$dst/.git" ]]; then
    git -C "$dst" fetch --all --prune --tags --depth="${GIT_DEPTH}" || true
    git -C "$dst" reset --hard origin/main 2>/dev/null \
      || git -C "$dst" reset --hard origin/master 2>/dev/null || true
  else
    mkdir -p "$(dirname "$dst")"
    if [[ "$recursive" == "true" ]]; then
      git clone --recursive ${GIT_DEPTH:+--depth "$GIT_DEPTH"} "$repo" "$dst"
    else
      git clone ${GIT_DEPTH:+--depth "$GIT_DEPTH"} "$repo" "$dst"
    fi
  fi
}

# build_node: per-node requirements + install.py (logs to CUSTOM_LOG_DIR)
build_node() {
  local dst="${1:?dst}"
  local name log
  name="$(basename "$dst")"
  log="${CUSTOM_LOG_DIR}/${name}.log"
  {
    echo "==> [$name] $(date -Is) start"
    if [[ -f "$dst/requirements.txt" ]]; then
      "$PIP_BIN" install --no-cache-dir -r "$dst/requirements.txt" || true
    fi
    if [[ -f "$dst/install.py" ]]; then
      "$PY_BIN" "$dst/install.py" || true
    fi
    echo "==> [$name] $(date -Is) done"
  } >"$log" 2>&1
}

# resolve_nodes_list: Resolve source of truth for repo URLs into an array name
#   Usage: local -a nodes; resolve_nodes_list nodes
# resolve_nodes_list OUT_ARRAY_NAME
resolve_nodes_list() {
  local out_name="${1:-}"
  local -a out=()
  if [[ -n "${CUSTOM_NODE_LIST_FILE:-}" && -s "${CUSTOM_NODE_LIST_FILE:-}" ]]; then
    mapfile -t out < <(grep -vE '^\s*(#|$)' "$CUSTOM_NODE_LIST_FILE")
  elif [[ -n "${CUSTOM_NODE_LIST:-}" ]]; then
    # shellcheck disable=SC2206
    out=(${CUSTOM_NODE_LIST})
  else
    out=("${DEFAULT_NODES[@]}")
  fi

  # Return via nameref or print
  if [[ -n "$out_name" ]]; then
    local -n ref="$out_name"
    ref=("${out[@]}")
  else
    printf '%s\n' "${out[@]}"
  fi
}

# rewrite_custom_nodes_requirements:
#   - in:  original consolidated requirements (from HF)
#   - out: rewritten file we actually feed to pip
# Uses CUSTOM_NODES_REQ_REWRITE_*="pkg|replacement" from .env.
rewrite_custom_nodes_requirements() {
  local in="$1"
  local out="$2"

  if [[ ! -f "$in" ]]; then
    echo "[custom-nodes] rewrite_custom_nodes_requirements: input missing: $in" >&2
    return 1
  fi

  rm -f "$out"
  \cp "$in" "$out"

  # Walk all env vars prefixed with CUSTOM_NODES_REQ_REWRITE_
  local var spec pkg repl
  for var in ${!CUSTOM_NODES_REQ_REWRITE_@}; do
    spec="${!var}"
    [[ -z "$spec" ]] && continue

    IFS='|' read -r pkg repl <<<"$spec"
    pkg="${pkg// /}"   # strip spaces
    [[ -z "$pkg" ]] && continue

    # Drop any line whose first token matches pkg
    sed -i -E "/^${pkg}(\s|$)/d" "$out"

    # If replacement begins with "#", we just drop it and move on
    if [[ "$repl" == "#"* || -z "$repl" ]]; then
      echo "[custom-nodes] rewrite: removed '${pkg}' with no replacement (rule: ${var})"
      continue
    fi

    # Append replacement line at end
    echo "$repl" >>"$out"
    echo "[custom-nodes] rewrite: replaced '${pkg}' -> '${repl}' (rule: ${var})"
  done
}

# install_custom_nodes_set: bounded parallel installer (wait -n throttle, no FIFOs)
#   Usage: install_custom_nodes_set NODES_ARRAY_NAME
install_custom_nodes_set() {
  local src_name="${1:-}"
  local -a NODES_LIST
  if [[ -n "$src_name" ]]; then
    local -n _src="$src_name"
    NODES_LIST=("${_src[@]}")
  else
    resolve_nodes_list NODES_LIST
  fi

  echo "[custom-nodes] Installing custom nodes. Processing ${#NODES_LIST[@]} node(s)"
  mkdir -p "${CUSTOM_DIR:?}" "${CUSTOM_LOG_DIR:?}"

  # Concurrency
  local max_jobs="${MAX_NODE_JOBS:-8}"
  if ! [[ "$max_jobs" =~ ^[0-9]+$ ]] || (( max_jobs < 1 )); then max_jobs=8; fi
  echo "[custom-nodes] Using concurrency: ${max_jobs}"

  # Harden git so it never prompts (prompts can look like a 'hang')
  export GIT_TERMINAL_PROMPT=0
  export GIT_ASKPASS=/bin/echo

  local running=0
  local errs=0
  local -a pids=()

  for repo in "${NODES_LIST[@]}"; do
    [[ -n "$repo" ]] || continue
    [[ "$repo" =~ ^# ]] && continue

    # If we're at the limit, wait for one job to finish
    if (( running >= max_jobs )); then
      if ! wait -n; then errs=$((errs+1)); fi
      running=$((running-1))
    fi

    (
      set -e
      name="$(repo_dir_name "$repo")"
      dst="$CUSTOM_DIR/$name"
      rec="$(needs_recursive "$repo")"

      echo "[custom-nodes] Starting install: $name → $dst"
      mkdir -p "$dst"

      clone_or_pull "$repo" "$dst" "$rec"

      if ! build_node "$dst"; then
        echo "[custom-nodes] ❌ Install ERROR $name (see ${CUSTOM_LOG_DIR}/${name}.log)"
        exit 1
      fi

      echo "[custom-nodes] ✅ Completed install for: $name"
    ) &

    pids+=("$!")
    running=$((running+1))
  done

  echo "[custom-nodes] Waiting for parallel node installs to complete…"
  # Wait for remaining jobs
  while (( running > 0 )); do
    if ! wait -n; then errs=$((errs+1)); fi
    running=$((running-1))
  done

  if (( errs > 0 )); then
    echo "[custom-nodes] ❌ Completed with ${errs} error(s). Check logs: $CUSTOM_LOG_DIR"
    return 2
  else
    echo "[custom-nodes] ✅ All nodes installed successfully."
  fi
}

# ======================================================================
# HF Bundling (create/push/pull)
# ======================================================================

hf_ensure_local_repo() {
  local repo="${HF_LOCAL_REPO:-${CACHE_DIR}/.hf_repo}"
  local url

  url="$(hf_remote_url 2>/dev/null || true)"
  if [[ -z "$url" ]]; then
    echo "[hf-local-repo] hf_ensure_local_repo: hf_remote_url unresolved" >&2
    return 1
  fi

  mkdir -p "$(dirname "$repo")"

  if [[ -d "$repo/.git" ]]; then
    # Cheap refresh in case you’ve pushed new bundles
    git -C "$repo" fetch --depth=1 origin main >/dev/null 2>&1 || true
    git -C "$repo" reset --hard origin/main >/dev/null 2>&1 || true
  else
    echo "[hf-local-repo] Cloning HF repo once into $repo…" >&2
    git clone --depth=1 "$url" "$repo" >/dev/null 2>&1 || {
      echo "[hf-local-repo] ❌ Failed to clone HF repo into $repo" >&2
      return 1
    }
  fi

  echo "$repo"
}

# hf_remote_url: builds authenticated HTTPS remote for model/dataset repos
hf_remote_url() {
  : "${HF_TOKEN:?missing HF_TOKEN}" "${HF_REPO_ID:?missing HF_REPO_ID}"
  local base="${HF_API_BASE:-https://huggingface.co}"
  local type="${HF_REPO_TYPE:-dataset}"   # dataset or model
  local id="${HF_REPO_ID}"
  echo "https://oauth2:${HF_TOKEN}@${base#https://}/${type}s/${id}.git"
}

# hf_fetch_nodes_list: optionally fetch a custom_nodes.txt index from HF
#   echoes local path or empty if not present
hf_fetch_nodes_list() {
  local out="${CACHE_DIR}/custom_nodes.txt"
  mkdir -p "$CACHE_DIR"
  local url="${HF_API_BASE}/${HF_REPO_ID}/resolve/${CN_BRANCH}/custom_nodes.txt"
  if curl -fsSL -H "Authorization: Bearer ${HF_TOKEN:-}" "$url" -o "$out"; then
    echo "$out"
  else
    echo ""
  fi
}

# hf_push_files: stage tgz/sha/manifest/requirements into bundles/meta/requirements
hf_push_files() {
  local msg="${1:-update bundles}"; shift || true
  local files=( "$@" )
  local tmp="${CACHE_DIR}/.hf_push.$$"
  rm -rf "$tmp"
  git lfs install
  git clone "$(hf_remote_url)" "$tmp"
  ( cd "$tmp"
    git checkout "$CN_BRANCH" 2>/dev/null || git checkout -b "$CN_BRANCH"
    mkdir -p bundles meta requirements
    for f in "${files[@]}"; do
      case "$f" in
        *.tgz|*.sha256) cp -f "$f" bundles/ ;;
        *.json)         cp -f "$f" meta/ ;;
        *.txt)          cp -f "$f" requirements/ ;;
        *)              cp -f "$f" bundles/ ;;
      esac
    done
    git lfs track "bundles/*.tgz"
    git add .gitattributes bundles meta requirements
    git commit -m "$msg" || true
    git push origin "$CN_BRANCH"
  )
  rm -rf "$tmp"
}

# ================================================================
# Hugging Face dataset name helpers
# ================================================================
# Expect HF_REPO_ID like: markwelshboyx/hearmemanAI-comfyUI-workflows
# or can fall back to parsing HF_REMOTE_URL if defined

hf_dataset_namespace() {
  # Primary: HF_REPO_ID="namespace/name"
  if [[ -n "${HF_REPO_ID:-}" ]]; then
    echo "${HF_REPO_ID%%/*}"
    return 0
  fi

  # Fallback: if you ever add HF_REPO as an alias
  if [[ -n "${HF_REPO:-}" ]]; then
    echo "${HF_REPO%%/*}"
    return 0
  fi

  # Fallback: try parsing HF_REMOTE_URL if it exists
  if [[ -n "${HF_REMOTE_URL:-}" ]]; then
    local url ns
    url="${HF_REMOTE_URL%.git}"
    url="${url#https://}"
    ns="$(printf '%s\n' "$url" | awk -F/ '{print $(NF-1)}')"
    [[ -n "$ns" ]] && { echo "$ns"; return 0; }
  fi

  echo "unknown_ns"
}

hf_dataset_name() {
  if [[ -n "${HF_REPO_ID:-}" ]]; then
    echo "${HF_REPO_ID##*/}"
    return 0
  fi

  if [[ -n "${HF_REPO:-}" ]]; then
    echo "${HF_REPO##*/}"
    return 0
  fi

  if [[ -n "${HF_REMOTE_URL:-}" ]]; then
    local url name
    url="${HF_REMOTE_URL%.git}"
    name="$(printf '%s\n' "$url" | awk -F/ '{print $NF}')"
    [[ -n "$name" ]] && { echo "$name"; return 0; }
  fi

  echo "unknown_name"
}

_hf_api_base() {
  local base="${HF_API_BASE:-https://huggingface.co}"
  local type="${HF_REPO_TYPE:-dataset}"   # datasets or models
  local id="${HF_REPO_ID:-}"

  if [[ -z "$id" ]]; then
    # last resort, reconstruct from namespace+name
    id="$(hf_dataset_namespace)/$(hf_dataset_name)"
  fi

  echo "${base}/api/${type}s/${id}"
}

#---------------------------------------------------------------
#
#
# Torch and SageAttention helpers
#
#
#---------------------------------------------------------------

# Decide if a given custom-node bundle filename is "compatible"
# with the current environment (bundle tag + pins).
_custom_node_bundle_compatible() {
  local fname="${1:?bundle filename}"

  # Tag: e.g. Wan2_1__Wan2_2__CUDA_12_8
  local tag="${CUSTOM_NODES_BUNDLE_TAG:-${BUNDLE_TAG:-}}"

  # Pins: numeric stack signature; prefer PIN_SIG, else compute via pins_signature()
  local signature=""
  if command -v pins_signature >/dev/null 2>&1; then
    signature="$(pins_signature 2>/dev/null || true)"
  fi
  local pins="${PIN_SIG:-$signature}"

  # Require tag substring if we have one
  if [[ -n "$tag" && "$fname" != *"$tag"* ]]; then
    return 1
  fi

  # Require pins substring if we have them
  if [[ -n "$pins" && "$fname" != *"$pins"* ]]; then
    return 1
  fi

  return 0
}

hf_fetch_compatible_sage_bundle() {
  local key="${1:?SAGE_KEY}"

  local repo cuda_tag
  repo="$(hf_ensure_local_repo)" || {
    echo "[sage-bundle] hf_fetch_latest_custom_nodes_bundle: no local repo." >&2
    return 1
  }


  # Extract cuXXX_sm_YY part from our key (if present)
  cuda_tag="$(printf '%s\n' "$key" | sed -E 's/.*_(cu[0-9]+_sm_[0-9]+)$/\1/' || true)"
  if [[ -z "$cuda_tag" ]]; then
    echo "[sage-bundle] Cannot derive CUDA/arch suffix from key=${key}; skipping compatible search." >&2
    return 1
  fi

  local f base k compat_list
  compat_list=()

  if compgen -G "${repo}/bundles/torch_sage_bundle_*.tgz" >/dev/null 2>&1; then
    for f in "${repo}"/bundles/torch_sage_bundle_*.tgz; do
      [[ -e "$f" ]] || continue
      base="$(basename "$f" .tgz)"
      k="${base#torch_sage_bundle_}"
      [[ "$k" == *"${cuda_tag}" ]] || continue
      compat_list+=("$k")
    done
  fi

  if (( ${#compat_list[@]} == 0 )); then
    echo "[sage-bundle] No compatible Sage bundles found for CUDA/arch=${cuda_tag}." >&2
    return 1
  fi

  # Choose latest (lexicographically max) compatible key
  IFS=$'\n' compat_list_sorted=($(printf '%s\n' "${compat_list[@]}" | sort))
  unset IFS
  local best_key="${compat_list_sorted[-1]}"
  local best_file="torch_sage_bundle_${best_key}.tgz"
  echo "[sage-bundle] Reusing compatible Sage bundle: ${best_file}" >&2

  mkdir -p "$CACHE_DIR"
  cp "${repo}/bundles/$best_file" "$CACHE_DIR/"
  echo "${CACHE_DIR}/${best_file}"
}

hf_bundles_summary() {
  local key="${1:-}"               # optional: current torch_sage_key
  local cache="${CACHE_DIR:-/workspace/ComfyUI/cache}"

  mkdir -p "$cache"

  local repo
  repo="$(hf_ensure_local_repo)" || {
    echo "[sage-bundle] hf_fetch_latest_custom_nodes_bundle: no local repo." >&2
    return 1
  }

  echo "Bundles (local repo) : inspecting…"

  local bundle_dir="${repo}/bundles"
  if [[ ! -d "$bundle_dir" ]]; then
    echo "  Bundles dir  : (none)"
    return 0
  fi

  # Count all .tgz bundles
  local total
  total="$(find "$bundle_dir" -maxdepth 1 -type f -name '*.tgz' | wc -l | tr -d ' ')"
  echo "  Total .tgz   : ${total}"

  # Count custom_nodes vs torch_sage
  local cn_count sage_count
  cn_count="$(find "$bundle_dir" -maxdepth 1 -type f -name 'custom_nodes_bundle_*.tgz' | wc -l | tr -d ' ')"
  sage_count="$(find "$bundle_dir" -maxdepth 1 -type f -name 'torch_sage_bundle_*.tgz'   | wc -l | tr -d ' ')"
  echo "  custom_nodes : ${cn_count}"
  echo "  torch_sage   : ${sage_count}"

  # If a key was provided, check for that specific bundle
  if [[ -n "$key" ]]; then
    local patt="torch_sage_bundle_${key}.tgz"
    if [[ -f "${bundle_dir}/${patt}" ]]; then
      echo "  This key     : ✅ ${patt}"
    else
      echo "  This key     : ❌ no torch_sage bundle for ${key}"
    fi
  fi
}

hf_repo_info() {
  local ns name type url
  ns="$(hf_dataset_namespace)"
  name="$(hf_dataset_name)"
  type="${HF_REPO_TYPE:-dataset}"
  url="https://huggingface.co/${type}s/${ns}/${name}"

  echo "=================================================="
  echo "🤖 Hugging Face Repo Info"
  echo "Repo handle    : ${ns}/${name}"
  echo "Repo type      : ${type}"
  echo "Repo URL       : ${url}"
  echo -n "Auth check     : "

  if [[ -n "${HF_TOKEN:-}" ]]; then
    if curl -fsSL -H "Authorization: Bearer ${HF_TOKEN}" \
         "https://huggingface.co/api/${type}s/${ns}/${name}" \
         >/dev/null 2>&1; then
      echo "✅ OK (token accepted)"
    else
      echo "⚠️ token present, but repo not reachable / 404"
    fi
  else
    echo "❌ no HF_TOKEN defined"
  fi

  # Use canonical shell helper for the key
  local key=""
  if command -v torch_sage_key >/dev/null 2>&1; then
    key="$(torch_sage_key 2>/dev/null || true)"
  fi
  if [[ -n "$key" ]]; then
    echo "Torch key      : ${key}"
  fi

  echo "=================================================="
}

# Return 0 if a LOCAL file exists for given basename in $CACHE_DIR
_have_local() {
  local base="$1"
  [[ -f "${CACHE_DIR}/${base}" ]]
}

# Return 0 if the HF repo contains the path (lightweight index scan)
_have_remote() {
  local relpath="$1"  # e.g. bundles/torch_sage_bundle_<KEY>.tgz
  local ns="$(hf_dataset_namespace)"
  local name="$(hf_dataset_name)"
  curl -fsSL -H "Authorization: Bearer ${HF_TOKEN}" \
    "https://huggingface.co/api/datasets/${ns}/${name}/tree/main?recursive=1" \
    | grep -q "\"path\":\"${relpath}\""
}

# Derive current keys/basenames
_sage_bundle_basename() {
  local key; key="$(torch_sage_key)"
  echo "torch_sage_bundle_${key}.tgz"
}

_custom_nodes_bundle_basename() {
  local tag pins
  tag="${CUSTOM_NODES_BUNDLE_TAG:?missing CUSTOM_NODES_BUNDLE_TAG}"     # e.g. Wan2_1__Wan2_2__CUDA_12_8
  pins="$(pins_signature)"                    # your existing helper
  echo "custom_nodes_bundle_${tag}_${pins}_*.tgz"
}

# Show a concise yes/no with optional detail
__yn() { [[ "$1" -eq 0 ]] && echo "YES" || echo "no"; }

env_status() {
  echo "=================================================="
  echo "GPU Name       : ${GPU_NAME:-unknown} (${GPU_COUNT:-?} GPU[s])"
  echo "GPU Arch       : ${GPU_ARCH:-unknown}"
  echo "Torch Channel  : ${TORCH_CHANNEL:-auto}"
  echo "Torch CUDA Tag : ${TORCH_CUDA:-cu128}"
  echo "Torch Stable   : ${TORCH_STABLE_VER:-?}"
  echo "Torch Nightly  : ${TORCH_NIGHTLY_VER:-auto}"
  echo -n "Torch Version  : "
  $PY - <<'PY'
import torch
print(f"{torch.__version__}  (CUDA {torch.version.cuda})")
PY

  local sage_key; sage_key="$(torch_sage_key)"
  local sage_base; sage_base="$(_sage_bundle_basename)"
  local nodes_glob; nodes_glob="$(_custom_nodes_bundle_basename)"

  echo "Sage Key       : ${sage_key}"
  echo "Cache Dir      : ${CACHE_DIR}"

  # Local checks
  local have_sage_local=1 have_nodes_local=1
  if compgen -G "${CACHE_DIR}/${sage_base}" > /dev/null; then have_sage_local=0; fi
  if compgen -G "${CACHE_DIR}/${nodes_glob}" > /dev/null; then have_nodes_local=0; fi

  # Remote checks (skip if no HF token)
  local have_sage_remote=1 have_nodes_remote=1
  if [[ -n "${HF_TOKEN:-}" ]]; then
    _have_remote "bundles/${sage_base}"; have_sage_remote=$?
    # We don’t know the exact timestamped filename for nodes, so match by prefix via API list:
    # quick and dirty: if any path starts with that tag+pins (ignoring timestamp), call it present
    local ns name; ns="$(hf_dataset_namespace)"; name="$(hf_dataset_name)"
    local prefix="bundles/${nodes_glob%\*}"  # strip *.tgz
    if curl -fsSL -H "Authorization: Bearer ${HF_TOKEN}" \
         "https://huggingface.co/api/datasets/${ns}/${name}/tree/main?recursive=1" \
         | grep -q "\"path\":\"${prefix}"; then
      have_nodes_remote=0
    fi
  fi

  printf "Sage bundle (local)  : %s\n" "$(__yn $have_sage_local)"
  printf "Sage bundle (remote) : %s   %s\n" "$(__yn $have_sage_remote)" \
         "$( [[ $have_sage_remote -eq 0 ]] && echo "(bundles/${sage_base})" )"
  printf "Nodes bundle (local) : %s\n" "$(__yn $have_nodes_local)"
  printf "Nodes bundle (remote): %s   %s\n" "$(__yn $have_nodes_remote)" \
         "$( [[ $have_nodes_remote -eq 0 ]] && echo "(bundles/${nodes_glob})" )"

  # Quick import sanity
  echo -n "Import torch/sage     : "
  $PY - <<'PY'
ok = True
try:
  import torch
except Exception as e:
  ok = False
try:
  import sageattention as sa
except Exception as e:
  ok = False
print("OK" if ok else "issues")
PY
  echo "=================================================="
}

# ================================================================
# Torch channel auto-detect + latest nightly discovery
# ================================================================

# Fetch latest nightly version for the selected CUDA stream (e.g. 2.10.0.dev20251112)
# Uses the torch sub-index: .../whl/nightly/<cuda>/torch/
get_latest_torch_nightly_ver() {
  local url="https://download.pytorch.org/whl/nightly/${TORCH_CUDA}/torch/"
  local py_abi="cp$(python3 -c 'import sys; print(f"{sys.version_info.major}{sys.version_info.minor}")')"

  local ver
  ver="$(
    curl -fsSL "$url" \
      | grep -oE "torch-[0-9]+\.[0-9]+\.[0-9]+\.dev[0-9]{8}\+${TORCH_CUDA}-${py_abi}-${py_abi}" \
      | sed -E "s/^torch-([0-9]+\.[0-9]+\.[0-9]+\.dev[0-9]{8})\+${TORCH_CUDA}.*/\1/" \
      | sort -V | tail -1
  )" || true

  [[ -n "$ver" ]] && echo "$ver" || echo ""
}

get_latest_torch_stable_ver() {
  local cuda="${TORCH_CUDA:-cu128}"
  local url="https://download.pytorch.org/whl/${cuda}/torch/"
  local py_abi
  py_abi="$("$PY" - << 'PY'
import sys
print(f"cp{sys.version_info.major}{sys.version_info.minor}")
PY
  )" || py_abi="cp312"

  # Extract all torch-X+cuYYY-cpZZZ wheels and pick the highest X
  curl -fsSL "$url" 2>/dev/null \
    | grep -oE "torch-[0-9]+\.[0-9]+\.[0-9]+\+${cuda}-${py_abi}" \
    | sed -E "s/^torch-([0-9]+\.[0-9]+\.[0-9]+)\+${cuda}-${py_abi}$/\1/" \
    | sort -V | tail -1
}

compute_effective_from_nightly() {
  # $1: nightly ver like 2.10.0.dev20251113
  local nightly="$1"
  local base="${nightly%%.dev*}"    # 2.10.0

  case "${TORCH_CHANNEL:-nightly}" in
    weekly)
      # Weekly tag: e.g. 2025w46 (UTC week)
      local week_tag
      week_tag="$(date -u +%Yw%V)"
      echo "${base}.dev${week_tag}"
      ;;
    *)
      # nightly (or anything else) → keep exact nightly
      echo "${nightly}"
      ;;
  esac
}

# Return 0 if a stable torch wheel for this CUDA stream seems present on the PyTorch index.
# Uses the torch sub-index: .../whl/<cuda>/torch/
stable_torch_available() {
  local url="https://download.pytorch.org/whl/${TORCH_CUDA}/torch/"
  local py_abi="cp$(python3 -c 'import sys; print(f"{sys.version_info.major}{sys.version_info.minor}")')"
  curl -fsSL "$url" \
    | grep -q "torch-${TORCH_STABLE_VER}\+${TORCH_CUDA}-${py_abi}-${py_abi}"
}

# Decide which Torch channel to use and record *how* we got there.
# Inputs (same as before):
#   TORCH_CUDA        e.g. cu128
#   TORCH_STABLE_VER  e.g. 2.10.0
#   TORCH_NIGHTLY_VER optional; auto-filled if needed
#   TORCH_CHANNEL     optional; user override: stable|nightly
#
# Uses helpers you already have:
#   stable_torch_available
#   get_latest_torch_nightly_ver
#
# Sets:
#   TORCH_CHANNEL              ("stable"|"weekly"|"nightly")
#   TORCH_CHANNEL_EFFECTIVE    (same as above)
#   TORCH_CHANNEL_SOURCE       ("user"|"auto")
#   TORCH_VERSION_EFFECTIVE    (the actual version string we’ll install)
auto_channel_detect() {
  # User explicitly set channel: respect it.
  if [[ -n "${TORCH_CHANNEL:-}" ]]; then
    echo "[torch] Channel preset via env: ${TORCH_CHANNEL}"

    case "${TORCH_CHANNEL}" in
      nightly|weekly)
        # Need a nightly baseline to know what to install.
        if [[ -z "${TORCH_NIGHTLY_VER:-}" ]]; then
          echo "[torch] [${TORCH_CHANNEL}] Probing index: https://download.pytorch.org/whl/nightly/${TORCH_CUDA}/torch/ (ABI=$(python3 - <<'PY'
import sys; print(f"cp{sys.version_info.major}{sys.version_info.minor}")
PY
))"
          local nv
          nv="$(get_latest_torch_nightly_ver)"
          if [[ -z "$nv" ]]; then
            echo "[torch] [${TORCH_CHANNEL}] WARNING: could not determine latest nightly from index."
            echo "[torch] [${TORCH_CHANNEL}] Falling back to TORCH_STABLE_VER=${TORCH_STABLE_VER}"
            export TORCH_NIGHTLY_VER="${TORCH_STABLE_VER}"
          else
            export TORCH_NIGHTLY_VER="$nv"
            echo "[torch] [${TORCH_CHANNEL}] Latest nightly from index: ${TORCH_NIGHTLY_VER} (+${TORCH_CUDA})"
          fi
        fi
        # TORCH_VERSION_EFFECTIVE is what drives bundle keys.
        export TORCH_VERSION_EFFECTIVE="$(compute_effective_from_nightly "${TORCH_NIGHTLY_VER}")"
        echo "[torch] [user] Using ${TORCH_CHANNEL} effective version: ${TORCH_VERSION_EFFECTIVE} (+${TORCH_CUDA})"
        ;;
      stable)
        # Stable: TORCH_VERSION_EFFECTIVE is just the stable tag
        export TORCH_VERSION_EFFECTIVE="${TORCH_STABLE_VER}"
        echo "[torch] [user] Using stable: ${TORCH_VERSION_EFFECTIVE} (+${TORCH_CUDA})"
        ;;
      *)
        echo "[torch] Unknown TORCH_CHANNEL=${TORCH_CHANNEL}, defaulting to nightly-like behavior."
        export TORCH_CHANNEL="nightly"
        auto_channel_detect
        ;;
    esac
    return 0
  fi

  # Auto mode: prefer stable if visible; otherwise nightly
  echo "[torch] Auto-detecting channel for CUDA=${TORCH_CUDA}, stable=${TORCH_STABLE_VER}…"
  if stable_torch_available; then
    export TORCH_CHANNEL="stable"
    export TORCH_VERSION_EFFECTIVE="${TORCH_STABLE_VER}"
    echo "[torch] ✅ Stable is available on index — selecting stable"
  else
    export TORCH_CHANNEL="nightly"
    echo "[torch] ⚠️ Stable wheel not found on index — selecting nightly"
    local nv
    nv="$(get_latest_torch_nightly_ver)"
    if [[ -z "$nv" ]]; then
      echo "[torch] [nightly] WARNING: could not determine latest nightly from index."
      echo "[torch] [nightly] Falling back to TORCH_STABLE_VER=${TORCH_STABLE_VER}"
      export TORCH_NIGHTLY_VER="${TORCH_STABLE_VER}"
      export TORCH_VERSION_EFFECTIVE="${TORCH_STABLE_VER}"
    else
      export TORCH_NIGHTLY_VER="$nv"
      export TORCH_VERSION_EFFECTIVE="$(compute_effective_from_nightly "${TORCH_NIGHTLY_VER}")"
      echo "[torch] [nightly] Latest nightly from index: ${TORCH_NIGHTLY_VER} (+${TORCH_CUDA}), effective=${TORCH_VERSION_EFFECTIVE}"
    fi
  fi
}

print_bundle_matrix() {
  local chan="${TORCH_CHANNEL:-auto}"
  local chan_src="auto"
  [[ -n "${TORCH_CHANNEL:-}" ]] && chan_src="user"

  # Current torch+smi combo → Sage key
  local torch_key
  if ! torch_key="$(torch_sage_key 2>/dev/null)"; then
    torch_key="unknown"
  fi

  echo "Torch Channel: ${chan} (${chan_src})"
  echo "Torch Key:    ${torch_key}"

  # Derive CUDA+arch suffix for "compatible" bundles: cuXXX_sm_YY
  local cuda_tag=""
  if [[ "$torch_key" == pycp* ]]; then
    # extract "cu128_sm_89" from pycp312_torch…_cu128_sm_89
    cuda_tag="$(printf '%s\n' "$torch_key" | sed -E 's/.*_(cu[0-9]+_sm_[0-9]+)$/\1/' || true)"
  fi

  # Read local HF repo to inspect bundles
  local repo
  repo="$(hf_ensure_local_repo)" || {
    echo "[sage-bundle] hf_fetch_latest_custom_nodes_bundle: no local repo." >&2
    return 1
  }
  local total_sage=0 compat_sage=0 exact_match=0
  local sage_lines=()
  local total_cn=0 compat_cn=0
  local cn_lines=()

  #
  # ---- Sage bundles ----
  #
  if compgen -G "${repo}/bundles/torch_sage_bundle_*.tgz" >/dev/null 2>&1; then
    local f base key_part ver label
    for f in "${repo}"/bundles/torch_sage_bundle_*.tgz; do
      [[ -e "$f" ]] || continue
      ((total_sage++))
      base="$(basename "$f" .tgz)"
      key_part="${base#torch_sage_bundle_}"

      # Extract the torch version segment between "torch" and "_cu"
      ver="$(printf '%s\n' "$key_part" \
            | sed -E 's/^pycp[0-9]+_torch([^_]+)_cu[0-9]+_sm_.+$/\1/' || true)"
      label="Stable"
      [[ "$ver" == *dev* ]] && label="Nightly"

      local compat="no"
      if [[ -n "$cuda_tag" && "$key_part" == *"${cuda_tag}"* ]]; then
        compat="yes"
        ((compat_sage++))
      fi

      local mark=""
      if [[ "$key_part" == "$torch_key" ]]; then
        exact_match=1
        mark=" (Selected)"
      fi

      # Only list compatible ones in the detail section
      if [[ "$compat" == "yes" ]]; then
        sage_lines+=("  (${label}) ${key_part}${mark}")
      fi
    done
  fi

  #
  # ---- Custom node bundles ----
  #
  if compgen -G "${repo}/bundles/custom_nodes_bundle_*.tgz" >/dev/null 2>&1; then
    local g gbase compat display_tag
    for g in "${repo}"/bundles/custom_nodes_bundle_*.tgz; do
      [[ -e "$g" ]] || continue
      ((total_cn++))
      gbase="$(basename "$g")"

      if _custom_node_bundle_compatible "$gbase"; then
        ((compat_cn++))

        # Compact display tag:
        # - Prefer CUSTOM_NODES_BUNDLE_TAG / BUNDLE_TAG if set
        # - Else strip prefix/suffix
        if [[ -n "${CUSTOM_NODES_BUNDLE_TAG:-}" ]]; then
          display_tag="${CUSTOM_NODES_BUNDLE_TAG}"
        elif [[ -n "${BUNDLE_TAG:-}" ]]; then
          display_tag="${BUNDLE_TAG}"
        else
          display_tag="${gbase#custom_nodes_bundle_}"
          display_tag="${display_tag%.tgz}"
        fi

        cn_lines+=("  ${display_tag} (compatible)")
      fi
    done
  fi

  #
  # ---- Compute Sage Path description ----
  #
  local sage_path
  if (( exact_match == 1 )); then
    sage_path="Pull from HF (bundle restore — exact key match)"
  elif (( compat_sage > 0 )); then
    if [[ -n "$cuda_tag" ]]; then
      sage_path="Build from source (no exact bundle; ${compat_sage} compatible for ${cuda_tag})"
    else
      sage_path="Build from source (no exact bundle; ${compat_sage} compatible by CUDA/arch)"
    fi
  else
    sage_path="Build from source (no compatible Sage bundles yet)"
  fi

  #
  # ---- Custom-nodes path description ----
  #
  local cn_path
  if (( compat_cn > 0 )); then
    cn_path="Pull from HF (bundle restore)"
  elif (( total_cn > 0 )); then
    cn_path="Build from source (no matching custom-node bundle)"
  else
    cn_path="Build from source (no custom-node bundles found)"
  fi

  #
  # ---- Print Sage bundle summary ----
  #
  echo "Sage bundles: ${total_sage} (total), ${compat_sage} (compatible)"
  if (( compat_sage > 0 )); then
    printf '%s\n' "${sage_lines[@]}"
  fi
  echo "Sage Path: ${sage_path}"
  echo ""

  #
  # ---- Print Custom-node bundle summary ----
  #
  echo "Custom Node bundles: ${total_cn} (total), ${compat_cn} (compatible)"
  if (( compat_cn > 0 )); then
    printf '%s\n' "${cn_lines[@]}"
  fi
  echo "Custom Node Path: ${cn_path}"
  echo ""
}

install_torch() {
  echo "[torch] Installing Torch (${TORCH_CHANNEL})..." >&2

  local url ver

  case "${TORCH_CHANNEL}" in
    stable)
      # Stable: explicit version pin (we know 2.9.1 works for cu128/cp312)
      url="https://download.pytorch.org/whl/${TORCH_CUDA}"
      ver="${TORCH_VERSION_EFFECTIVE:-${TORCH_STABLE_VER}}+${TORCH_CUDA}"

      env -u PIP_REQUIRE_HASHES -u PIP_CONSTRAINT \
        $PIP install --no-cache-dir \
          "torch==${ver}" torchvision torchaudio \
          --index-url "$url"
      ;;

    weekly|nightly)
      # Weekly/Nightly: let pip resolve a compatible trio from the nightly index.
      # We do NOT pin torch==… here to avoid resolver conflicts like you just hit.
      url="https://download.pytorch.org/whl/nightly/${TORCH_CUDA}"

      env -u PIP_REQUIRE_HASHES -u PIP_CONSTRAINT \
        $PIP install --pre --no-cache-dir \
          torch torchvision torchaudio \
          --index-url "$url"
      ;;

    *)
      echo "[install-torch] FATAL: Unknown TORCH_CHANNEL=${TORCH_CHANNEL}" >&2
      return 1
      ;;
  esac

  # After install, record the actual torch version and print it
  local actual
  actual="$($PY - <<'PY'
import torch, sys
v = torch.__version__
print(v)
PY
)" || actual="unknown"

  if [[ "$actual" != "unknown" ]]; then
    # strip any '+cuXXX' suffix for the "core" version
    local base="${actual%%+*}"
    export TORCH_VERSION_EFFECTIVE="$base"
    # For non-stable, keep TORCH_NIGHTLY_VER in sync with what we actually installed
    if [[ "${TORCH_CHANNEL}" != "stable" ]]; then
      export TORCH_NIGHTLY_VER="$base"
    fi
  fi

  echo "[install-torch] Installed torch: ${actual}"

  $PY - <<'PY'
import torch
print(f"[install-torch] Torch full version : {torch.__version__}")
print(f"[install-torch] Torch CUDA version : {torch.version.cuda}")
PY
}

show_torch_sage_env_summary() {
  echo "=================================================="
  echo "Torch Channel  : ${TORCH_CHANNEL}"
  echo "Torch CUDA     : ${TORCH_CUDA}"
  echo "Torch Version  : $($PY -c 'import torch;print(torch.__version__)')"
  echo "GPU Arch       : ${GPU_ARCH}"
  echo "Sage Key       : $(torch_sage_key)"
  echo "=================================================="
}

# ================================================================
# Smarter Sage key generation (weekly-bucketed nightly builds)
# ================================================================
torch_sage_key() {
  "$PY" - << 'PY'
import sys, os, torch

abi = f"cp{sys.version_info.major}{sys.version_info.minor}"

# Prefer an "effective" version (for weekly/stable aliasing),
# fall back to the actual torch.__version__ if not set.
eff = os.environ.get("TORCH_VERSION_EFFECTIVE", "").strip()
if not eff:
    eff = torch.__version__

base_ver = eff.split('+', 1)[0].replace('+', '_')

cu_raw = (torch.version.cuda or "").replace('.', '')
cu = f"cu{cu_raw}" if cu_raw else "cu_unknown"

arch = (os.environ.get("GPU_ARCH") or "").strip().lower()
if arch.startswith("sm"):
    arch = arch.replace("sm", "").lstrip("_- ")
arch = f"sm_{arch}" if arch else "sm_unknown"

print(f"py{abi}_torch{base_ver}_{cu}_{arch}")
PY
}

install_sage_from_source() {
  # CC via torch
  local CC_TORCH
  CC_TORCH="$("$PY" - << 'PY'
import torch
maj,minr = torch.cuda.get_device_capability(0) if torch.cuda.is_available() else (0,0)
print(f"{maj}.{minr}")
PY
  )"
  echo "Detected GPU compute capability: ${CC_TORCH}"

  # Toolchain for CUDA 12.x
  unset CC CXX SAGE_CUDA_ARCH_LIST SAGE_GENCODE CUDA_ARCH_LIST
  if ! command -v g++-12 >/dev/null; then
    apt-get update && apt-get install -y gcc-12 g++-12
  fi
  export CC=/usr/bin/gcc-12
  export CXX=/usr/bin/g++-12

  # Arch list
  case "$CC_TORCH" in
    12.*) export TORCH_CUDA_ARCH_LIST="12.0;8.9;8.6;8.0" ;;
    9.*)  export TORCH_CUDA_ARCH_LIST="9.0;8.9;8.6;8.0"  ;;
    8.9)  export TORCH_CUDA_ARCH_LIST="8.9;8.6;8.0"      ;;
    8.*)  export TORCH_CUDA_ARCH_LIST="8.6;8.0"          ;;
    *)    export TORCH_CUDA_ARCH_LIST="8.0"              ;;
  esac
  echo "TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST}"

  # Clean + build (NO build isolation, so setup can import torch)
  rm -rf /tmp/SageAttention
  git clone https://github.com/thu-ml/SageAttention.git /tmp/SageAttention

  if env -u PIP_REQUIRE_HASHES -u PIP_CONSTRAINT $PIP install --no-build-isolation -e /tmp/SageAttention 2>&1 | tee /workspace/logs/sage_build.log; then
    echo "SageAttention built OK"
    return 0
  else
    echo "SageAttention build FAILED — see /workspace/logs/sage_build.log" >&2
    return 1
  fi
}

build_sage_bundle() {
  local key="${1:?SAGE_KEY required}"
  mkdir -p "$CACHE_DIR"
  local tarpath="${CACHE_DIR}/torch_sage_bundle_${key}.tgz"

  SAGE_TARPATH="$tarpath" "$PY" - << 'PY'
import importlib, os, sysconfig, tarfile, sys

site_dir = sysconfig.get_paths()["purelib"]

# Try candidate module names
candidates = ["sageattention", "SageAttention", "sage_attention"]
mod = None
pkg_name = None

for name in candidates:
    try:
        mod = importlib.import_module(name)
        pkg_name = name
        break
    except Exception:
        continue

if mod is None:
    raise SystemExit("Could not import any SageAttention module (tried: sageattention, SageAttention, sage_attention)")

pkg_path = os.path.dirname(mod.__file__)

# Find the installed dist-info directory under site-packages (if present)
base = pkg_name.replace('_', '').lower()
dist_dir = None
for entry in os.listdir(site_dir):
    if entry.lower().startswith(base) and entry.endswith(".dist-info"):
        dist_dir = os.path.join(site_dir, entry)
        break

tarpath = os.environ["SAGE_TARPATH"]

with tarfile.open(tarpath, "w:gz") as tf:
    # Always store the package as "sageattention" (or whatever pkg_name is),
    # regardless of where it lives on disk (editable installs, /tmp, etc).
    tf.add(pkg_path, arcname=pkg_name)

    # Store dist-info as just "sageattention-2.2.0.dist-info"
    if dist_dir and os.path.isdir(dist_dir):
        tf.add(dist_dir, arcname=os.path.basename(dist_dir))
PY

  echo "$tarpath"
}

build_sage_bundle_wrapper() {
  local key="${1:?SAGE_KEY required}"
  local tarpath="${CACHE_DIR}/torch_sage_bundle_${key}.tgz"

  SAGE_TARPATH="$tarpath" "$PY" -m pip show torch >/dev/null 2>&1 || {
    echo "[sage-bundle] Torch not installed; cannot build Sage bundle." >&2
    return 1
  }

  tarpath="$(build_sage_bundle "$key")" || return 1
  echo "$tarpath"
}

push_sage_bundle_if_requested() {
  if [[ "${PUSH_SAGE_BUNDLE:-0}" != "1" ]]; then
    return 0
  fi

  local key tarpath
  key="$(torch_sage_key)"
  echo "[sage-bundle] Pushing Sage bundle to HF for key=${key}…" >&2

  # Hard gate: don't push a bundle if we can't import SageAttention
  if ! "$PY" - << 'PY'
import importlib, sys
mods = ["sageattention", "SageAttention", "sage_attention"]
for m in mods:
    try:
        importlib.import_module(m)
        print(m)
        raise SystemExit(0)
    except Exception:
        pass
print("Could not import any SageAttention module (tried: sageattention, SageAttention, sage_attention)", file=sys.stderr)
raise SystemExit(1)
PY
  then
    echo "[sage-bundle] ❌ Not pushing Sage bundle — SageAttention is not importable." >&2
    return 1
  fi

  tarpath="$(build_sage_bundle_wrapper "$key")" || {
    echo "[sage-bundle] Failed to build Sage bundle." >&2
    return 1
  }

  hf_push_files "torch_sage bundle ${key}" "$tarpath"
  echo "[sage-bundle] Uploaded torch_sage_bundle_${key}.tgz"
}

hf_fetch_sage_bundle() {
  local key="${1:?SAGE_KEY}" repo patt local_tgz
  repo="$(hf_ensure_local_repo)" || {
    echo "[sage-bundle] ❌ Could not ensure local HF repo" >&2
    return 1
  }

  patt="${repo}/bundles/torch_sage_bundle_${key}.tgz"
  if [[ ! -f "$patt" ]]; then
    echo "[sage-bundle] ❌ Bundle (torch_sage_bundle_${key}.tgz) not available in HF repo." >&2
    return 1
  fi

  mkdir -p "$CACHE_DIR"
  local_tgz="${CACHE_DIR}/$(basename "$patt")"
  cp -f "$patt" "$local_tgz"

  echo "$local_tgz"
}

# hf_fetch_pip_cache:
#   Look for pip_cache/pip_cache_${key}.tgz in HF repo, copy into CACHE_DIR, echo local path.
hf_fetch_pip_cache() {
  local key="${1:?pip cache key required}"
  local repo

  repo="$(hf_ensure_local_repo)" || {
    echo "[sage-bundle] hf_fetch_latest_custom_nodes_bundle: no local repo." >&2
    return 1
  }

  local rel="pip_cache/pip_cache_${key}.tgz"
  local src="${repo}/${rel}"

  if [[ ! -f "$src" ]]; then
    echo "[pip-cache] No pip cache found for key=${key}" >&2
    return 0
  fi

  mkdir -p "${CACHE_DIR:-/workspace/ComfyUI/cache}"
  local dst="${CACHE_DIR}/pip_cache_${key}.tgz"
  cp -f "$src" "$dst"

  echo "$dst"
}

# push_pip_cache_if_requested:
#   If PUSH_CUSTOM_NODES_PIP_CACHE=1 and CUSTOM_NODES_PIP_CACHE_DIR is non-empty, tar it and push to HF.
push_pip_cache_if_requested() {
  if [[ "${PUSH_CUSTOM_NODES_PIP_CACHE:-0}" != "1" ]]; then
    return 0
  fi

  local cache="${CUSTOM_NODES_PIP_CACHE_DIR:-}"
  if [[ -z "$cache" || ! -d "$cache" ]]; then
    echo "[pip-cache] No CUSTOM_NODES_PIP_CACHE_DIR set; nothing to push." >&2
    return 0
  fi

  if [[ -z "$(ls -A "$cache" 2>/dev/null)" ]]; then
    echo "[pip-cache] CUSTOM_NODES_PIP_CACHE_DIR is empty; skipping push." >&2
    return 0
  fi

  local key tgz
  key="$(pip_cache_key)"
  tgz="${CACHE_DIR}/pip_cache_${key}.tgz"

  echo "[pip-cache] Creating pip cache archive ${tgz}..."
  tar -czf "$tgz" -C "$cache" . || {
    echo "[pip-cache] ❌ Failed to tar pip cache." >&2
    return 1
  }

  hf_push_files "pip_cache ${key}" "$tgz"
  echo "[pip-cache] Uploaded pip_cache_${key}.tgz" >&2

}

# ensure_pip_cache_for_custom_nodes:
#   If USE_PIP_CACHE_FOR_CUSTOM_NODES is set, compute cache dir and restore from HF if present.
ensure_pip_cache_for_custom_nodes() {
  if [[ "${USE_PIP_CACHE_FOR_CUSTOM_NODES:-0}" != "1" ]]; then
    return 0
  fi

  local key cache
  key="$(pip_cache_key)"
  cache="${CACHE_DIR}/pip_custom_${key}"

  mkdir -p "$cache"
  export CUSTOM_NODES_PIP_CACHE_DIR="$cache"
  export PIP_CACHE_DIR="$cache"

  echo "[pip-cache] Using PIP_CACHE_DIR=${PIP_CACHE_DIR} (custom nodes only)" >&2

  # If cache is empty, try to hydrate it from HF
  if [[ -z "$(ls -A "$cache" 2>/dev/null)" ]]; then
    local tgz
    echo "[pip-cache] Attempting to retrieve from HF, compatible cache for key: $key..." >&2
    tgz="$(hf_fetch_pip_cache "$key")"
    if [[ -n "$tgz" && -f "$tgz" ]]; then
      echo "[pip-cache] Restoring pip cache from $(basename "$tgz")..." >&2
      tar -xzf "$tgz" -C "$cache" || {
        echo "[pip-cache] ⚠️ Failed to extract pip cache archive; continuing without it." >&2
      }
      echo "[pip-cache] Restored pip cache from tar file." >&2
    fi
  fi
}

restore_sage_from_tar() {
  local tar="${SAGE_TARPATH:?SAGE_TARPATH not set}"

  local site
  site="$("$PY" - <<'PY'
import sys
for p in sys.path:
    if p.endswith("site-packages"):
        print(p)
        break
PY
)"
  if [[ -z "$site" ]]; then
    echo "[sage-bundle] ERROR: could not locate site-packages for $PY" >&2
    return 1
  fi

  echo "[sage-bundle] Untarring SageAttention from $(basename "$tar") into ${site}…" >&2
  mkdir -p "$site"
  tar xzf "$tar" -C "$site"

  "$PY" - <<'PY'
import sys
print("[sage-bundle] sys.executable:", sys.executable)
try:
    import sageattention
    print("[sage-bundle] SAGE imported sucessfully from tar bundle:", sageattention, getattr(sageattention, "__file__", None))
except Exception as e:
    print("[sage-bundle] SAGE IMPORT ERROR:", repr(e))
PY
}

ensure_sage_from_bundle_or_build() {
  local key tarpath
  key="$(torch_sage_key)"

  echo "[sage-bundle] Looking for Sage bundle key=${key}…" >&2

  # If the user wants a fresh build, skip bundle lookup entirely
  if [[ "${SAGE_FORCE_REBUILD:-0}" == "1" ]]; then
    echo "[sage-bundle] SAGE_FORCE_REBUILD=1 — skipping bundle restore and rebuilding from source." >&2
  else
    local pattern="${CACHE_DIR}/torch_sage_bundle_${key}.tgz"

    if [[ -f "$pattern" ]]; then
      tarpath="$pattern"
      echo "[sage-bundle] Found local Sage bundle in cache: $(basename "$tarpath")" >&2
    else
      # Exact bundle from HF?
      if tarpath="$(hf_fetch_sage_bundle "$key" 2>/dev/null)"; then
        :
      else
        tarpath=""
      fi

      # If still nothing, optionally reuse a compatible bundle (same cuXXX_sm_YY)
      if [[ -z "$tarpath" && "${SAGE_ALLOW_COMPAT_REUSE:-0}" == "1" ]]; then
        if tarpath="$(hf_fetch_compatible_sage_bundle "$key" 2>/dev/null)"; then
          :
        else
          tarpath=""
        fi
      fi
    fi
  fi

  if [[ -n "${tarpath:-}" && -f "$tarpath" ]]; then
    echo "[sage-bundle] Using Sage bundle: $(basename "$tarpath")" >&2
    SAGE_TARPATH="$tarpath" restore_sage_from_tar
    return 0
  fi

  echo "[sage-bundle] No bundle found — building Sage from source…" >&2
  install_sage_from_source || return 1
  return 0
}

#----------------------------------------------------------------------
# Custom nodes bundle fetch/build/push/pull
#----------------------------------------------------------------------
# hf_fetch_latest_custom_nodes_bundle: pull newest matching bundle for tag+pins into CACHE_DIR
#   echoes local tgz path or empty
hf_fetch_latest_custom_nodes_bundle() {
  local tag="${1:?bundle tag required}"
  local pins="${2:?pins required}"
  local repo patt best

  repo="$(hf_ensure_local_repo)" || {
    echo "[custom-nodes] hf_fetch_latest_custom_nodes_bundle: no local repo" >&2
    return 1
  }

  patt="${repo}/bundles/custom_nodes_bundle_${tag}_${pins}_*.tgz"

  if ! compgen -G "$patt" >/dev/null 2>&1; then
    echo "[custom-nodes] No custom-nodes bundle found for tag=${tag}, pins=${pins}" >&2
    return 1
  fi

  # pick “latest” by lexicographic sort on filename (timestamp suffix)
  best="$(ls -1 $patt | sort | tail -n1)"
  mkdir -p "$CACHE_DIR"
  cp -f "$best" "$CACHE_DIR/"
  echo "${CACHE_DIR}/$(basename "$best")"
}

# Fetch the consolidated requirements file for a given custom-nodes tag
# from the HF dataset into CACHE_DIR and echo its local path.
hf_fetch_custom_nodes_requirements_for_tag() {
  local tag="${1:?tag required}"
  local repo req_src req_dst

  repo="$(hf_ensure_local_repo)" || {
    echo "[custom-nodes] hf_fetch_latest_custom_nodes_bundle: no local repo" >&2
    return 1
  }

  # Name is derived exactly like on the push side: requirements/<reqs_name(tag)>
  local req_src="${repo}/requirements/$(reqs_name "$tag")"

  if [[ ! -f "$req_src" ]]; then
    echo "[custom-nodes] ⚠️ No consolidated requirements found for tag=${tag} (${req_rel})." >&2
    return 1
  fi

  mkdir -p "${CACHE_DIR:-/workspace/ComfyUI/cache}"
  local req_dst="${CACHE_DIR}/$(basename "$req_src")"
  cp -f "$req_src" "$req_dst"

  echo "$req_dst"
}

# Install custom-node requirements tied to a bundle tag.
# Looks for: requirements/consolidated_requirements_${tag}.txt in your HF repo.
install_custom_nodes_requirements() {
  local tag="${1:?bundle tag required}"

  local repo req_src req_work
  repo="$(hf_ensure_local_repo)" || {
    echo "[custom-nodes] hf_fetch_latest_custom_nodes_bundle: no local repo" >&2
    return 1
  }

  req_src="${repo}/requirements/consolidated_requirements_${tag}.txt"
  if [[ ! -f "$req_src" ]]; then
    echo "[custom-nodes] ⚠️ No consolidated requirements found for tag=${tag} at ${req_src}" >&2
    return 0  # not fatal; we just skip extra reqs
  fi

  req_work="${CACHE_DIR:-/workspace/ComfyUI/cache}/consolidated_requirements_${tag}.rewritten.txt"
  rewrite_custom_nodes_requirements "$req_src" "$req_work" || {
    echo "[custom-nodes] ⚠️ rewrite_custom_nodes_requirements failed; using original file" >&2
    req_work="$req_src"
  }

  echo "[custom-nodes] Installing custom-node requirements from ${req_work}..."
  # Use pip cache for these installs; keep hashes disabled.
  env -u PIP_REQUIRE_HASHES \
      PIP_CACHE_DIR="$CUSTOM_NODES_PIP_CACHE_DIR" \
      "$PIP" install -r "$req_work" || {
        echo "[custom-nodes] ⚠️ pip install -r ${req_work} failed; see logs above." >&2
        return 1
      }

  return 0
}

# build_custom_nodes_manifest: create JSON manifest of installed nodes
build_custom_nodes_manifest() {
  local tag="${1:?tag}" out="${2:?out_json}"

  # Make sure the Python side sees where to write + which tag to use
  CUSTOM_DIR="${CUSTOM_DIR:?}" \
  CUSTOM_NODES_BUNDLE_TAG="$tag" \
  out_json="$out" \
  "$PY_BIN" - <<'PY'
import json, os, subprocess

d = os.environ["CUSTOM_DIR"]
items = []

for name in sorted(os.listdir(d)):
    p = os.path.join(d, name)
    # only include git-tracked custom nodes
    if not os.path.isdir(p) or not os.path.isdir(os.path.join(p, ".git")):
        continue

    def run(*args):
        return subprocess.check_output(["git", "-C", p, *args], text=True).strip()

    try:
        url = run("config", "--get", "remote.origin.url")
    except Exception:
        url = ""
    try:
        ref = run("rev-parse", "HEAD")
    except Exception:
        ref = ""
    try:
        br = run("rev-parse", "--abbrev-ref", "HEAD")
    except Exception:
        br = ""

    items.append({"name": name, "path": p, "origin": url, "branch": br, "commit": ref})

out = os.environ["out_json"]
with open(out, "w", encoding="utf-8") as f:
    json.dump({"tag": os.environ.get("CUSTOM_NODES_BUNDLE_TAG", ""), "nodes": items}, f, indent=2)
PY
}

# build_consolidated_reqs: dedupe/strip heavy pins we manage separately
build_consolidated_reqs() {
  local tag="${1:?tag}" out="${2:?out_txt}"
  local tmp; tmp="$(mktemp)"
  ( shopt -s nullglob
    for r in "$CUSTOM_DIR"/*/requirements.txt; do
      echo -e "\n# ---- $(dirname "$r")/requirements.txt ----"
      cat "$r"
    done
  ) > "$tmp"
  # Strip torch/opencv/cupy/numpy (we pin them), remove comments/empties, sort unique
  grep -vE '^(torch|torchvision|torchaudio|opencv(|-python|-contrib-python|-headless)|cupy(|-cuda.*)|numpy)\b' "$tmp" \
    | sed '/^\s*#/d;/^\s*$/d' | sort -u > "$out" || true
  rm -f "$tmp"
}

# build_custom_nodes_bundle: pack custom_nodes + metadata into CACHE_DIR, returns tgz path
build_custom_nodes_bundle() {
  local tag="${1:?tag}" pins="${2:?pins}" ts="$(bundle_ts)"
  mkdir -p "$CACHE_DIR"
  local base; base="$(bundle_base "$tag" "$pins" "$ts")"
  local tarpath="${CACHE_DIR}/${base}.tgz"
  local manifest="${CACHE_DIR}/$(manifest_name "$tag")"
  local reqs="${CACHE_DIR}/$(reqs_name "$tag")"
  local sha="${CACHE_DIR}/$(sha_name "$base")"

  build_custom_nodes_manifest "$tag" "$manifest"
  build_consolidated_reqs "$tag" "$reqs"
  tar -C "$(dirname "$CUSTOM_DIR")" -czf "$tarpath" "$(basename "$CUSTOM_DIR")"
  sha256sum "$tarpath" > "$sha"
  echo "$tarpath"
}

# install_custom_nodes_bundle: extract tgz into parent of CUSTOM_DIR; normalize name
install_custom_nodes_bundle() {
  local tgz="${1:?tgz}"
  local parent dir; parent="$(dirname "$CUSTOM_DIR")"; dir="$(basename "$CUSTOM_DIR")"
  mkdir -p "$parent"
  tar -C "$parent" -xzf "$tgz"
  if [[ ! -d "$CUSTOM_DIR" ]]; then
    local extracted; extracted="$(tar -tzf "$tgz" | head -1 | cut -d/ -f1)"
    [[ -n "$extracted" ]] && mv -f "$parent/$extracted" "$CUSTOM_DIR"
  fi
}

# ensure_custom_nodes_from_bundle_or_build:
#   If HF has a bundle matching CUSTOM_NODES_BUNDLE_TAG + PINS → install it
#   Else build from NODES and optionally push a fresh bundle
ensure_custom_nodes_from_bundle_or_build() {
  local tag="${CUSTOM_NODES_BUNDLE_TAG:?CUSTOM_NODES_BUNDLE_TAG required}"
  local pins="${PINS:-$(pins_signature)}"
  local ok=0

  mkdir -p "$CACHE_DIR" "$CUSTOM_LOG_DIR"
  mkdir -p "$(dirname "$CUSTOM_DIR")"

  # Enable PIP cache for custom-node requirements only
  ensure_pip_cache_for_custom_nodes

  echo "[custom-nodes] PINS = $pins"
  echo "[custom-nodes] Looking for bundle tag=${tag}, pins=${pins}…"

  local tgz=""
  tgz="$(hf_fetch_latest_custom_nodes_bundle "$tag" "$pins" 2>/dev/null || true)"

  if [[ -n "$tgz" && -f "$tgz" ]]; then
    echo "[custom-nodes] Using HF bundle: $(basename "$tgz")"
    rm -rf "$CUSTOM_DIR"
    mkdir -p "$(dirname "$CUSTOM_DIR")"
    tar -xzf "$tgz" -C "$(dirname "$CUSTOM_DIR")"
    echo "[custom-nodes] Restored custom nodes from HF bundle."

    if install_custom_nodes_requirements "$tag"; then
      ok=1
    else
      ok=0
      echo "[custom-nodes] ⚠️ Requirements install failed; NOT pushing bundle/cache." >&2
    fi
  else
    echo "[custom-nodes] No HF bundle available — installing from DEFAULT_NODES…" >&2
    if install_custom_nodes_set && install_custom_nodes_requirements "$tag"; then
      ok=1
    else
      ok=0
      echo "[custom-nodes] ⚠️ Custom-node install failed; NOT pushing bundle/cache." >&2
    fi
  fi

  if (( ok == 1 )); then
    push_bundle_if_requested || true
    push_pip_cache_if_requested || true
  fi

  return $ok
}

# push_bundle_if_requested: convenience wrapper (respects CUSTOM_NODES_BUNDLE_TAG/PINS)
push_bundle_if_requested() {
  [[ "${PUSH_CUSTOM_NODES_BUNDLE:-0}" = "1" ]] || return 0
  local tag="${CUSTOM_NODES_BUNDLE_TAG:?CUSTOM_NODES_BUNDLE_TAG required}"
  local pins="${PINS:-$(pins_signature)}"
  local base tarpath manifest reqs sha
  base="$(bundle_base "$tag" "$pins")"
  tarpath="$(build_custom_nodes_bundle "$tag" "$pins")"
  manifest="${CACHE_DIR}/$(manifest_name "$tag")"
  reqs="${CACHE_DIR}/$(reqs_name "$tag")"
  sha="${CACHE_DIR}/$(sha_name "$base")"
  hf_push_files "bundle ${base}" "$tarpath" "$sha" "$manifest" "$reqs"
  echo "Uploaded bundle [$base]"
}

#=======================================================================================
#
# ---------- Section 5: ARIA2 BASED HUGGINGFACE DOWNLOADS ----------
#
#=======================================================================================

# Defaults (match your daemon)
: "${ARIA2_HOST:=127.0.0.1}"
: "${ARIA2_PORT:=6969}"
: "${ARIA2_SECRET:=KissMeQuick}"
: "${ARIA2_PROGRESS_INTERVAL:=15}"
: "${ARIA2_PROGRESS_BAR_WIDTH:=40}"
: "${COMFY:=/workspace/ComfyUI}"
: "${COMFY_LOGS:=/workspace/logs}"

mkdir -p "$COMFY_LOGS" "$COMFY/models" >/dev/null 2>&1 || true

_helpers_need() { command -v "$1" >/dev/null || { echo "Missing $1" >&2; exit 1; }; }

# ---- tiny utils ----
helpers_human_bytes() { # bytes -> human
  local b=${1:-0} d=0
  local -a u=(Bytes KB MB GB TB PB)

  while (( b >= 1024 && d < ${#u[@]}-1 )); do
    b=$(( b / 1024 ))
    ((d++))
  done

  printf "%d %s" "$b" "${u[$d]}"
}

#=======================================================================
#===
#=== Common utils for manifest-based and CIVITAI-based downloading
#===
#=======================================================================

# start_aria2_daemon: launch aria2c daemon if not already running
aria2_start_daemon() {
  : "${ARIA2_HOST:=127.0.0.1}"
  : "${ARIA2_PORT:=6969}"
  : "${ARIA2_SECRET:=KissMeQuick}"

  # already up?
  if curl -fsS "http://${ARIA2_HOST}:${ARIA2_PORT}/jsonrpc" \
       -H 'Content-Type: application/json' \
       --data '{"jsonrpc":"2.0","id":"v","method":"aria2.getVersion","params":["token:'"$ARIA2_SECRET"'"]}' \
       >/dev/null 2>&1; then
    return 0
  fi
  
  set +m
  # quiet background, no shell job id printed
  nohup aria2c --no-conf \
    --enable-rpc --rpc-secret="$ARIA2_SECRET" \
    --rpc-listen-port="$ARIA2_PORT" --rpc-listen-all=false \
    --daemon=true \
    --check-certificate=true --min-tls-version=TLSv1.2 \
    --max-concurrent-downloads="${ARIA2_MAX_CONC:-8}" \
    --continue=true --file-allocation=none \
    --summary-interval=0 --show-console-readout=false \
    --console-log-level=warn \
    --log="${COMFY_LOGS:-/workspace/logs}/aria2.log" --log-level=notice \
    >/dev/null 2>&1 &
    disown
    set -m

  # wait until RPC responds
  for _ in {1..50}; do
    sleep 0.1
    curl -fsS "http://${ARIA2_HOST}:${ARIA2_PORT}/jsonrpc" \
      -H 'Content-Type: application/json' \
      --data '{"jsonrpc":"2.0","id":"v","method":"aria2.getVersion","params":["token:'"$ARIA2_SECRET"'"]}' \
      >/dev/null 2>&1 && return 0
  done
  echo "❌ aria2 RPC did not come up" >&2
  return 1
}

# --- raw JSON-RPC POST helper (the function your code calls) ---
helpers_rpc_post() {
  : "${ARIA2_HOST:=127.0.0.1}" "${ARIA2_PORT:=6969}"
  curl -sS "http://${ARIA2_HOST}:${ARIA2_PORT}/jsonrpc" \
       -H 'Content-Type: application/json' \
       --data-binary "${1:-{}}" \
       || true
}

# ---- ping ----
helpers_rpc_ping() {
  : "${ARIA2_HOST:=127.0.0.1}" "${ARIA2_PORT:=6969}" "${ARIA2_SECRET:=KissMeQuick}"
  curl -fsS "http://${ARIA2_HOST}:${ARIA2_PORT}/jsonrpc" \
       -H 'Content-Type: application/json' \
       --data '{"jsonrpc":"2.0","id":"v","method":"aria2.getVersion","params":["token:'"$ARIA2_SECRET"'"]}' \
       >/dev/null 2>&1
}

# addUri
helpers_rpc_add_uri() {
  local url="$1" dir="$2" out="$3" checksum="$4"
  local tok="token:${ARIA2_SECRET}"
  local opts
  opts=$(jq -nc --arg d "$dir" --arg o "$out" '
    { "dir": $d, "out": $o, "allow-overwrite": "true", "auto-file-renaming": "false" }')
  # checksum optional
  if [[ -n "$checksum" ]]; then
    opts=$(jq -nc --argjson base "$opts" --arg c "$checksum" '$base + {"checksum":$c}')
  fi
  local payload
  payload=$(jq -nc --arg tok "$tok" --arg u "$url" --argjson o "$opts" \
    '{jsonrpc:"2.0", id:"add", method:"aria2.addUri", params:[$tok, [$u], $o]}')
  helpers_rpc_post "$payload" | jq -r '.result // empty'
}

# helpers_rpc <method> <params_json_array>
# params_json_array should be a JSON array (e.g. [ ["url"], {"dir":"...","out":"..."} ])

helpers_rpc() {
  local method="$1"; shift
  local params_json="$1"
  : "${ARIA2_HOST:=127.0.0.1}" "${ARIA2_PORT:=6969}" "${ARIA2_SECRET:=KissMeQuick}"

  # Build final params = ["token:SECRET", ...original array items...]
  local payload
  if [[ -n "$ARIA2_SECRET" ]]; then
    payload="$(
      jq -nc \
         --arg m "$method" \
         --arg t "token:$ARIA2_SECRET" \
         --argjson p "$params_json" '
        {jsonrpc:"2.0", id:"x", method:$m,
         params: ( [$t] + $p ) }'
    )"
  else
    payload="$(
      jq -nc --arg m "$method" --argjson p "$params_json" \
        '{jsonrpc:"2.0", id:"x", method:$m, params:$p}'
    )"
  fi

  curl -sS "http://$ARIA2_HOST:$ARIA2_PORT/jsonrpc" \
       -H 'Content-Type: application/json' \
       --data-binary "$payload"
}

aria2_stop_all() {
  # pause and clear all results (daemon left running)
  helpers_rpc 'aria2.pauseAll' >/dev/null 2>&1 || true
  # remove stopped results
  local gids
  gids="$(helpers_rpc 'aria2.tellStopped' '[0,10000]' | jq -r '(.result // [])[]?.gid // empty')" || true
  if [[ -n "$gids" ]]; then
    while read -r gid; do
      [[ -z "$gid" ]] && continue
      helpers_rpc 'aria2.removeDownloadResult' '["'"$gid"'"]' >/dev/null 2>&1 || true
    done <<<"$gids"
  fi
}

# clear results
aria2_clear_results() {
  helpers_rpc_ping || return 0
  helpers_rpc_post '{"jsonrpc":"2.0","id":"pd","method":"aria2.purgeDownloadResult","params":["token:'"$ARIA2_SECRET"'"]}' >/dev/null 2>&1 || true
}

helpers_have_aria2_rpc() {
  : "${ARIA2_HOST:=127.0.0.1}"; : "${ARIA2_PORT:=6969}"; : "${ARIA2_SECRET:=KissMeQuick}"
  curl -fsS "http://$ARIA2_HOST:$ARIA2_PORT/jsonrpc" \
    -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","id":"v","method":"aria2.getVersion","params":["token:'"$ARIA2_SECRET"'"]}' \
    >/dev/null 2>&1
}

helpers_queue_empty() {
  : "${ARIA2_HOST:=127.0.0.1}"; : "${ARIA2_PORT:=6969}"; : "${ARIA2_SECRET:=KissMeQuick}"
  local body resp a w
  body="$(jq -cn --arg t "token:$ARIA2_SECRET" \
    '{jsonrpc:"2.0",id:"A",method:"aria2.tellActive",params:[$t]},
     {jsonrpc:"2.0",id:"W",method:"aria2.tellWaiting",params:[$t,0,1000]}' )"
  resp="$(curl -fsS "http://$ARIA2_HOST:$ARIA2_PORT/jsonrpc" -H 'Content-Type: application/json' --data-binary "$body" 2>/dev/null)" || return 0
  a="$(jq -sr '.[]
    | select(.id=="A").result
    | length' <<<"$resp")"
  w="$(jq -sr '.[]
    | select(.id=="W").result
    | length' <<<"$resp")"
  (( a==0 && w==0 ))
}

# ---- Foreground progress with trap ----
aria2_monitor_progress() {
  local interval="${1:-10}" barw="${2:-40}" log="${3:-/workspace/logs/aria2_progress.log}"
  mkdir -p "$(dirname "$log")"

  local _stop=0
  _loop_trap() {
    echo "⚠️  Aria2 Downloader Interrupted — pausing queue…" >&2
    helpers_rpc 'aria2.pauseAll' '[]' >/dev/null 2>&1 || true
    if [[ "${ARIA2_SHUTDOWN_ON_INT:-0}" == "1" ]]; then
      echo "⚠️  Shutting down aria2 daemon…" >&2
      helpers_rpc 'aria2.forceShutdown' '[]' >/dev/null 2>&1 || true
    fi
    _stop=1
  }
  trap _loop_trap INT TERM

  while :; do
    aria2_show_download_snapshot | tee -a "$log"
    if helpers_queue_empty || [[ $_stop -eq 1 ]]; then
      break
    fi
    sleep "$interval"
  done

  trap - INT TERM
}

aria2_show_download_snapshot() {
  : "${ARIA2_HOST:=127.0.0.1}"
  : "${ARIA2_PORT:=6969}"
  : "${ARIA2_SECRET:=KissMeQuick}"
  : "${ARIA2_PROGRESS_MAX:=999}"
  : "${ARIA2_PROGRESS_BAR_WIDTH:=40}"

  # Be robust even if set -e is globally enabled
  set +e

  # --- Fetch JSON from aria2 ---
  local act_json wai_json sto_json
  act_json="$(helpers_rpc 'aria2.tellActive' '[]' 2>/dev/null || true)"
  wai_json="$(helpers_rpc 'aria2.tellWaiting' '[0,1000]' 2>/dev/null || true)"
  sto_json="$(helpers_rpc 'aria2.tellStopped' '[0,1000]' 2>/dev/null || true)"

  # --- Extract arrays ---
  local act wai sto
  act="$(jq -c '(.result // [])' <<<"$act_json" 2>/dev/null || echo '[]')"
  wai="$(jq -c '(.result // [])' <<<"$wai_json" 2>/dev/null || echo '[]')"
  sto="$(jq -c '(.result // [])' <<<"$sto_json" 2>/dev/null || echo '[]')"

  # --- Counts ---
  local active_count pending_count completed_count
  active_count="$(jq -r 'length' <<<"$act" 2>/dev/null || echo 0)"
  pending_count="$(jq -r 'length' <<<"$wai" 2>/dev/null || echo 0)"
  completed_count="$(jq -r 'length' <<<"$sto" 2>/dev/null || echo 0)"

  echo "================================================================================"
  echo "=== Aria2 Downloader Snapshot @ $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=== Active: $active_count   Pending: $pending_count   Completed: $completed_count"
  echo "================================================================================"
  echo

  # Helper: trim COMFY/COMFY_HOME from a dir
  local ROOT
  ROOT="${COMFY:-${COMFY_HOME:-}}"

  # --- Pending (waiting queue) ---
  echo "Pending (waiting queue)"
  echo "--------------------------------------------------------------------------------"
  if (( pending_count == 0 )); then
    echo "  (none)"
  else
    local -a pending_rows pending_rows2
    local row name dir maxw=0

    mapfile -t pending_rows < <(
      jq -r '
        .[]?
        | (.files[0].path // "") as $p
        | if $p == "" then empty else
            ($p | capture("(?<dir>.*)/(?<name>[^/]+)$")) as $m
            | "\($m.name)\t\($m.dir)"
          end
      ' <<<"$wai" 2>/dev/null || true
    )

    for row in "${pending_rows[@]}"; do
      IFS=$'\t' read -r name dir <<<"$row"
      if [[ -n "$ROOT" && "$dir" == "$ROOT/"* ]]; then
        dir="${dir#$ROOT/}"
      fi
      pending_rows2+=( "$name"$'\t'"$dir" )
      (( ${#name} > maxw )) && maxw=${#name}
    done

    for row in "${pending_rows2[@]}"; do
      IFS=$'\t' read -r name dir <<<"$row"
      printf "  ⏳  - %-*s [%s]\n" "$maxw" "$name" "$dir"
    done
  fi
  echo

  echo "Downloading (active transfers)"
  echo "--------------------------------------------------------------------------------"
  if (( active_count == 0 )); then
    echo "  (none)"
  else
    local -a dl_rows
    local row done tot spd path pct bar_len bar W dir name ROOT

    ROOT="${COMFY:-${COMFY_HOME:-/workspace/ComfyUI}}"
    W="${ARIA2_PROGRESS_BAR_WIDTH:-40}"

    mapfile -t dl_rows < <(
      jq -r '
        .[]?
        | [.completedLength // "0",
          .totalLength     // "0",
          .downloadSpeed   // "0",
          (.files[0].path  // "")]
        | @tsv
      ' <<<"$act" 2>/dev/null || true
    )

    for row in "${dl_rows[@]}"; do
      IFS=$'\t' read -r done tot spd path <<<"$row"
      [[ -z "$path" ]] && continue

      done=$((done+0))
      tot=$((tot+0))
      spd=$((spd+0))

      pct=0
      (( tot > 0 )) && pct=$(( done * 100 / tot ))

      bar_len=$(( W * pct / 100 ))
      printf -v bar '%*s' "$bar_len" ''
      bar=${bar// /#}
      printf -v bar '%-*s' "$W" "$bar"

      dir="${path%/*}"
      name="${path##*/}"

      if [[ -n "$ROOT" && "$dir" == "$ROOT/"* ]]; then
        dir="${dir#$ROOT/}"
      fi

      printf " %3d%% [%-*s] %10s/s (%10s / %10s)  [ %-20s ] %s\n" \
        "$pct" "$W" "$bar" \
        "$(helpers_human_bytes "$spd")" \
        "$(helpers_human_bytes "$done")" \
        "$(helpers_human_bytes "$tot")" \
        "$dir" "$name"
    done
  fi
  echo

  # Build TSV rows: name<TAB>relpath<TAB>size
  local completed_tsv
  completed_tsv="$(
    jq -r '
      .[]?
      | select(.status == "complete")
      | (.files[0].path // "") as $full
      | select($full != "")
      | ($full | split("/") | last) as $name
      | ($full | split("/") | .[0:-1] | join("/")) as $dir
      | (.totalLength // "0") as $sz
      | [$name, $dir, $sz] | @tsv
    ' <<<"$sto" 2>/dev/null || true
  )"

  if [[ -z "$completed_tsv" ]]; then
    echo "Completed (this session)"
    echo "--------------------------------------------------------------------------------"
    echo "  (none)"
    echo "--------------------------------------------------------------------------------"
  else
    # turn TSV into array and pretty-print
    local -a completed_rows
    IFS=$'\n' read -r -d '' -a completed_rows <<<"$completed_tsv"$'\n'
    helpers_print_completed_block "${completed_rows[@]}"
    echo "--------------------------------------------------------------------------------"
  fi

  # --- Group totals (active + waiting) ---
  local total_done_active total_size_active total_speed_active
  local total_done_waiting total_size_waiting
  local total_done total_size total_speed

  # Sum over active transfers
  total_done_active="$(
    jq -r '[.[] | (.completedLength // "0" | tonumber)] | add // 0' \
      <<<"$act" 2>/dev/null || echo 0
  )"
  total_size_active="$(
    jq -r '[.[] | (.totalLength     // "0" | tonumber)] | add // 0' \
      <<<"$act" 2>/dev/null || echo 0
  )"
  total_speed_active="$(
    jq -r '[.[] | (.downloadSpeed   // "0" | tonumber)] | add // 0' \
      <<<"$act" 2>/dev/null || echo 0
  )"

  # Sum over waiting transfers (speed is always 0)
  total_done_waiting="$(
    jq -r '[.[] | (.completedLength // "0" | tonumber)] | add // 0' \
      <<<"$wai" 2>/dev/null || echo 0
  )"
  total_size_waiting="$(
    jq -r '[.[] | (.totalLength     // "0" | tonumber)] | add // 0' \
      <<<"$wai" 2>/dev/null || echo 0
  )"

  # Combine
  total_done=$(( total_done_active + total_done_waiting ))
  total_size=$(( total_size_active + total_size_waiting ))
  total_speed=$(( total_speed_active ))   # waiting has no speed

  echo
  echo "Group total: speed $(helpers_human_bytes "$total_speed")/s, done $(helpers_human_bytes "$total_done") / $(helpers_human_bytes "$total_size")"
  echo

  set -e
}

# Print aligned "Completed (this session)" block from a list of "name<TAB>relpath<TAB>size"
helpers_print_completed_block() {
  local lines=("$@")
  [[ ${#lines[@]} -eq 0 ]] && return 0

  local maxlen=0
  local name relpath size row
  # find longest name
  for row in "${lines[@]}"; do
    IFS=$'\t' read -r name relpath size <<<"$row"
    (( ${#name} > maxlen )) && maxlen=${#name}
  done

  echo "Completed (this session)"
  echo "--------------------------------------------------------------------------------"
  for row in "${lines[@]}"; do
    IFS=$'\t' read -r name relpath size <<<"$row"
    printf "  ✅ %-*s  %s  (%s)\n" "$maxlen" "$name" "$relpath" "$(helpers_human_bytes $size)"
  done
}

aria2_debug_queue_counts() {
  : "${ARIA2_HOST:=127.0.0.1}"
  : "${ARIA2_PORT:=6969}"
  : "${ARIA2_SECRET:=KissMeQuick}"

  local t="token:${ARIA2_SECRET}"
  local url="http://${ARIA2_HOST}:${ARIA2_PORT}/jsonrpc"

  echo "=== aria2_debug_queue_counts @ $(date '+%Y-%m-%d %H:%M:%S') ==="

  # Active
  local act_json wai_json sto_json
  act_json="$(curl -fsS "$url" \
    -H 'Content-Type: application/json' \
    --data-binary "$(jq -cn --arg t "$t" '{jsonrpc:"2.0",id:"A",method:"aria2.tellActive",params:[$t]}')" \
  )" || { echo "  ERROR: tellActive RPC failed"; return 1; }

  wai_json="$(curl -fsS "$url" \
    -H 'Content-Type: application/json' \
    --data-binary "$(jq -cn --arg t "$t" '{jsonrpc:"2.0",id:"W",method:"aria2.tellWaiting",params:[$t,0,1000]}')" \
  )" || { echo "  ERROR: tellWaiting RPC failed"; return 1; }

  sto_json="$(curl -fsS "$url" \
    -H 'Content-Type: application/json' \
    --data-binary "$(jq -cn --arg t "$t" '{jsonrpc:"2.0",id:"S",method:"aria2.tellStopped",params:[$t,-1000,1000]}')" \
  )" || { echo "  ERROR: tellStopped RPC failed"; return 1; }

  # Extract counts straight from .result
  local active_count waiting_count stopped_count
  active_count="$(jq -r '(.result // []) | length' <<<"$act_json" 2>/dev/null || echo 0)"
  waiting_count="$(jq -r '(.result // []) | length' <<<"$wai_json" 2>/dev/null || echo 0)"
  stopped_count="$(jq -r '(.result // []) | length' <<<"$sto_json" 2>/dev/null || echo 0)"

  echo "  active   (tellActive .result | length):  $active_count"
  echo "  waiting  (tellWaiting .result | length): $waiting_count"
  echo "  stopped  (tellStopped .result | length): $stopped_count"

  echo
  echo "  Sample active names:"
  jq -r '(.result // [])[] | .files[0].path // .bittorrent.info.name // .gid // "unknown"' \
    <<<"$act_json" 2>/dev/null | sed 's/^/    - /' | head -10

  echo
  echo "  Sample waiting names:"
  jq -r '(.result // [])[] | .files[0].path // .bittorrent.info.name // .gid // "unknown"' \
    <<<"$wai_json" 2>/dev/null | sed 's/^/    - /' | head -10

  echo
  echo "  Sample stopped names:"
  jq -r '(.result // [])[] | .files[0].path // .bittorrent.info.name // .gid // "unknown"' \
    <<<"$sto_json" 2>/dev/null | sed 's/^/    - /' | head -10
}

#-----------------------------------------------------------------------
#--
#-- Manifest parser helpers --
#--

# Replace {VAR} tokens using current environment.
# - If the input parses as JSON, walk string leaves and substitute via jq+env.
# - Otherwise, do fast pure-Bash substitution on the plain string.
helpers_resolve_placeholders() {
  _helpers_need jq
  local raw="$1"

  # If it's valid JSON, use jq path
  if printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    jq -nr -r --arg RAW "$raw" '
      def subst_env($text):
        reduce (env | to_entries[]) as $e ($text;
          gsub("\\{" + ($e.key|tostring) + "\\}"; ($e.value|tostring))
        );
      def walk_strings(f):
        if type == "object" then
          with_entries(.value |= ( . | walk_strings(f) ))
        elif type == "array" then
          map( walk_strings(f) )
        elif type == "string" then
          f
        else
          .
        end;

      ($RAW | fromjson)                          # safe: we just validated it parses
      | walk_strings( subst_env(.) )
      | tojson
    '
    return
  fi

  # Plain string: Bash token replace {NAME} -> $NAME (leaves unknown as-is)
  local s="$raw" key val
  # Replace all tokens that look like {VARNAME}
  while [[ $s =~ \{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
    key="${BASH_REMATCH[1]}"
    val="${!key}"                        # indirect expansion
    # If not set, keep token as-is (comment next line & uncomment the one after if you want them to disappear)
    [[ -z ${!key+x} ]] && val="{$key}"
    s="${s//\{$key\}/$val}"
  done
  printf '%s\n' "$s"
}

# Build a JSON object of vars+paths from manifest + UPPERCASE env vars
helpers_build_vars_json() {
  _helpers_need jq
  local man="$1"
  # Start with vars+paths from the manifest
  local base
  base="$(jq -n --slurpfile m "$man" '
    ($m[0].vars  // {}) as $v |
    ($m[0].paths // {}) as $p |
    ($v + $p)
  ')" || return 1

  # Merge UPPERCASE environment as *strings* (never --argjson)
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^[A-Z0-9_]+$ ]] || continue
    base="$(jq --arg k "$k" --arg v "$v" '. + {($k): $v}' <<<"$base")"
  done < <(env)

  printf '%s' "$base"
}

# Enqueue one URL/path pair from manifest
# - Resolves {PLACEHOLDERS} in 'raw_path' to get the final 'out' filename and 'dir'
helpers_manifest_enqueue_one() {
  local url="$1" raw_path="$2"
  local path dir out resp gid
  path="$(helpers_resolve_placeholders "$raw_path")" || return 1
  dir="$(dirname -- "$path")"; out="$(basename -- "$path")"
  mkdir -p -- "$dir"

  # skip if completed file exists and no partial
  if [[ -f "$path" && ! -f "$path.aria2" ]]; then
    echo " - ⏭️ SKIPPING: $out (safetensors file exists)" >&2
    return 0
  fi

  local gid
  gid="$(helpers_rpc_add_uri "$url" "$dir" "$out" "")"
  if [[ -n "$gid" ]]; then
    echo " - 📥 Queue: $out" >&2
    return 0
  else
    echo "ERROR adding $url to the queue (addUri: $resp). Could be a bad token, bad URL etc. Please check the logs." >&2
    return 1
  fi
}

#-----------------------------------------------------------------------
# ---- Process json list for downloads to pull ----

# ---- Manifest Enqueue ----
aria2_download_from_manifest() {
  _helpers_need curl; _helpers_need jq; _helpers_need awk

  # Optional arg: manifest source; if empty, fall back to MODEL_MANIFEST_URL.
  # Source can be:
  #   - local file path (JSON)
  #   - URL (http/https)
  local src="${1:-${MODEL_MANIFEST_URL:-}}"
  if [[ -z "$src" ]]; then
    echo "aria2_download_from_manifest: no manifest source given and MODEL_MANIFEST_URL is not set." >&2
    return 1
  fi

  local MAN tmp=""
  if [[ -f "$src" ]]; then
    # Local file
    MAN="$src"
  else
    # Treat as URL and download to temp file
    MAN="$(mktemp)"
    tmp="$MAN"
    if ! curl -fsSL "$src" -o "$MAN"; then
      echo "aria2_download_from_manifest: failed to fetch manifest: $src" >&2
      rm -f "$tmp"
      return 1
    fi
  fi

  # build vars map (kept for parity, even if not directly used)
  local VARS_JSON
  VARS_JSON="$(helpers_build_vars_json "$MAN")" || {
    [[ -n "$tmp" ]] && rm -f "$tmp"
    return 1
  }

  # find enabled sections
  local SECTIONS_ALL ENABLED sec dl_var
  SECTIONS_ALL="$(jq -r '.sections | keys[]' "$MAN")"
  ENABLED=()
  while read -r sec; do
    dl_var="download_${sec}"
    if [[ "${!sec:-}" == "true" || "${!sec:-}" == "1" || \
          "${!dl_var:-}" == "true" || "${!dl_var:-}" == "1" ]]; then
      ENABLED+=("$sec")
    fi
  done <<<"$SECTIONS_ALL"

  # Dedupe sections
  if ((${#ENABLED[@]} == 0)); then
    echo "aria2_download_from_manifest: no sections enabled in manifest '$src'." >&2
    echo 0               # <- $any = 0 (nothing enqueued), but NOT an error
    [[ -n "$tmp" ]] && rm -f "$tmp"
    return 0
  fi
  mapfile -t ENABLED < <(printf '%s\n' "${ENABLED[@]}" | awk '!seen[$0]++')

  # (Daemon should already be running; leave that to top-level)
  local any=0

  for sec in "${ENABLED[@]}"; do
    echo ">>> Enqueue section: $sec" >&2

    # Build TSV in this shell
    local tsv
    tsv="$(
      jq -r --arg sec "$sec" '
        def as_obj:
          if   type=="object" then {url:(.url//""), path:(.path // ((.dir // "") + (if .out then "/" + .out else "" end)))}
          elif type=="array"  then {url:(.[0]//""), path:(.[1]//"")}
          elif type=="string" then {url:., path:""}
          else {url:"", path:""} end;
        (.sections[$sec] // [])[] | as_obj | select(.url|length>0)
        | [.url, (if (.path|length)>0 then .path else (.url|sub("^.*/";"")) end)] | @tsv
      ' "$MAN"
    )"

    # If this section has no actual URL entries, just continue
    [[ -z "$tsv" ]] && continue

    # Iterate TSV lines
    while IFS=$'\t' read -r url raw_path; do
      # unified enqueue -> records gid via helpers_rpc_add_uri
      # helpers_manifest_enqueue_one should:
      #   - print Queue / SKIP messages to stderr
      #   - return 0 if success/skip, non-zero on error
      #   - increment any only if something was enqueued
      if helpers_manifest_enqueue_one "$url" "$raw_path"; then
        any=1
      fi
    done <<<"$tsv"

  done

  [[ -n "$tmp" ]] && rm -f "$tmp"

  # At this point:
  #   any = 1  -> at least one item enqueued
  #   any = 0  -> sections enabled but everything was already present/skipped
  if [[ "$any" == "0" ]]; then
    echo "aria2_download_from_manifest: nothing new to enqueue (all targets already present) from '$src'." >&2
  fi

  printf '%s\n' "$any"
  return 0
}

#=======================================================================================
# ---- Main ARIA2 Spawn ----
#=======================================================================================

aria2_enqueue_and_wait_from_manifest() {
  local manifest_src="${1:-}"   # optional: URL or local JSON; default MODEL_MANIFEST_URL inside downloader

  aria2_clear_results >/dev/null 2>&1 || true
  helpers_have_aria2_rpc || aria2_start_daemon

  local trapped=0
  _cleanup_trap_manifest() {
    (( trapped )) && return 0
    trapped=1
    echo
    echo "⚠️  Aria2 Downloader Interrupted — stopping queue and cleaning results…"
    # Nice to show what's left when user interrupts
    helpers_print_pending_from_aria2 2>/dev/null || true
    aria2_stop_all    >/dev/null 2>&1 || true
    aria2_clear_results >/dev/null 2>&1 || true
    return 130
  }
  trap _cleanup_trap_manifest INT TERM

  echo "================================================================================"
  echo "==="
  echo "=== Huggingface Model Downloader: Processing queuing @ $(date '+%Y-%m-%d %H:%M:%S') ==="
  echo "==="

  local any
  if ! any="$(aria2_download_from_manifest "$manifest_src")"; then
    echo "aria2_enqueue_and_wait_from_manifest: manifest processing failed." >&2
    trap - INT TERM
    return 1
  fi

  # Downloader *already* printed any "nothing to enqueue" messages.
  # Here we just decide whether to start the monitor loop.
  if [[ "$any" == "0" ]] && helpers_queue_empty; then
    # No new items and queue empty -> nothing to wait for
    trap - INT TERM
    return 0
  fi

  # Otherwise: either we enqueued something, or queue already had items.
  aria2_monitor_progress \
    "${ARIA2_PROGRESS_INTERVAL:-15}" \
    "${ARIA2_PROGRESS_BAR_WIDTH:-40}" \
    "${COMFY_LOGS:-/workspace/logs}/aria2_progress.log"

  # Show completed block when done
  helpers_print_completed_from_aria2 2>/dev/null || true

  aria2_clear_results >/dev/null 2>&1 || true
  trap - INT TERM
  return 0
}

#=======================================================================================
#
# ---------- Section 6: CivitAI ID downloader helpers ----------
#
#=======================================================================================

# Env it uses (override in .env):
: "${CHECKPOINT_IDS_TO_DOWNLOAD:=}"     # e.g. "12345, 67890, 23422:i2v"
: "${LORAS_IDS_TO_DOWNLOAD:=}"          # e.g. "abc, def ghi"
: "${CIVITAI_LOG_DIR:=${COMFY_LOGS:-/workspace/logs}/civitai}"
: "${CIVITAI_DEBUG:=0}"

#---------------------------------------------------------------------------------------

# =========================
# CivitAI (clean slate RPC)
# =========================
# Env:
#   CIVITAI_TOKEN                 (required for private/limited files; optional for public)
#   LORAS_IDS_TO_DOWNLOAD         e.g. "2361379, 234567"
#   CHECKPOINT_IDS_TO_DOWNLOAD    e.g. "1234567 7654321"
#   COMFY_HOME                    default: /workspace/ComfyUI
#   CIVITAI_DEBUG=1               verbose
#   CIVITAI_PROBE=0|1             1-byte probe before enqueue (default: 1)
#
# Requires:
#   helpers_human_bytes, aria2_start_daemon,
#   helpers_rpc_add_uri, helpers_have_aria2_rpc, aria2_start_daemon,
#   aria2_monitor_progress, aria2_clear_results, aria2_stop_all

# Keep ASCII-ish, tool-friendly names that Comfy pickers like.
# Rules:
# - strip straight/curly quotes
# - collapse whitespace -> _
# - ()[]{} -> __
# - remove anything not [A-Za-z0-9._-] -> _
# - collapse multiple _ -> single _
# - trim leading/trailing _
# - preserve/normalize extension case

helpers_sanitize_basename() {
  local in="$1"
  [[ -z "$in" ]] && { printf "model.safetensors"; return; }

  local base ext name
  base="$(basename -- "$in")"
  ext="${base##*.}"
  name="${base%.*}"
  # normalize extension to lower
  ext="${ext,,}"

  # sed-based cleanup
  name="$(printf '%s' "$name" \
    | sed -E "s/['‘’]//g; s/[[:space:]]+/_/g; s/[(){}\[\]]+/__/g; s/[^A-Za-z0-9._-]+/_/g; s/_+/_/g; s/^_+|_+$//g")"

  [[ -z "$name" ]] && name="model"
  printf "%s.%s" "$name" "$ext"
}

# Ensure uniqueness in a directory (append _1, _2, … if needed)
helpers_unique_dest() {
  local dir="$1" base="$2"
  local path="$dir/$base"
  local stem="${base%.*}" ext=".${base##*.}"
  local i=1
  while [[ -e "$path" ]]; do
    path="$dir/${stem}_$i$ext"
    ((i++))
  done
  printf "%s" "$path"
}

helpers_civitai_extract_and_move_zip() {
  local zip_path="$1" target_dir="$2"
  [[ -f "$zip_path" ]] || { echo "⚠️  ZIP not found: $zip_path"; return 1; }
  mkdir -p "$target_dir"

  local tmpdir; tmpdir="$(mktemp -d -p "${target_dir%/*}" civit_zip_XXXXXX)"
  local moved=0

  # Try unzip quietly; fall back to BusyBox if needed
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$zip_path" -d "$tmpdir" || true
  else
    busybox unzip -oq "$zip_path" -d "$tmpdir" || true
  fi

  shopt -s nullglob
  local f
  for f in "$tmpdir"/**/*.safetensors "$tmpdir"/*.safetensors; do
    [[ -e "$f" ]] || continue
    local bn clean dest
    bn="$(basename -- "$f")"
    clean="$(helpers_sanitize_basename "$bn")"
    dest="$(helpers_unique_dest "$target_dir" "$clean")"
    mkdir -p "$(dirname "$dest")"
    mv -f -- "$f" "$dest"
    echo "📦 Extracted: $(basename -- "$dest")" >&2
    ((moved++))
  done
  shopt -u nullglob

  # Cleanup temp + leave original ZIP (or delete—your call)
  rm -rf -- "$tmpdir"

  if (( moved == 0 )); then
    echo "⚠️  No .safetensors found in ZIP: $(basename -- "$zip_path")" >&2
    # Option A: keep ZIP in place (already in loras dir)
    # Option B (recommended): park it in an _incoming folder so it’s out of the picker’s way
    local park_dir="${target_dir%/}/_incoming"
    mkdir -p "$park_dir"
    mv -f -- "$zip_path" "$park_dir/" || true
    echo "➡️  Moved ZIP to: $park_dir/$(basename -- "$zip_path")" >&2
  else
    # If at least one .safetensors extracted, remove the ZIP
    rm -f -- "$zip_path"
  fi
}

# Case-insensitive match for *.safetensors
helpers_zip_has_safetensors() {
  local zip="$1"
  if command -v unzip >/dev/null 2>&1; then
    unzip -Z1 -- "$zip" 2>/dev/null | awk 'tolower($0) ~ /\.safetensors$/ {found=1} END{exit !(found)}'
  elif command -v bsdtar >/dev/null 2>&1; then
    bsdtar -tf -- "$zip" 2>/dev/null | awk 'tolower($0) ~ /\.safetensors$/ {found=1} END{exit !(found)}'
  else
    echo "⚠️  Need unzip or bsdtar to inspect $zip" >&2
    return 2
  fi
}

# Extract only *.safetensors (case-insensitive) from ZIP into $dest_dir
helpers_extract_safetensors_from_zip() {
  local zip="$1" dest_dir="$2"
  mkdir -p -- "$dest_dir"
  if command -v unzip >/dev/null 2>&1; then
    # unzip is case-sensitive; extract with a broad list then prune
    # Strategy: extract all, then move only *.safetensors (ci via awk), then clean temp
    local tmpdir; tmpdir="$(mktemp -d)"
    unzip -oq -- "$zip" -d "$tmpdir" || return 1
    find "$tmpdir" -type f | awk 'BEGIN{IGNORECASE=1} /\.safetensors$/ {print}' | while read -r f; do
      mv -f -- "$f" "$dest_dir/"
    done
    rm -rf -- "$tmpdir"
    return 0
  elif command -v bsdtar >/dev/null 2>&1; then
    local tmpdir; tmpdir="$(mktemp -d)"
    bsdtar -xf -- "$zip" -C "$tmpdir" || return 1
    find "$tmpdir" -type f | awk 'BEGIN{IGNORECASE=1} /\.safetensors$/ {print}' | while read -r f; do
      mv -f -- "$f" "$dest_dir/"
    done
    rm -rf -- "$tmpdir"
    return 0
  else
    echo "⚠️  Need unzip or bsdtar to extract $zip" >&2
    return 2
  fi
}

# Moves ZIPs into _incoming/, extracts safetensors to the parent dir,
# quarantines ZIPs with no safetensors or suspiciously tiny ones.
helpers_civitai_postprocess_dir() {
  local dest_dir="$1"  # e.g., /workspace/ComfyUI/models/loras
  local incoming="$dest_dir/_incoming"
  local junk="$incoming/_junk"
  mkdir -p -- "$incoming" "$junk"

  # scan recent .zip (last 2 hours) OR just all .zip if you prefer:
  find "$dest_dir" -maxdepth 1 -type f -name '*.zip' -printf '%T@ %p\n' \
    | sort -nr \
    | awk '{ $1=""; sub(/^ /,""); print }' \
    | while read -r zip; do
        # skip if already in _incoming/_junk (safety)
        case "$zip" in
          "$incoming"/*|"$junk"/*) continue ;;
        esac

        # move into _incoming
        local moved="$incoming/$(basename "$zip")"
        mv -f -- "$zip" "$moved" || continue

        # quick size sanity (<= 64 KB → likely metadata-only)
        local bytes; bytes="$(stat -c %s "$moved" 2>/dev/null || stat -f %z "$moved")"
        if [[ -n "$bytes" && "$bytes" -le 65536 ]]; then
          echo "⚠️  $(basename "$moved") is tiny ($bytes B) — no extraction; quarantining." >&2
          mv -f -- "$moved" "$junk/"
          continue
        fi

        if helpers_zip_has_safetensors "$moved"; then
          if helpers_extract_safetensors_from_zip "$moved" "$dest_dir"; then
            echo "✅ Extracted safetensors from $(basename "$moved"); removing ZIP." >&2
            rm -f -- "$moved"
          else
            echo "⚠️  Extraction failed for $(basename "$moved"); quarantining." >&2
            mv -f -- "$moved" "$junk/"
          fi
        else
          echo "⚠️  No .safetensors found in $(basename "$moved"); quarantining." >&2
          mv -f -- "$moved" "$junk/"
        fi
      done
}

# --- ID parsing: "1,2  3,,4" -> "1 2 3 4" (numbers only), drop placeholders
helpers_civitai_tokenize_ids() {
  printf '%s' "$1" \
    | tr ',\n' '  ' \
    | tr -s ' ' \
    | grep -Eo '[0-9]+' \
    || true
}

# --- Make a direct VERSION download URL; token goes in query string
helpers_civitai_make_url() {
  local ver_id="$1"
  local tok="${CIVITAI_TOKEN:-}"
  local url="https://civitai.com/api/download/models/${ver_id}"
  [[ -n "$tok" ]] && url="${url}?token=${tok}"
  printf '%s\n' "$url"
}

# --- Optional light probe (1-byte range GET); set CIVITAI_PROBE=0 to skip
helpers_civitai_probe_url() {
  local url="$1"
  [[ "${CIVITAI_PROBE:-0}" == "0" ]] && return 0
  curl -fsSL --range 0-0 \
       -H 'User-Agent: curl/8' -H 'Accept: */*' \
       --retry 2 --retry-delay 1 \
       --connect-timeout 6 --max-time 12 \
       "$url" -o /dev/null
}

# --- Fetch VERSION json (for filename)
helpers_civitai_get_version_json() {
  local ver_id="$1"
  local hdr=()
  [[ -n "${CIVITAI_TOKEN:-}" ]] && hdr+=(-H "Authorization: Bearer ${CIVITAI_TOKEN}")
  curl -fsSL "${hdr[@]}" "https://civitai.com/api/v1/model-versions/${ver_id}"
}

# --- Choose a filename (prefer *.safetensors; fall back to first file name)
helpers_civitai_pick_name() {
  jq -r '
    (.files // []) as $f
    | ( $f | map(select((.name // "" | ascii_downcase | endswith(".safetensors")))) ) as $s
    | ( ($s | if length>0 then . else $f end) | .[0].name // empty )
  '
}

# --- Enqueue a single VERSION into aria2 RPC; returns 0 if enqueued
civitai_download_versionid() {
  local ver_id="$1" dest_dir="$2"
  local vjson name url

  vjson="$(helpers_civitai_get_version_json "$ver_id")" || {
    [[ "$CIVITAI_DEBUG" -eq 1 ]] && echo "❌ v${ver_id}: version JSON fetch failed" >&2
    return 1
  }

  name="$(printf '%s' "$vjson" | helpers_civitai_pick_name)"
  if [[ -z "$name" ]]; then
    [[ "$CIVITAI_DEBUG" -eq 1 ]] && echo "❌ v${ver_id}: no filename in files[]" >&2
    return 1
  fi

  url="$(helpers_civitai_make_url "$ver_id")"

  # Optional 1-byte probe; disable with CIVITAI_PROBE=0
  if ! helpers_civitai_probe_url "$url"; then
    [[ "$CIVITAI_DEBUG" -eq 1 ]] && echo "❌ v${ver_id}: URL probe failed" >&2
    return 1
  fi

  mkdir -p "$dest_dir"

  # IMPORTANT: 4th param is checksum in your helpers; pass empty string.
  # Do NOT pass headers here (token is already in the URL).
  if helpers_rpc_add_uri "$url" "$dest_dir" "$name" ""; then
    echo "📥 CivitAI v${ver_id}" >&2
    return 0
  else
    echo "❌ v${ver_id}: addUri failed" >&2
    return 1
  fi
}

# --- Batch: parse env lists, enqueue to correct dirs, run your progress loop
aria2_enqueue_and_wait_from_civitai() {
  aria2_clear_results >/dev/null 2>&1 || true
  helpers_have_aria2_rpc || aria2_start_daemon

  local trapped=0
  _cleanup_trap_civitai() {
    (( trapped )) && return 0
    trapped=1
    echo; echo "⚠️  Interrupted — stopping queue and cleaning results…" >&2
    aria2_stop_all >/dev/null 2>&1 || true
    aria2_clear_results >/dev/null 2>&1 || true
    return 130
  }
  trap _cleanup_trap_civitai INT TERM

  local comfy="${COMFY_HOME:-/workspace/ComfyUI}"
  local lora_dir="$comfy/models/loras"
  local ckpt_dir="$comfy/models/checkpoints"
  echo "📦 Target (LoRAs): $lora_dir" >&2
  echo "📦 Target (Checkpoints): $ckpt_dir" >&2

  local any=0 ids vid

  # LoRA version IDs
  ids="$(helpers_civitai_tokenize_ids "${LORAS_IDS_TO_DOWNLOAD:-}")"
  if [[ -n "${ids// }" ]]; then
    [[ "$CIVITAI_DEBUG" -eq 1 ]] && echo "→ Parsed $(wc -w <<<"$ids") LoRA id(s): $ids" >&2
    for vid in $ids; do
      if civitai_download_versionid "$vid" "$lora_dir"; then any=1; fi
    done
  else
    echo "⏭️ No LoRA id(s) parsed." >&2
  fi

  # Checkpoint version IDs
  ids="$(helpers_civitai_tokenize_ids "${CHECKPOINT_IDS_TO_DOWNLOAD:-}")"
  if [[ -n "${ids// }" ]]; then
    [[ "$CIVITAI_DEBUG" -eq 1 ]] && echo "→ Parsed $(wc -w <<<"$ids") Checkpoint id(s): $ids" >&2
    for vid in $ids; do
      if civitai_download_versionid "$vid" "$ckpt_dir"; then any=1; fi
    done
  else
    echo "⏭️ No Checkpoint id(s) parsed."
  fi

  if [[ "$any" != "1" ]]; then
    echo "Nothing to enqueue from CivitAI tokens." >&2
    trap - INT TERM
    return 0
  fi

  # Use your existing nice progress UI
  aria2_monitor_progress "${ARIA2_PROGRESS_INTERVAL:-30}" "${ARIA2_PROGRESS_BAR_WIDTH:-40}" \
    "${COMFY_LOGS:-/workspace/logs}/aria2_progress.log"

  aria2_clear_results >/dev/null 2>&1 || true
  trap - INT TERM
  return 0
}

show_env () {
  # ----- Convenience environment echo -----
  echo "======================================="
  echo "🧠 Environment Summary"
  echo "======================================="
  echo ""
  echo "COMFY_HOME:           $COMFY_HOME"
  echo ""
  echo "Custom nodes dir:     $CUSTOM_DIR"
  echo "Cache dir:            $CACHE_DIR"
  echo "Logs dir:             $COMFY_LOGS"
  echo "Output dir:           $OUTPUT_DIR"
  echo "Bundles dir:          $BUNDLES_DIR"
  echo "Bundle tag:           $CUSTOM_NODES_BUNDLE_TAG"
  echo "Workflow dir:         $WORKFLOW_DIR"
  echo "Model manifest URL:   $MODEL_MANIFEST_URL"
  echo ""
  echo "DIFFUSION_MODELS_DIR: $DIFFUSION_MODELS_DIR"
  echo "TEXT_ENCODERS_DIR:    $TEXT_ENCODERS_DIR"
  echo "CLIP_VISION_DIR:      $CLIP_VISION_DIR"
  echo "VAE_DIR:              $VAE_DIR"
  echo "LORAS_DIR:            $LORAS_DIR"
  echo "DETECTION_DIR:        $DETECTION_DIR"
  echo "CTRL_DIR:             $CTRL_DIR"
  echo "UPSCALE_DIR:          $UPSCALE_DIR"
  echo ""
  echo "HF_TOKEN:             $(if [ -n "$HF_TOKEN" ]; then echo "Set"; else echo "Not set"; fi)"
  echo "CIVITAI_TOKEN:        $(if [ -n "$CIVITAI_TOKEN" ]; then echo "Set"; else echo "Not set"; fi)"
  echo "CHECKPOINT_IDS:       ${CHECKPOINT_IDS_TO_DOWNLOAD:-Empty}"
  echo "LORAS_IDS:            ${LORAS_IDS_TO_DOWNLOAD:-Empty}"
  echo "======================================="
  echo ""
  hf_repo_info
  echo ""
  echo "======================================="

}