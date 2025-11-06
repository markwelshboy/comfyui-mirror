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

#=====================================================================
# Section 5: Aria2-Based Model Downloads (uses json manifest)
#===================================================================== 

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

# ---------- Internals ----------
_helpers_need() { command -v "$1" >/dev/null || { echo "Missing $1" >&2; exit 1; }; }

_helpers_tok_json() {
  if [[ -n "$ARIA2_SECRET" ]]; then printf '"token:%s",' "$ARIA2_SECRET"; fi
}

helpers_have_aria2_rpc() {
  curl -s "http://${ARIA2_HOST:-127.0.0.1}:${ARIA2_PORT:-6800}/jsonrpc" \
    -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","id":"v","method":"aria2.getVersion","params":["token:'"${ARIA2_SECRET:-KissMeQuick}"'"]}' \
    | jq -e '.result.version' >/dev/null 2>&1
}

helpers_start_aria2_daemon() {
  if helpers_have_aria2_rpc; then
    helpers_log "aria2 RPC already running." "▶"
    return 0
  fi
  helpers_log "Starting aria2 RPC daemon…" "▶"
  aria2c --no-conf \
    --enable-rpc \
    --rpc-secret="${ARIA2_SECRET:-KissMeQuick}" \
    --rpc-listen-port="${ARIA2_PORT:-6800}" \
    --rpc-listen-all=false \
    --daemon=true \
    --check-certificate=true \
    --min-tls-version=TLSv1.2 \
    --max-concurrent-downloads="${ARIA2_MAX_CONC:-8}" \
    --continue=true \
    --file-allocation=none \
    --summary-interval=0 \
    --show-console-readout=false \
    --console-log-level=warn \
    --log="${COMFY_LOGS:-/workspace/logs}/aria2.log" \
    --log-level=notice \
    ${ARIA2_EXTRA_OPTS:-}
  sleep 0.2
  helpers_have_aria2_rpc || { helpers_log "aria2 RPC failed to start" "❌"; return 1; }
}

# Resolve {VARNAME} placeholders against a JSON map
helpers_resolve_placeholders() {
  local string="$1" map_json="$2"
  jq -nr --arg s "$string" --argjson map "$map_json" '
    def subvars($m):
      reduce ($m|to_entries[]) as $e ($s; gsub("\\{"+($e.key)+"\\}"; ($e.value|tostring)) );
    $s | subvars($map)
  '
}

# Optional: quiet, opt-in URL probe that won't spam logs
helpers_probe_url() {
  # Usage: helpers_probe_url "<url>"
  # Returns 0 if HEAD/GET looks good, else non-zero.
  local url="$1"
  [[ -z "$url" ]] && return 0
  # Default OFF; set ARIA2_PROBE=1 to enable probing
  [[ "${ARIA2_PROBE:-0}" != "1" ]] && return 0

  local to="${ARIA2_PROBE_TIMEOUT:-10}"
  local rt="${ARIA2_PROBE_RETRIES:-0}"

  # HEAD is often enough; some endpoints don’t like HEAD, so fall back to GET if HEAD fails.
  # stderr is suppressed unless DEBUG/CIVITAI_DEBUG/ARIA2_DEBUG is set.
  if curl -sSIL -m "$to" --retry "$rt" --retry-all-errors -o /dev/null "$url" 2>"/tmp/.probe.$$"; then
    return 0
  fi
  if curl -sSL  -m "$to" --retry "$rt" --retry-all-errors -o /dev/null "$url" 2>>"/tmp/.probe.$$"; then
    return 0
  fi

  if [[ -n "${DEBUG}${CIVITAI_DEBUG}${ARIA2_DEBUG}" ]]; then
    echo "⚠️  Probe failed for: $url"
    sed -n '1,8p' "/tmp/.probe.$$" || true
  fi
  rm -f "/tmp/.probe.$$"
  return 1
}

# Ensure the destination file is either skipped (exists/valid) or ready to enqueue (dir made).
# Usage: helpers_ensure_target_ready "<abs_path>" ["<source_url_for_optional_probe>"]
# Returns 0 = enqueue, 1 = skip (already exists & sane)
helpers_ensure_target_ready() {
  local target="$1"; local src_url="${2:-}"
  [[ -z "$target" ]] && return 1

  local dir; dir="$(dirname -- "$target")"
  mkdir -p -- "$dir"

  # If already present and non-zero size, skip with human size
  if [[ -s "$target" ]]; then
    local sz; sz="$(helpers_human_bytes "$(stat -c%s -- "$target" 2>/dev/null || wc -c <"$target")")"
    echo "✅ $(basename -- "$target") exists (${sz}), skipping."
    return 1
  fi

  # Optional, quiet URL probe (OFF by default)
  if ! helpers_probe_url "$src_url"; then
    # Don’t block the queue; just proceed silently (aria2 will handle retries/auth)
    : # no-op
  end

  return 0
}

# ---------- MAIN: download selected sections from manifest ----------
helpers_download_from_manifest() {
  _helpers_need curl; _helpers_need jq; _helpers_need awk

  if [[ -z "${MODEL_MANIFEST_URL:-}" ]]; then
    echo "MODEL_MANIFEST_URL is not set." >&2
    return 1
  fi

  local MAN; MAN="$(mktemp)"
  curl -fsSL "$MODEL_MANIFEST_URL" -o "$MAN" || {
    echo "Failed to fetch manifest: $MODEL_MANIFEST_URL" >&2
    return 1
  }

  # Build placeholder map = vars + paths + current env (env can override)
  local VARS_JSON
  VARS_JSON="$(
    jq -n --slurpfile m "$MAN" '
      ($m[0].vars // {}) as $v
      | ($m[0].paths // {}) as $p
      | ($v + $p)
    '
  )"
  # Merge uppercase env into map (env wins)
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^[A-Z0-9_]+$ ]] || continue
    VARS_JSON="$(jq --arg k "$k" --arg v "$v" '. + {($k):$v}' <<<"$VARS_JSON")"
  done < <(env)

  # Which sections are enabled? either export <section>=true or download_<section>=true
  local SECTIONS_ALL ENABLED sec
  SECTIONS_ALL="$(jq -r '.sections | keys[]' "$MAN")"
  ENABLED=()
  while read -r sec; do
    if [[ "${!sec:-}" == "true" || "${!sec:-}" == "1" ]]; then ENABLED+=("$sec"); fi
    local dl_var="download_${sec}"
    if [[ "${!dl_var:-}" == "true" || "${!dl_var:-}" == "1" ]]; then ENABLED+=("$sec"); fi
  done <<<"$SECTIONS_ALL"

  if ((${#ENABLED[@]}==0)); then
    echo "No sections enabled. Available:"
    echo "$SECTIONS_ALL" | sed 's/^/  - /'
    return 0
  fi
  mapfile -t ENABLED < <(printf '%s\n' "${ENABLED[@]}" | awk '!seen[$0]++')

  helpers_have_aria2_rpc || helpers_start_aria2_daemon
  helpers_reset_enqueued

  local url raw_path path dir out gid
  for sec in "${ENABLED[@]}"; do
    echo ">>> Enqueue section: $sec"

    jq -r --arg sec "$sec" --arg default_dir "${DEFAULT_DOWNLOAD_DIR:-$COMFY}" '
      def as_obj:
        if (type=="object") then
          {url:(.url // ""), path:(.path // ((.dir // "") + (if .out then "/" + .out else "" end)))}
        elif (type=="array") then
          {url:(.[0] // ""), path:(.[1] // "")}
        elif (type=="string") then
          {url:., path:""}
        else
          {url:"", path:""}
        end;
      (.sections[$sec] // [])[] | as_obj
      | .url as $u
      | ( if (.path|length) > 0 then .path
          else ( if ($default_dir|length) > 0
                then ($default_dir + "/" + ($u|sub("^.*/";"")))
                else (               ($u|sub("^.*/";"")) )
                end )
          end ) as $p
      | select(($u|type)=="string" and ($p|type)=="string" and ($u|length)>0 and ($p|length)>0)
      | [$u, $p] | @tsv
    ' "$MAN" | while IFS=$'\t' read -r url raw_path; do
          [[ -z "$url" || -z "$raw_path" ]] && { echo "⚠️  Skipping invalid item"; continue; }

          path="$(helpers_resolve_placeholders "$raw_path" "$VARS_JSON")"
          dir="$(dirname -- "$path")"
          out="$(basename -- "$path")"
          mkdir -p -- "$dir"

          if helpers_ensure_target_ready "$path" "$url"; then
            echo "📥 Queue: $(basename -- "$path")"
            gid="$(helpers_rpc_add_uri "$url" "$dir" "$out" "")"
            helpers_record_gid "$gid"
          fi
    done
  done
  echo "✅ Enqueued selected sections."
}

helpers_human_bytes() {
  # usage: helpers_human_bytes <bytes>
  local n=${1:-0}
  if (( n < 1024 )); then printf "%d B" "$n"
  elif (( n < 1048576 )); then printf "%d KB" $((n/1024))
  elif (( n < 1073741824 )); then printf "%d MB" $((n/1048576))
  else printf "%d GB" $((n/1073741824))
  fi
}

# log helper (since your new pod said "helpers_log: command not found")
helpers_log() { printf "%s %s\n" "${2:-ℹ️}" "$1"; }

# Human bytes (you already have something similar; safe default)
human_bytes() {
  local b=${1:-0} s=0 S=(B KB MB GB TB)
  while ((b>=1024 && s<${#S[@]}-1)); do b=$((b/1024)); s=$((s+1)); done
  printf "%d %s" "$b" "${S[$s]}"
}

# ---------- Progress snapshots (append-friendly; no clear by default) ----------
helpers_progress_snapshot_loop() {
  _helpers_need curl; _helpers_need jq

  local interval="${1:-${ARIA2_PROGRESS_INTERVAL:-5}}"
  local bar_w="${2:-${ARIA2_PROGRESS_BAR_WIDTH:-40}}"
  local log_file="${3:-}"
  local comfy_root="${COMFY_HOME:-/workspace/ComfyUI}"

  local endpoint="http://${ARIA2_HOST:-127.0.0.1}:${ARIA2_PORT:-6800}/jsonrpc"
  local tok=""; [[ -n "${ARIA2_SECRET:-}" ]] && tok="token:${ARIA2_SECRET}"

  draw_bar() {
    local done=${1:-0} total=${2:-0} width=${3:-40}
    local pct=0 fill=0 empty=$width
    (( total > 0 )) && pct=$(( done*100/total ))
    fill=$(( pct*width/100 )); (( fill > width )) && fill=$width
    empty=$(( width-fill ))
    printf "%3d%% [" "$pct"
    printf '%*s' "$fill" '' | tr ' ' '#'
    printf '%*s' "$empty" '' | tr ' ' ' '
    printf "]"
  }

  local idle_streak=0

  while :; do
    local loop_start; loop_start="$(date +%s)"

    # ----- Global stat -----
    local payload_g='{"jsonrpc":"2.0","id":"g","method":"aria2.getGlobalStat","params":['
    [[ -n "$tok" ]] && payload_g+="\"$tok\""
    payload_g+=']}'
    local resp_g; resp_g="$(curl -sS --fail "$endpoint" -H 'Content-Type: application/json' \
                       --data-binary "$payload_g" 2>/dev/null || echo 'null')"

    # Coerce to numeric 0 even if null/empty
    local active_n waiting_n stopped_n
    active_n="$( jq -r 'try ((.result // .).numActive  | tonumber) catch 0' <<<"$resp_g" )"
    waiting_n="$(jq -r 'try ((.result // .).numWaiting | tonumber) catch 0' <<<"$resp_g" )"
    stopped_n="$(jq -r 'try ((.result // .).numStopped | tonumber) catch 0' <<<"$resp_g" )"
    [[ -z "$active_n"  ]] && active_n=0
    [[ -z "$waiting_n" ]] && waiting_n=0
    [[ -z "$stopped_n" ]] && stopped_n=0

    # ----- Active list -----
    local payload_a='{"jsonrpc":"2.0","id":"a","method":"aria2.tellActive","params":['
    [[ -n "$tok" ]] && payload_a+="\"$tok\","
    payload_a+='["gid","status","totalLength","completedLength","downloadSpeed","files"]]}'
    local resp_a; resp_a="$(curl -sS --fail "$endpoint" -H 'Content-Type: application/json' \
                      --data-binary "$payload_a" 2>/dev/null || echo 'null')"
    local A; A="$(jq -c 'try ((.result // .) | if type=="array" then . else [] end) catch []' <<<"$resp_a")"

    # Reset arrays every tick (prevents stale lines)
    local -a act_name=() act_done=() act_tot=() act_spd=() act_path=() act_destdir=()
    local i=0 max_name_len=0

    while IFS=$'\t' read -r name done tot spd fullpath; do
      # guard numbers
      [[ -z "$done" ]] && done=0
      [[ -z "$tot"  ]] && tot=0
      [[ -z "$spd"  ]] && spd=0

      # Derive destination (relative to COMFY_HOME)
      local rel="$fullpath"
      if [[ -n "$comfy_root" && "$rel" == "$comfy_root"* ]]; then
        rel="${rel#$comfy_root/}"
      fi
      local destdir; destdir="$(dirname -- "$rel")"
      [[ "$destdir" == models/* ]] || destdir="$rel"
      [[ "$destdir" == */ ]] && destdir="${destdir%/}"

      act_name[i]="$name"
      act_done[i]="$done"
      act_tot[i]="$tot"
      act_spd[i]="$spd"
      act_path[i]="$fullpath"
      act_destdir[i]="$destdir"
      (( ${#name} > max_name_len )) && max_name_len=${#name}
      ((i++))
    done < <( jq -r '
        .[]
        | . as $it
        | ($it.totalLength   |tonumber? // 0) as $tot
        | ($it.completedLength|tonumber? // 0) as $done
        | ($it.downloadSpeed |tonumber? // 0) as $spd
        | ( if ($it.files|type)=="array" and ($it.files|length)>0
            then ($it.files[0].path // "unknown")
            else "unknown" end ) as $path
        | ($path | split("/") | last) as $name
        | [$name, ($done|tostring), ($tot|tostring), ($spd|tostring), $path] | @tsv
      ' <<<"$A" )

    # Totals (force 0 if empty)
    local total_speed total_done total_size
    total_speed="$(jq -r '[.[].downloadSpeed|tonumber? // 0] | add // 0' <<<"$A")"; [[ -z "$total_speed" ]] && total_speed=0
    total_done="$( jq -r '[.[].completedLength|tonumber? // 0] | add // 0' <<<"$A")"; [[ -z "$total_done"  ]] && total_done=0
    total_size="$( jq -r '[.[].totalLength    |tonumber? // 0] | add // 0' <<<"$A")"; [[ -z "$total_size"  ]] && total_size=0

    # ----- Completed (last 12) & longest name -----
    local payload_s='{"jsonrpc":"2.0","id":"s","method":"aria2.tellStopped","params":['
    [[ -n "$tok" ]] && payload_s+="\"$tok\","
    payload_s+='0,200,["status","totalLength","files","errorMessage"]]}'
    local resp_s; resp_s="$(curl -sS --fail "$endpoint" -H 'Content-Type: application/json' \
                      --data-binary "$payload_s" 2>/dev/null || echo 'null')"
    local S; S="$(jq -c 'try ((.result // .) | if type=="array" then . else [] end) catch []' <<<"$resp_s")"

    local -a comp_name=() comp_len=() comp_path=()
    local comp_count=0 comp_max_name=0
    while IFS=$'\t' read -r cname clen cpath; do
      [[ -z "$clen" ]] && clen=0
      comp_name[comp_count]="$cname"
      comp_len[comp_count]="$clen"
      comp_path[comp_count]="$cpath"
      (( ${#cname} > comp_max_name )) && comp_max_name=${#cname}
      ((comp_count++))
    done < <( jq -r '
        [ .[]
          | select(.status=="complete")
          | ( if (.files|type)=="array" and (.files|length)>0
              then .files[0].path else "" end ) as $path
          | ($path|split("/")|last) as $name
          | (.totalLength|tonumber? // 0) as $len
          | [$name, ($len|tostring), $path] ]
        | .[-12:] // [] | .[] | @tsv
      ' <<<"$S" )

    # ----- Failed (last 10 errors) -----
    local failed_block
    failed_block="$( jq -r '
        [ .[]
          | select(.status=="error")
          | ( if (.files|type)=="array" and (.files|length)>0
              then .files[0].path else "" end ) as $path
          | (.errorMessage // "Unknown error") as $msg
          | ($path|split("/")|last) as $name
          | [$name, $msg, $path] ] | .[-10:] // []
          | if length==0 then "" else
              ( "Failed (recent):\n--------------------------------------------------------------------------------\n"
                + ( map("✖ " + .[0] + "  —  " + .[1]) | join("\n") ) + "\n" )
            end
      ' <<<"$S")"

    # ----- Render snapshot -----
    {
      local now; now="$(date '+%Y-%m-%d %H:%M:%S')"
      echo "=== aria2 progress @ $now ==="

      if (( ${#act_name[@]} > 0 )); then
        echo "Active (${#act_name[@]})"
        echo "--------------------------------------------------------------------------------"
        local rows="${#act_name[@]}"
        for ((i=0;i<rows;i++)); do
          draw_bar "${act_done[i]}" "${act_tot[i]}" "$bar_w"
          printf "  %6s/s  (%s / %s)  " \
            "$(helpers_human_bytes "${act_spd[i]}")" \
            "$(helpers_human_bytes "${act_done[i]}")" \
            "$(helpers_human_bytes "${act_tot[i]}")"
          printf "[ Destination -> %s ] " "${act_destdir[i]}"
          printf "%-*s\n" "$max_name_len" "${act_name[i]}"
        done
        echo "--------------------------------------------------------------------------------"
      else
        echo "Active (0)"
        echo "--------------------------------------------------------------------------------"
      fi

      printf "Group total: speed %s/s, done %s / %s\n" \
        "$(helpers_human_bytes "$total_speed")" \
        "$(helpers_human_bytes "$total_done")" \
        "$(helpers_human_bytes "$total_size")"

      if (( total_speed > 0 )) && (( total_size >= total_done )) && (( total_size > 0 )); then
        local remain=$(( total_size - total_done ))
        local eta=$(( remain / total_speed ))
        printf "ETA: %02d:%02d\n" $((eta/60)) $((eta%60))
      fi

      # Completed (aligned names)
      if (( comp_count > 0 )); then
        echo
        echo "Completed (this session)"
        echo "--------------------------------------------------------------------------------"

        # Compute max filename width safely (avoid null/empty)
        local comp_max_name=0
        local j=0
        while (( j < comp_count )); do
          # guard: ensure name exists
          local _nm="${comp_name[j]}"
          local _len=${#_nm}
          (( _len > comp_max_name )) && comp_max_name=$_len
          (( j++ ))
        done
        # minimum width to keep the column from collapsing
        (( comp_max_name < 8 )) && comp_max_name=8

        # Print rows
        j=0
        while (( j < comp_count )); do
          # path relative to comfy root → "models/…"
          local rel="${comp_path[j]}"
          if [[ -n "$comfy_root" && "$rel" == "$comfy_root"* ]]; then
            rel="${rel#$comfy_root/}"
          fi

          # human size (bytes → e.g., "26 GB")
          local hsize
          hsize="$(helpers_human_bytes "${comp_len[j]}")"

          # aligned print
          printf "✔ %-*s  %s  (%s)\n" \
            "$comp_max_name" "${comp_name[j]}" \
            "$rel" \
            "$hsize"

          (( j++ ))
        done
      fi

      # Failed summary (if any)
      if [[ -n "$failed_block" ]]; then
        echo
        printf "%s" "$failed_block"
      fi

      echo
    } | { if [[ -n "$log_file" ]]; then tee -a "$log_file"; else cat; fi; }

    # ----- Exit logic -----
    if (( active_n == 0 && waiting_n == 0 )); then
      ((idle_streak++))
    else
      idle_streak=0
    fi
    if (( idle_streak >= 2 )); then
      echo "✅ All downloads complete — exiting progress loop."
      break
    fi

    # precise interval
    local loop_end; loop_end="$(date +%s)"
    local elapsed=$(( loop_end - loop_start ))
    local sleep_for=$(( interval - elapsed ))
    (( sleep_for < 1 )) && sleep_for=1
    sleep "$sleep_for"
  done
}

# ---------- RPC helpers ----------

_aria2_endpoint() { printf "http://%s:%s/jsonrpc" "${ARIA2_HOST:-127.0.0.1}" "${ARIA2_PORT:-6800}"; }
_aria2_tok()      { [[ -n "${ARIA2_SECRET:-}" ]] && printf '"token:%s",' "$ARIA2_SECRET"; }

# Call: _aria2_rpc <method> [params_json_without_token_prefix]
# Example: _aria2_rpc aria2.getGlobalStat
#          _aria2_rpc aria2.tellWaiting '0,1000,["gid","status"]'
_aria2_rpc() {
  local m="$1"; shift || true
  local params="$*"
  local tok; tok="$(_aria2_tok)"
  [[ -n "$params" ]] && params=",$params"
  curl -sS --fail "$(_aria2_endpoint)" -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"method\":\"$m\",\"params\":[${tok%?}${params#,*}]}" \
    || echo 'null'
}

# Utility: return array (one per line) of GIDs for a tell* result
_aria2_gids_from() {
  jq -r 'try (.result // .) | if type=="array" then . else [] end | .[].gid // empty catch empty'
}

# ----- Stop/kill all ACTIVE + WAITING -----
aria2_stop_all() {
  echo "⏹️  Stopping all active + waiting downloads…"
  # Active
  _aria2_rpc aria2.tellActive '["gid","status"]' | _aria2_gids_from | while read -r gid; do
    echo "  • forceRemove ACTIVE $gid"
    _aria2_rpc aria2.forceRemove "\"$gid\"" >/dev/null || true
  done
  # Waiting (queue)
  _aria2_rpc aria2.tellWaiting '0,1000,["gid","status"]' | _aria2_gids_from | while read -r gid; do
    echo "  • remove WAITING $gid"
    _aria2_rpc aria2.remove "\"$gid\"" >/dev/null || true
  done
  # A tiny grace
  sleep 1
}

# ----- Clear COMPLETED + FAILED results from aria2 memory -----
aria2_clear_results() {
  echo "🧹 Clearing stopped (completed/failed) results…"
  # Remove per-GID records (keeps finished files on disk)
  _aria2_rpc aria2.tellStopped '0,1000,["gid","status"]' | _aria2_gids_from | while read -r gid; do
    echo "  • removeDownloadResult $gid"
    _aria2_rpc aria2.removeDownloadResult "\"$gid\"" >/dev/null || true
  done
  # Purge any leftover result cache
  echo "  • purgeDownloadResult"
  _aria2_rpc aria2.purgeDownloadResult >/dev/null || true
}

# ----- Full nuke convenience: stop -> clear -> optional partial cleanup -> daemon shutdown -----
aria2_nuke_all() {
  local partial_root="${1:-${COMFY_HOME:-/workspace/ComfyUI}/models}"

  aria2_stop_all
  aria2_clear_results

  # Optional: cleanup *.aria2 partial stubs under models
  if [[ -d "$partial_root" ]]; then
    echo "🧽 Removing *.aria2 partial files under: $partial_root"
    find "$partial_root" -type f -name '*.aria2' -print -delete 2>/dev/null || true
  fi

  # Try graceful shutdown of the RPC daemon (won’t delete logs/files)
  echo "🛑 Shutting down aria2 daemon…"
  _aria2_rpc aria2.shutdown >/dev/null || true

  # Fallback: hard kill lingering aria2c RPC daemons
  sleep 1
  pkill -f 'aria2c .*--enable-rpc' 2>/dev/null || true
  echo "✅ All queues cleared and daemon stopped."
}

# ----- Tiny diagnostics (optional) -----
aria2_show_counts() {
  local s; s="$(_aria2_rpc aria2.getGlobalStat)"
  printf "Active:%s Waiting:%s Stopped:%s\n" \
    "$(jq -r '(.result//.).numActive  // "0"'  <<<"$s")" \
    "$(jq -r '(.result//.).numWaiting // "0"'  <<<"$s")" \
    "$(jq -r '(.result//.).numStopped // "0"' <<<"$s")"
}

aria2_inspect_gid() {
  local gid="$1"
  [[ -z "$gid" ]] && { echo "Usage: aria2_inspect_gid <gid>"; return 1; }
  local endpoint="http://${ARIA2_HOST:-127.0.0.1}:${ARIA2_PORT:-6800}/jsonrpc"
  local tok=""; [[ -n "${ARIA2_SECRET:-}" ]] && tok="token:${ARIA2_SECRET}"
  curl -s "$endpoint" -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":\"st\",\"method\":\"aria2.tellStatus\",\"params\":[\"$tok\",\"$gid\",[\"status\",\"errorMessage\",\"totalLength\",\"completedLength\",\"files\",\"followedBy\",\"bittorrent\"]]}"
  echo
}

aria2_last_errors() {
  local endpoint="http://${ARIA2_HOST:-127.0.0.1}:${ARIA2_PORT:-6800}/jsonrpc"
  local tok=""; [[ -n "${ARIA2_SECRET:-}" ]] && tok="token:${ARIA2_SECRET}"
  curl -s "$endpoint" -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":\"s\",\"method\":\"aria2.tellStopped\",\"params\":[\"$tok\",0,50,[\"status\",\"errorMessage\",\"files\"]]}" \
  | jq -r '.result[]
     | select(.status=="error")
     | {name:(.files[0].path|split("/")|last), err:(.errorMessage//"Unknown")}
     | "✖ \(.name): \(.err)"'
}

helpers_watch_gids() {
  _helpers_need jq; _helpers_need curl
  local gids=("$@")
  local -A done=()
  while :; do
    local all=1
    for g in "${gids[@]}"; do
      [[ ${done[$g]} ]] && continue
      s="$(curl -s "http://${ARIA2_HOST}:${ARIA2_PORT}/jsonrpc" -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":\"st\",\"method\":\"aria2.tellStatus\",\"params\":[ $(_helpers_tok_json) \"$g\", [\"status\",\"completedLength\",\"totalLength\",\"files\"] ] }")"
      st="$(jq -r '.result.status' <<<"$s")"
      name="$(jq -r '.result.files[0].path // .result.files[0].uris[0].uri' <<<"$s")"
      cl="$(jq -r '.result.completedLength' <<<"$s")"; tl="$(jq -r '.result.totalLength' <<<"$s")"
      printf "%-50.50s  %-9s  %s/%s\n" "$(basename "$name")" "$st" "$cl" "$tl"
      if [[ "$st" == "complete" || "$st" == "error" ]]; then done[$g]=1; fi
    done
    for g in "${gids[@]}"; do [[ ${done[$g]} ]] || { all=0; break; }; done
    (( all )) && break
    sleep "${ARIA2_PROGRESS_INTERVAL:-10}"
  done
}

helpers_rpc_shutdown() {
  curl -s "http://${ARIA2_HOST}:${ARIA2_PORT}/jsonrpc" \
    -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":\"sd\",\"method\":\"aria2.shutdown\",\"params\":[\"token:${ARIA2_SECRET}\"]}" \
    | jq -r '.result // .error.message // "ok"' 2>/dev/null
}

# Return just the host of a URL
_helpers_url_host() { awk -F/ '{print $3}' <<<"$1"; }

# HEAD/redirect probe → prints HTTP status code (or 000 on failure)
_helpers_http_status() {
  local url="$1"
  curl -sS -o /dev/null \
       -I -L \
       --max-redirs "${HF_PROBE_REDIRECTS:-5}" \
       --connect-timeout "${HF_PROBE_TIMEOUT:-5}" \
       --retry "${HF_PROBE_RETRY:-0}" \
       --write-out '%{http_code}' \
       "$url" || printf '000'
}

# Decide if this URL needs HF auth (returns 0/1 printed to stdout)
# Modes:
#   HF_AUTH_MODE=auto (default): probe; send auth only on 401/403
#   HF_AUTH_MODE=always: always attach Authorization for huggingface.co
#   HF_AUTH_MODE=never:  never attach Authorization
_helpers_hf_needs_auth() {
  local url="$1"
  local host; host="$(_helpers_url_host "$url")"
  [[ "$host" =~ (^|\.)(huggingface\.co)$ ]] || { echo 0; return; }

  case "${HF_AUTH_MODE:-auto}" in
    always) echo 1; return ;;
    never)  echo 0; return ;;
    auto|*) :
      local code; code="$(_helpers_http_status "$url")"
      # 401/403 → private/gated, needs token
      if [[ "$code" == "401" || "$code" == "403" ]]; then
        echo 1
      else
        echo 0
      fi
      ;;
  esac
}

helpers_reset_enqueued() {
  : > "$ARIA2_GID_FILE"
}

helpers_record_gid() {
  local gid="$1"
  [[ -n "$gid" && "$gid" != "null" ]] && echo "$gid" >> "$ARIA2_GID_FILE"
}

# Wait until ALL provided GIDs are complete/error/removed.
# Returns 0 if all completed OK, 1 if any ended in error/removed.
helpers_wait_for_gids() {
  _helpers_need curl; _helpers_need jq
  local interval="${1:-${ARIA2_PROGRESS_INTERVAL:-10}}"; shift || true
  local gids=("$@")
  [[ ${#gids[@]} -eq 0 ]] && { echo "No GIDs to wait on." >&2; return 0; }

  declare -A done ok
  while :; do
    # Build system.multicall for all not-done GIDs
    local payload='{"jsonrpc":"2.0","id":"mc","method":"system.multicall","params":[['
    local first=1
    for g in "${gids[@]}"; do
      [[ ${done[$g]} ]] && continue
      [[ $first -eq 0 ]] && payload+=','
      first=0
      if [[ -n "${ARIA2_SECRET:-}" ]]; then
        payload+='{"methodName":"aria2.tellStatus","params":["token:'"${ARIA2_SECRET}"'","'"$g"'",["status","errorMessage","totalLength","completedLength","files"]]}'
      else
        payload+='{"methodName":"aria2.tellStatus","params":["'"$g"'",["status","errorMessage","totalLength","completedLength","files"]]}'
      fi
    done
    payload+=']]}'

    # If nothing pending, break
    if [[ $first -eq 1 ]]; then
      break
    fi

    local resp
    resp="$(curl -s "http://${ARIA2_HOST:-127.0.0.1}:${ARIA2_PORT:-6800}/jsonrpc" \
            -H 'Content-Type: application/json' --data-binary "$payload")"

    local i=0
    for g in "${gids[@]}"; do
      [[ ${done[$g]} ]] && { i=$((i+1)); continue; }
      local node status errmsg
      node="$(jq -r --argjson idx "$i" '.result[$idx]' <<<"$resp")"
      if [[ "$(jq -r 'has("error")' <<<"$node")" == "true" ]]; then
        done[$g]=1; ok[$g]=0
        i=$((i+1))
        continue
      fi
      status="$(jq -r '.result.status // "unknown"' <<<"$node")"
      errmsg="$(jq -r '.result.errorMessage // ""' <<<"$node")"

      case "$status" in
        complete) done[$g]=1; ok[$g]=1 ;;
        error|removed) done[$g]=1; ok[$g]=0; [[ -n "$errmsg" ]] && echo "✖ $g error: $errmsg" >&2 ;;
        *) ;;
      esac
      i=$((i+1))
    done

    # All done?
    local all=1; for g in "${gids[@]}"; do [[ ${done[$g]} ]] || { all=0; break; }; done
    (( all )) && break

    sleep "$interval"
  done

  local any_bad=0; for g in "${gids[@]}"; do [[ "${ok[$g]}" == "1" ]] || any_bad=1; done
  return $any_bad
}

# Convenience: wait on everything recorded in $ARIA2_GID_FILE
helpers_wait_for_enqueued() {
  local interval="${1:-${ARIA2_PROGRESS_INTERVAL:-10}}"
  [[ -f "$ARIA2_GID_FILE" ]] || { echo "No GID file: $ARIA2_GID_FILE" >&2; return 0; }
  mapfile -t gids < <(awk 'NF' "$ARIA2_GID_FILE" | awk '!seen[$0]++')
  helpers_wait_for_gids "$interval" "${gids[@]}"
}

# Run progress UI until specific GIDs finish, then exit
helpers_progress_until_done() {
  local interval="${1:-${ARIA2_PROGRESS_INTERVAL:-10}}"; shift || true
  local gids=("$@")
  [[ ${#gids[@]} -eq 0 ]] && { echo "No GIDs to watch." >&2; return 0; }
  helpers_progress_snapshot_loop "$interval" "${ARIA2_PROGRESS_BAR_WIDTH:-40}" "${COMFY_LOGS:-/workspace/logs}/aria2_progress.log" &
  local snap_pid=$!
  helpers_wait_for_gids "$interval" "${gids[@]}"
  local rc=$?
  kill "$snap_pid" >/dev/null 2>&1 || true
  wait "$snap_pid" 2>/dev/null || true
  return $rc
}

aria2_enqueue_and_wait_from_manifest() {
  local man_url="${MODEL_MANIFEST_URL:-}"
  [[ -z "$man_url" ]] && { echo "MODEL_MANIFEST_URL is not set." >&2; return 1; }

  # start from a clean slate (doesn't delete files)
  aria2_clear_results >/dev/null 2>&1 || true

  # Ensure daemon
  helpers_have_aria2_rpc || helpers_start_aria2_daemon

  # Graceful INT/TERM handling
  local trapped=0
  _cleanup_trap_manifest() {
    (( trapped )) && return 0
    trapped=1
    echo; echo "⚠️  Interrupted — stopping queue and cleaning results…"
    aria2_stop_all >/dev/null 2>&1 || true
    aria2_clear_results >/dev/null 2>&1 || true
    # Don’t kill the daemon here; other tasks may still use it
    return 130
  }
  trap _cleanup_trap_manifest INT TERM

  # Enqueue selections
  local any=0
  echo "▶ Starting aria2 RPC daemon…"
  any="$(helpers_download_from_manifest || echo 0)"

  if [[ "$any" == "0" ]]; then
    echo "Nothing enqueued. Exiting without starting progress loop."
    trap - INT TERM
    return 0
  fi

  # Foreground progress loop — exits itself when queue drains
  helpers_progress_snapshot_loop "${ARIA2_PROGRESS_INTERVAL:-5}" "${ARIA2_PROGRESS_BAR_WIDTH:-40}" \
    "${COMFY_LOGS:-/workspace/logs}/aria2_progress.log"

  # Clear stopped results _after_ a successful run (fresh list next time)
  aria2_clear_results >/dev/null 2>&1 || true

  trap - INT TERM
  return 0
}

helpers_rpc_count_pending() {
  _helpers_need curl; _helpers_need jq
  local endpoint="http://${ARIA2_HOST:-127.0.0.1}:${ARIA2_PORT:-6800}/jsonrpc"
  local tok=""; [[ -n "${ARIA2_SECRET:-}" ]] && tok="token:${ARIA2_SECRET}"

  # tellActive
  local payload_a='{"jsonrpc":"2.0","id":"a","method":"aria2.tellActive","params":['
  [[ -n "$tok" ]] && payload_a+="\"$tok\","
  payload_a+='["gid"]]}'
  local ra; ra="$(curl -sS --fail "$endpoint" -H 'Content-Type: application/json' --data-binary "$payload_a" 2>/dev/null || echo 'null')"
  local A_len; A_len="$(jq 'try ((.result // .) | length) catch 0' <<<"$ra")"

  # tellWaiting
  local payload_w='{"jsonrpc":"2.0","id":"w","method":"aria2.tellWaiting","params":['
  [[ -n "$tok" ]] && payload_w+="\"$tok\","
  payload_w+='0,200,["gid"]]}'
  local rw; rw="$(curl -sS --fail "$endpoint" -H 'Content-Type: application/json' --data-binary "$payload_w" 2>/dev/null || echo 'null')"
  local W_len; W_len="$(jq 'try ((.result // .) | length) catch 0' <<<"$rw")"

  echo $(( A_len + W_len ))
}

helpers_rpc_add_uri() {
  local url="$1" dir="$2" out="$3" checksum="${4:-}"

  # Concurrency knobs (global defaults)
  local split_n="${SPLIT:-16}"
  local mconn_n="${MCONN:-16}"
  local chunk_sz="${CHUNK:-1M}"

  # If host is HF, optionally downshift (gentler on their CDN)
  local host; host="$(_helpers_url_host "$url")"
  if [[ "$host" =~ (^|\.)(huggingface\.co)$ ]]; then
    split_n="${HF_SPLIT:-${split_n}}"
    mconn_n="${HF_MCONN:-${mconn_n}}"
    chunk_sz="${HF_CHUNK:-${chunk_sz}}"
  fi

  # bytes → integer for aria2 RPC
  _helpers_parse_size_bytes() {
    local s="${1:-1M}"
    case "$s" in
      *K|*k) gawk -v n="${s%[Kk]}" 'BEGIN{printf "%d", n*1024}' ;;
      *M|*m) gawk -v n="${s%[Mm]}" 'BEGIN{printf "%d", n*1024*1024}' ;;
      *G|*g) gawk -v n="${s%[Gg]}" 'BEGIN{printf "%d", n*1024*1024*1024}' ;;
      *)     printf '%s' "$s" ;;
    esac
  }
  local chunk_b; chunk_b="$(_helpers_parse_size_bytes "$chunk_sz")"

  # Decide whether to attach Authorization for this specific URL
  local send_auth; send_auth="$(_helpers_hf_needs_auth "$url")"
  if [[ "$send_auth" == "1" && -z "${HF_TOKEN:-}" ]]; then
    echo "⚠️  HF auth required by probe, but HF_TOKEN is not set. Proceeding without Authorization; may fail." >&2
    send_auth=0
  fi

  # Build per-download options
  local opt req resp gid err
  opt="$(
    jq -n \
      --arg dir "$dir" \
      --arg out "$out" \
      --arg hf "${HF_TOKEN:-}" \
      --arg chk "$checksum" \
      --arg host "$host" \
      --argjson split "$split_n" \
      --argjson mconn "$mconn_n" \
      --argjson chunk "$chunk_b" \
      --argjson send_auth "$send_auth" '
        {
          dir: $dir,
          out: $out,
          continue: true,
          split: $split,
          "max-connection-per-server": $mconn,
          "min-split-size": $chunk
        }
        | if $send_auth==1 then .header = [ "Authorization: Bearer \($hf)" ] else . end
        | if ($chk|length)>0 then .checksum=("sha-256="+$chk) else . end
      '
  )"

  req="$(
    jq -n \
      --arg url "$url" \
      --argjson opt "$opt" \
      --arg tok "${ARIA2_SECRET:-}" '
        {
          jsonrpc:"2.0",
          id:"add",
          method:"aria2.addUri",
          params: (
            ( if ($tok|length)>0 then ["token:"+$tok] else [] end )
            + [[ $url ]]
            + [ $opt ]
          )
        }'
  )"

  resp="$(
    printf '%s' "$req" \
    | curl -s "http://${ARIA2_HOST:-127.0.0.1}:${ARIA2_PORT:-6800}/jsonrpc" \
            -H 'Content-Type: application/json' \
            --data-binary @-
  )"

  # Optional debug
  if [[ "${DEBUG_ARIA2:-0}" == "1" ]]; then
    echo "---- addUri request ----" >&2;  echo "$req"  | jq . >&2
    echo "---- addUri response ----" >&2; echo "$resp" | jq . >&2 || echo "$resp" >&2
  fi

  gid="$(jq -r 'select(.result) | .result' <<<"$resp" 2>/dev/null || true)"
  err="$(jq -r 'select(.error)  | .error.message' <<<"$resp" 2>/dev/null || true)"

  if [[ -n "$gid" && "$gid" != "null" ]]; then
    echo "$gid"
    return 0
  fi

  echo "❌ aria2.addUri failed for: $out" >&2
  echo "    URL: $url" >&2
  if [[ -n "$err" && "$err" != "null" ]]; then
    echo "    Error: $err" >&2
  else
    echo "    Raw response: $resp" >&2
  fi
  return 1
}

#=======================================================================================
#
# ---------- CivitAI ID downloader helpers ----------
#
#=======================================================================================

# Env it uses (override in .env):
: "${CHECKPOINT_IDS_TO_DOWNLOAD:=}"     # e.g. "12345, 67890, 23422:i2v"
: "${LORAS_IDS_TO_DOWNLOAD:=}"          # e.g. "abc, def ghi"
: "${CIVITAI_LOG_DIR:=${COMFY_LOGS:-/workspace/logs}/civitai}"

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
# Requires (already present in your stack):
#   helpers_rpc_add_uri, helpers_have_aria2_rpc, helpers_start_aria2_daemon,
#   helpers_progress_snapshot_loop, aria2_clear_results, aria2_stop_all

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
    echo "📦 Extracted: $(basename -- "$dest")"
    ((moved++))
  done
  shopt -u nullglob

  # Cleanup temp + leave original ZIP (or delete—your call)
  rm -rf -- "$tmpdir"

  if (( moved == 0 )); then
    echo "⚠️  No .safetensors found in ZIP: $(basename -- "$zip_path")"
    # Option A: keep ZIP in place (already in loras dir)
    # Option B (recommended): park it in an _incoming folder so it’s out of the picker’s way
    local park_dir="${target_dir%/}/_incoming"
    mkdir -p "$park_dir"
    mv -f -- "$zip_path" "$park_dir/" || true
    echo "➡️  Moved ZIP to: $park_dir/$(basename -- "$zip_path")"
  else
    # If at least one .safetensors extracted, remove the ZIP
    rm -f -- "$zip_path"
  fi
}

# Case-insensitive match for *.safetensors
_helpers_zip_has_safetensors() {
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
_helpers_extract_safetensors_from_zip() {
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
          echo "⚠️  $(basename "$moved") is tiny ($bytes B) — no extraction; quarantining."
          mv -f -- "$moved" "$junk/"
          continue
        fi

        if _helpers_zip_has_safetensors "$moved"; then
          if _helpers_extract_safetensors_from_zip "$moved" "$dest_dir"; then
            echo "✅ Extracted safetensors from $(basename "$moved"); removing ZIP."
            rm -f -- "$moved"
          else
            echo "⚠️  Extraction failed for $(basename "$moved"); quarantining."
            mv -f -- "$moved" "$junk/"
          fi
        else
          echo "⚠️  No .safetensors found in $(basename "$moved"); quarantining."
          mv -f -- "$moved" "$junk/"
        fi
      done
}

# Print aligned "Completed (this session)" block from a list of "name<TAB>relpath<TAB>size"
helpers_print_completed_block() {
  local lines=("$@")
  [[ ${#lines[@]} -eq 0 ]] && return 0

  local maxlen=0
  local name relpath size
  # find longest name
  for row in "${lines[@]}"; do
    IFS=$'\t' read -r name relpath size <<<"$row"
    (( ${#name} > maxlen )) && maxlen=${#name}
  done

  echo
  echo "Completed (this session)"
  echo "--------------------------------------------------------------------------------"
  for row in "${lines[@]}"; do
    IFS=$'\t' read -r name relpath size <<<"$row"
    printf "✔ %-*s  %s  (%s)\n" "$maxlen" "$name" "$relpath" "$size"
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
  [[ "${CIVITAI_PROBE:-1}" == "0" ]] && return 0
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
helpers_civitai_enqueue_version() {
  local ver_id="$1" dest_dir="$2"
  local vjson name url

  vjson="$(helpers_civitai_get_version_json "$ver_id")" || {
    [[ -n "$CIVITAI_DEBUG" ]] && echo "❌ v${ver_id}: version JSON fetch failed" >&2
    return 1
  }

  name="$(printf '%s' "$vjson" | helpers_civitai_pick_name)"
  if [[ -z "$name" ]]; then
    [[ -n "$CIVITAI_DEBUG" ]] && echo "❌ v${ver_id}: no filename in files[]" >&2
    return 1
  fi

  url="$(helpers_civitai_make_url "$ver_id")"

  # Optional 1-byte probe; disable with CIVITAI_PROBE=0
  if ! helpers_civitai_probe_url "$url"; then
    [[ -n "$CIVITAI_DEBUG" ]] && echo "❌ v${ver_id}: URL probe failed" >&2
    return 1
  fi

  mkdir -p "$dest_dir"

  # IMPORTANT: 4th param is checksum in your helpers; pass empty string.
  # Do NOT pass headers here (token is already in the URL).
  if helpers_rpc_add_uri "$url" "$dest_dir" "$name" ""; then
    [[ -n "$CIVITAI_DEBUG" ]] && {
      echo "📥 CivitAI v${ver_id}"
      echo "   URL : $url"
      echo "   OUT : ${dest_dir%/}/$name"
    }
    return 0
  else
    [[ -n "$CIVITAI_DEBUG" ]] && echo "❌ v${ver_id}: addUri failed" >&2
    return 1
  fi
}

# --- Batch: parse env lists, enqueue to correct dirs, run your progress loop
aria2_enqueue_and_wait_from_civitai() {
  aria2_clear_results >/dev/null 2>&1 || true
  helpers_have_aria2_rpc || helpers_start_aria2_daemon

  local trapped=0
  _cleanup_trap_civitai() {
    (( trapped )) && return 0
    trapped=1
    echo; echo "⚠️  Interrupted — stopping queue and cleaning results…"
    aria2_stop_all >/dev/null 2>&1 || true
    aria2_clear_results >/dev/null 2>&1 || true
    return 130
  }
  trap _cleanup_trap_civitai INT TERM

  local comfy="${COMFY_HOME:-/workspace/ComfyUI}"
  local lora_dir="$comfy/models/loras"
  local ckpt_dir="$comfy/models/checkpoints"
  echo "📦 Target (LoRAs): $lora_dir"
  echo "📦 Target (Checkpoints): $ckpt_dir"

  local any=0 ids vid

  # LoRA version IDs
  ids="$(helpers_civitai_tokenize_ids "${LORAS_IDS_TO_DOWNLOAD:-}")"
  if [[ -n "${ids// }" ]]; then
    [[ -n "$CIVITAI_DEBUG" ]] && echo "→ Parsed $(wc -w <<<"$ids") LoRA id(s): $ids"
    for vid in $ids; do
      if helpers_civitai_enqueue_version "$vid" "$lora_dir"; then any=1; fi
    done
  else
    [[ -n "$CIVITAI_DEBUG" ]] && echo "⏭️ No LoRA id(s) parsed."
  fi

  # Checkpoint version IDs
  ids="$(helpers_civitai_tokenize_ids "${CHECKPOINT_IDS_TO_DOWNLOAD:-}")"
  if [[ -n "${ids// }" ]]; then
    [[ -n "$CIVITAI_DEBUG" ]] && echo "→ Parsed $(wc -w <<<"$ids") Checkpoint id(s): $ids"
    for vid in $ids; do
      if helpers_civitai_enqueue_version "$vid" "$ckpt_dir"; then any=1; fi
    done
  else
    [[ -n "$CIVITAI_DEBUG" ]] && echo "⏭️ No Checkpoint id(s) parsed."
  fi

  if [[ "$any" != "1" ]]; then
    echo "Nothing to enqueue from CivitAI tokens."
    trap - INT TERM
    return 0
  fi

  # Use your existing nice progress UI
  helpers_progress_snapshot_loop "${ARIA2_PROGRESS_INTERVAL:-30}" "${ARIA2_PROGRESS_BAR_WIDTH:-40}" \
    "${COMFY_LOGS:-/workspace/logs}/aria2_progress.log"

  aria2_clear_results >/dev/null 2>&1 || true
  trap - INT TERM
  return 0
}