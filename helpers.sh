#!/usr/bin/env bash
# ======================================================================
# helpers.sh — Golden edition
#   - No hardcoded /workspace paths (respects COMFY_HOME/CACHE_DIR/etc.)
#   - Minimal, consistent Hugging Face vars (HF_REPO_ID, HF_REPO_TYPE, HF_TOKEN, CN_BRANCH)
#   - Clear function groups with docs
#   - Safe, idempotent, parallel node installation
#   - Bundle pull-or-build logic keyed by BUNDLE_TAG + PINS
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
#   REPO_URL             - ComfyUI repo URL (default comfyanonymous/ComfyUI)
#   GIT_DEPTH            - default 1
#   MAX_NODE_JOBS        - default 6..8
# Optional (SageAttention build):
#   SAGE_COMMIT, SAGE_GENCODE, TORCH_CUDA_ARCH_LIST, NVCC_APPEND_FLAGS, EXT_PARALLEL, MAX_JOBS
# Hugging Face:
#   HF_REPO_ID           - e.g. user/comfyui-bundles
#   HF_REPO_TYPE         - dataset | model (default dataset)
#   HF_TOKEN             - auth token
#   CN_BRANCH            - default main
#   HF_API_BASE          - default https://huggingface.co
#   BUNDLE_TAG           - logical “set” name (e.g. WAN2122_Baseline)
# Pins/signature:
#   PINS                 - computed by pins_signature() if not set

# Provide reasonable fallbacks if .env forgot any
: "${REPO_URL:=https://github.com/comfyanonymous/ComfyUI}"
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
# Section 1: Generic utilities
# ======================================================================

# tg: Telegram notify (best-effort)
tg() {
  if [ -n "${TELEGRAM_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=$1" >/dev/null || true
  fi
}

# need_tools_for_hf: Ensure git, git-lfs, jq available
need_tools_for_hf() {
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y jq git git-lfs >/dev/null 2>&1 || true
  git lfs install --system || true
}

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

# needs_recursive: mark repos that need --recursive
needs_recursive() {
  case "$1" in
    *ComfyUI_UltimateSDUpscale*) echo "true" ;;
    *) echo "false" ;;
  esac
}

# ======================================================================
# Section 2: ComfyUI core management
# ======================================================================

# ensure_comfy: Install or hard-reset ComfyUI at COMFY_HOME
ensure_comfy() {
  if [[ -d "$COMFY_HOME/.git" && -f "$COMFY_HOME/main.py" ]]; then
    git -C "$COMFY_HOME" fetch --depth=1 origin || true
    git -C "$COMFY_HOME" reset --hard origin/master 2>/dev/null \
      || git -C "$COMFY_HOME" reset --hard origin/main 2>/dev/null || true
  else
    rm -rf "$COMFY_HOME"
    git clone --depth=1 "$REPO_URL" "$COMFY_HOME"
  fi

  "$PIP_BIN" install -U pip wheel setuptools
  [ -f "$COMFY_HOME/requirements.txt" ] && "$PIP_BIN" install -r "$COMFY_HOME/requirements.txt" || true
  ln -sfn "$COMFY_HOME" /ComfyUI
}

# build_sage: Build SageAttention at a specific commit (expects torch dev env ready)
#   $1 commit (e.g. 68de379)
build_sage() {
  local commit="${1:?commit}"
  ( set -e
    cd /tmp
    rm -rf SageAttention
    git clone https://github.com/thu-ml/SageAttention.git
    cd SageAttention
    git reset --hard "$commit"

    export MAX_JOBS="${MAX_JOBS:-32}"
    export EXT_PARALLEL="${EXT_PARALLEL:-4}"
    export NVCC_APPEND_FLAGS="${NVCC_APPEND_FLAGS:---threads 8}"
    export FORCE_CUDA=1
    export CXX="${CXX:-g++}" CC="${CC:-gcc}"
    export EXTRA_NVCCFLAGS="${SAGE_GENCODE:-}"

    "$PIP_BIN" install --no-build-isolation -e .
  )
}

# ======================================================================
# Section 3: Custom node installation (parallel)
# ======================================================================

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
# Section 4: Bundling (create/push/pull)
# ======================================================================

# hf_remote_url: builds authenticated HTTPS remote for model/dataset repos
hf_remote_url() {
  : "${HF_TOKEN:?missing HF_TOKEN}" "${HF_REPO_ID:?missing HF_REPO_ID}"
  local host="huggingface.co"
  [ "${HF_REPO_TYPE:-dataset}" = "dataset" ] && host="${host}/datasets"
  echo "https://oauth2:${HF_TOKEN}@${host}/${HF_REPO_ID}.git"
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

# hf_fetch_latest_bundle: pull newest matching bundle for tag+pins into CACHE_DIR
#   echoes local tgz path or empty
hf_fetch_latest_bundle() {
  local tag="${1:?tag}" pins="${2:?pins}"
  local tmp="${CACHE_DIR}/.hf_pull.$$"
  mkdir -p "$CACHE_DIR"; rm -rf "$tmp"
  git lfs install
  git clone --depth=1 "$(hf_remote_url)" "$tmp" >/dev/null 2>&1 || { rm -rf "$tmp"; return 0; }
  local patt="bundles/$(bundle_base "$tag" "$pins")"; patt="${patt%_*}_*.tgz"
  local matches=()
  mapfile -t matches < <(cd "$tmp" && ls -1 $patt 2>/dev/null | sort)
  if (( ${#matches[@]} == 0 )); then rm -rf "$tmp"; return 0; fi
  local latest="${matches[-1]}"
  ( cd "$tmp"
    git lfs fetch --include="$latest" >/dev/null 2>&1 || true
    git lfs pull  --include="$latest" >/dev/null 2>&1 || true
    cp -f "$latest" "$CACHE_DIR/$(basename "$latest")"
  )
  local out="${CACHE_DIR}/$(basename "$latest")"
  rm -rf "$tmp"
  echo "$out"
}

# build_nodes_manifest: create JSON manifest of installed nodes
build_nodes_manifest() {
  local tag="${1:?tag}" out="${2:?out_json}"
  "$PY_BIN" - <<PY
import json, os, subprocess, sys
d = os.environ["CUSTOM_DIR"]
items = []
for name in sorted(os.listdir(d)):
    p = os.path.join(d, name)
    if not os.path.isdir(p) or not os.path.isdir(os.path.join(p, ".git")):
        continue
    def run(*args):
        return subprocess.check_output(["git"," -C", p, *args], text=True).strip()
    try:
        url = subprocess.check_output(["git","-C",p,"config","--get","remote.origin.url"], text=True).strip()
    except Exception: url = ""
    try:
        ref = subprocess.check_output(["git","-C",p,"rev-parse","HEAD"], text=True).strip()
    except Exception: ref = ""
    try:
        br = subprocess.check_output(["git","-C",p,"rev-parse","--abbrev-ref","HEAD"], text=True).strip()
    except Exception: br = ""
    items.append({"name": name, "path": p, "origin": url, "branch": br, "commit": ref})
with open(sys.argv[1], "w") as f:
    json.dump({"tag": os.environ.get("BUNDLE_TAG",""), "nodes": items}, f, indent=2)
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

  build_nodes_manifest "$tag" "$manifest"
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

# ensure_nodes_from_bundle_or_build:
#   If HF has a bundle matching BUNDLE_TAG + PINS → install it
#   Else build from NODES and optionally push a fresh bundle
ensure_nodes_from_bundle_or_build() {
  local tag="${BUNDLE_TAG:?BUNDLE_TAG required}"
  local pins="${PINS:-$(pins_signature)}"
  mkdir -p "$CACHE_DIR" "$CUSTOM_DIR" "$CUSTOM_LOG_DIR"

  echo "[custom-nodes] Looking for bundle tag=${tag}, pins=${pins}…"
  local tgz; tgz="$(hf_fetch_latest_bundle "$tag" "$pins")"
  if [[ -n "$tgz" && -s "$tgz" ]]; then
    echo "[custom-nodes] Found bundle: $(basename "$tgz") — installing"
    install_custom_nodes_bundle "$tgz"
    return 0
  fi

  # Resolve the list once, log how many we got, then pass it in.
  local -a RESOLVED_NODES=()
  resolve_nodes_list RESOLVED_NODES
  echo "[custom-nodes] RESOLVED_NODES count: ${#RESOLVED_NODES[@]}"
  if (( ${#RESOLVED_NODES[@]} == 0 )); then
    echo "[custom-nodes] ERROR: Node list is empty. Check CUSTOM_NODE_LIST_FILE / CUSTOM_NODE_LIST / DEFAULT_NODES."
    return 2
  fi

  install_custom_nodes_set RESOLVED_NODES || return $?

  if [[ "${PUSH_BUNDLE:-0}" = "1" ]]; then
    local base tarpath manifest reqs sha
    base="$(bundle_base "$tag" "$pins")"
    tarpath="$(build_custom_nodes_bundle "$tag" "$pins")"
    manifest="${CACHE_DIR}/$(manifest_name "$tag")"
    reqs="${CACHE_DIR}/$(reqs_name "$tag")"
    sha="${CACHE_DIR}/$(sha_name "$base")"
    echo "[custom-nodes] Pushing bundle + metadata to HF…"
    hf_push_files "bundle ${base}" "$tarpath" "$sha" "$manifest" "$reqs"
  fi
}

# push_bundle_if_requested: convenience wrapper (respects BUNDLE_TAG/PINS)
push_bundle_if_requested() {
  [[ "${PUSH_BUNDLE:-0}" = "1" ]] || return 0
  local tag="${BUNDLE_TAG:?BUNDLE_TAG required}"
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
      printf "  - %-*s [%s]\n" "$maxw" "$name" "$dir"
    done
  fi
  echo

  # --- Downloading (active transfers) ---
  echo "Downloading (active transfers)"
  echo "--------------------------------------------------------------------------------"
  if (( active_count == 0 )); then
    echo "  (none)"
  else
    local -a dl_rows
    local row done tot spd path pct bar_len bar W dir name

    W="${ARIA2_PROGRESS_BAR_WIDTH:-40}"

    # Extract simple TSV from the active array
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
      # skip if no path (shouldn’t really happen, but be safe)
      [[ -z "$path" ]] && continue

      # Cast to integers
      done=$((done+0))
      tot=$((tot+0))
      spd=$((spd+0))

      # Percentage (integer)
      pct=0
      (( tot > 0 )) && pct=$(( done * 100 / tot ))

      # Build progress bar
      bar_len=$(( W * pct / 100 ))
      printf -v bar '%*s' "$bar_len" ''
      bar=${bar// /#}
      printf -v bar '%-*s' "$W" "$bar"

      # Split path into dir + name
      dir="${path%/*}"
      name="${path##*/}"

      # Trim COMFY / COMFY_HOME prefix if present
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

  # --- Completed (this session) ---
  echo "Completed (this session)"
  echo "--------------------------------------------------------------------------------"
  if (( completed_count == 0 )); then
    echo "  (none)"
    echo "--------------------------------------------------------------------------------"
  else
    local -a completed_rows
    mapfile -t completed_rows < <(
      jq -r '
        .[]?
        | select(.status == "complete")
        | (.files[0].path // "") as $p
        | if $p == "" then empty else
            ($p | capture("(?<dir>.*)/(?<name>[^/]+)$")) as $m
            | (.totalLength // 0 | tonumber) as $len
            | "\($m.name)\t\($m.dir)\t\($len)"
          end
      ' <<<"$sto" 2>/dev/null || true
    )

    if ((${#completed_rows[@]} == 0)); then
      echo "  (none)"
      echo "--------------------------------------------------------------------------------"
    else
      # Reuse your helpers_print_completed_block
      helpers_print_completed_block "${completed_rows[@]}"
      echo "--------------------------------------------------------------------------------"
    fi
  fi

  # --- Group totals (active + waiting) ---
  local total_done total_size total_speed merged
  merged="$(jq -c --argjson a "$act" --argjson w "$wai" '$a + $w' 2>/dev/null || echo '[]')"

  total_done="$(jq -r '[.[]? | (.completedLength//"0"|tonumber)] | add // 0' <<<"$merged" 2>/dev/null || echo 0)"
  total_size="$(jq -r '[.[]? | (.totalLength//"0"|tonumber)]    | add // 0' <<<"$merged" 2>/dev/null || echo 0)"
  total_speed="$(jq -r '[.[]? | (.downloadSpeed//"0"|tonumber)] | add // 0' <<<"$merged" 2>/dev/null || echo 0)"

  # Simple local human-bytes, in case helpers_human_bytes isn't ideal here
  aria2__hb() {
    local n="$1"
    if [[ -z "$n" || "$n" == "0" ]]; then
      printf "0 Bytes"
      return
    fi
    local u value
    if   (( n >= 1099511627776 )); then u="TB"; value=$(( n/1099511627776 ))
    elif (( n >= 1073741824    )); then u="GB"; value=$(( n/1073741824 ))
    elif (( n >= 1048576       )); then u="MB"; value=$(( n/1048576 ))
    elif (( n >= 1024          )); then u="KB"; value=$(( n/1024 ))
    else u="Bytes"; value=$n
    fi
    printf "%d %s" "$value" "$u"
  }

  echo "Group total: speed $(aria2__hb "$total_speed")/s, done $(aria2__hb "$total_done") / $(aria2__hb "$total_size")"

  set -e
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