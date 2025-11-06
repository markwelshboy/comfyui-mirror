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
: "${ARIA2_PROGRESS_INTERVAL:=5}"
: "${ARIA2_PROGRESS_BAR_WIDTH:=40}"
: "${COMFY:=/workspace/ComfyUI}"
: "${COMFY_LOGS:=/workspace/logs}"

mkdir -p "$COMFY_LOGS" "$COMFY/models" >/dev/null 2>&1 || true

# ---- tiny utils ----
helpers_human_bytes() { # bytes -> human
  local b=${1:-0} d=0 unit=Bytes
  local -a u=(Bytes KB MB GB TB PB)
  while (( b >= 1024 && d < ${#u[@]}-1 )); do b=$((b/1024)); ((d++)); done
  printf "%d %s" "$b" "${u[$d]}"
}

# Replace the existing helpers_resolve_placeholders with this:
helpers_resolve_placeholders() {
  # Replace ${VARNAME} with value from provided JSON map (first) or env (fallback)
  # Args: 1=template string (may contain ${FOO}), 2=json map string
  local tmpl="$1" json="${2:-{}}"
  local out="$tmpl"

  # Fast bail if no ${...}
  [[ "$out" != *'${'* ]] && { printf '%s' "$out"; return 0; }

  # Expand all ${NAME} occurrences
  local before="$out" var key val
  # Limit to avoid infinite loops if someone embeds weird patterns
  for _ in {1..50}; do
    if [[ "$out" =~ (\$\{[A-Z0-9_]+\}) ]]; then
      var="${BASH_REMATCH[1]}"
      key="${var:2:${#var}-3}"
      # lookup in JSON then env
      val="$(jq -r --arg k "$key" '.[ $k ] // env[$k] // empty' <<<"$json")"
      # If still empty, replace with nothing (or keep raw; choose one)
      out="${out//$var/$val}"
    else
      break
    fi
    # If nothing changed, stop
    [[ "$out" == "$before" ]] && break
    before="$out"
  done

  printf '%s' "$out"
}

# ---- RPC core ----
helpers_rpc_post() {
  local payload="$1"
  curl -fsS --connect-timeout 2 "http://$ARIA2_HOST:$ARIA2_PORT/jsonrpc" \
    -H 'Content-Type: application/json' --data "$payload"
}

helpers_rpc_ping() {
  helpers_rpc_post '{"jsonrpc":"2.0","id":"v","method":"aria2.getVersion","params":["token:'"$ARIA2_SECRET"'"]}' \
    >/dev/null 2>&1
}

helpers_have_aria2_rpc() { helpers_rpc_ping; }

helpers_start_aria2_daemon() {
  # don’t double-start
  if helpers_have_aria2_rpc; then return 0; fi
  mkdir -p "$COMFY_LOGS" >/dev/null 2>&1 || true
  aria2c --no-conf \
    --enable-rpc --rpc-secret="$ARIA2_SECRET" \
    --rpc-listen-port="$ARIA2_PORT" --rpc-listen-all=false \
    --daemon=true \
    --check-certificate=true --min-tls-version=TLSv1.2 \
    --max-concurrent-downloads="${ARIA2_MAX_CONC:-8}" \
    --continue=true --file-allocation=none \
    --summary-interval=0 --show-console-readout=false \
    --console-log-level=warn \
    --log="$COMFY_LOGS/aria2.log" --log-level=notice \
    >/dev/null 2>&1 || true
  # wait a beat
  for _ in {1..20}; do helpers_have_aria2_rpc && return 0; sleep 0.2; done
  return 1
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

# clear results
aria2_clear_results() {
  helpers_rpc_ping || return 0
  helpers_rpc_post '{"jsonrpc":"2.0","id":"pd","method":"aria2.purgeDownloadResult","params":["token:'"$ARIA2_SECRET"'"]}' >/dev/null 2>&1 || true
}

# stop all (jq 1.5-safe)
aria2_stop_all() {
  echo "⏹️  Stopping all active + waiting downloads…"
  helpers_rpc_ping || { echo "⚠️  RPC not reachable"; return 0; }
  local tok="token:${ARIA2_SECRET}"

  helpers_rpc_post '{"jsonrpc":"2.0","id":"a","method":"aria2.tellActive","params":["'"$tok"'"]}' \
    | jq -r '(.result // []) | .[]? | .gid // empty' \
    | while read -r gid; do
        helpers_rpc_post '{"jsonrpc":"2.0","id":"ra","method":"aria2.remove","params":["'"$tok"'","'"$gid"'"]}' >/dev/null 2>&1 || true
      done
  helpers_rpc_post '{"jsonrpc":"2.0","id":"w","method":"aria2.tellWaiting","params":["'"$tok"'",0,1000]}' \
    | jq -r '(.result // []) | .[]? | .gid // empty' \
    | while read -r gid; do
        helpers_rpc_post '{"jsonrpc":"2.0","id":"rw","method":"aria2.remove","params":["'"$tok"'","'"$gid"'"]}' >/dev/null 2>&1 || true
      done
  helpers_rpc_post '{"jsonrpc":"2.0","id":"p","method":"aria2.pauseAll","params":["'"$tok"'"]}' >/dev/null 2>&1 || true
  helpers_rpc_post '{"jsonrpc":"2.0","id":"pd","method":"aria2.purgeDownloadResult","params":["'"$tok"'"]}' >/dev/null 2>&1 || true
}

# (no-op book-keeping hooks; keep for compatibility)
helpers_reset_enqueued() { return 0; }
helpers_record_gid() { :; }
helpers_probe_url() { return 0; }  # silenced

# ---- One-shot progress snapshot (aligned) ----
helpers_progress_snapshot_once() {
  local bar_w="${1:-40}"
  local tok="token:${ARIA2_SECRET}"

  # Active
  local active; active="$(helpers_rpc_post '{"jsonrpc":"2.0","id":"a","method":"aria2.tellActive","params":["'"$tok"'"]}')" || active='{}'
  local names=() sizes=() dones=() speeds=() dirs=()

  #mapfile -t names < <(jq -r '(.result // [])[] | (.files[0].path // .bittorrent.info.name // .infoHash // "unknown") | split("/") | last' <<<"$active")
  #mapfile -t dirs  < <(jq -r '(.result // [])[] | (.files[0].path // "unknown") | split("/") | .[0:-1] | join("/")' <<<"$active")
  #mapfile -t sizes < <(jq -r '(.result // [])[] | (.totalLength // 0)' <<<"$active")
  #mapfile -t dones < <(jq -r '(.result // [])[] | (.completedLength // 0)' <<<"$active")
  #mapfile -t speeds < <(jq -r '(.result // [])[] | (.downloadSpeed // 0)' <<<"$active")

  # Replace the 4 mapfile lines in helpers_progress_snapshot_once with:
  mapfile -t names < <(jq -r '
    (.result // [])[]
    | ( .files[0].path
        // .bittorrent.info.name
        // .infoHash
        // .gid
        // "unknown" )' <<<"$active" | awk -F/ '{print $NF}')
  mapfile -t dirs  < <(jq -r '(.result // [])[] | (.files[0].path // "") | split("/") | .[0:-1] | join("/")' <<<"$active")
  mapfile -t sizes < <(jq -r '(.result // [])[] | (.totalLength // 0)' <<<"$active")
  mapfile -t dones < <(jq -r '(.result // [])[] | (.completedLength // 0)' <<<"$active")
  mapfile -t speeds < <(jq -r '(.result // [])[] | (.downloadSpeed // 0)' <<<"$active")

  local i n="${#names[@]}" maxn=0
  for ((i=0;i<n;i++)); do ((${#names[i]} > maxn)) && maxn=${#names[i]}; done
  (( maxn < 24 )) && maxn=24

  echo "=== aria2 progress @ $(date +"%Y-%m-%d %H:%M:%S") ==="
  echo "Active ($n)"
  echo "--------------------------------------------------------------------------------"

  local total_done=0 total_size=0 total_speed=0
  for ((i=0;i<n;i++)); do
    local name="${names[i]}" size="${sizes[i]:-0}" done="${dones[i]:-0}" sp="${speeds[i]:-0}" dir="${dirs[i]}"
    (( total_done+=done, total_size+=size, total_speed+=sp ))
    local pct=0; (( size>0 )) && pct=$(( (done*100)/size ))
    local fill=$(( (pct*bar_w)/100 ))
    local bar; printf -v bar "%${fill}s" ""; bar=${bar// /#}
    local pad; printf -v pad "%$((bar_w-fill))s" ""; pad=${pad// /" "}
    printf " %3d%% [%s%s] %6s/s  (%s / %s)  [ Destination -> %s ] %s\n" \
      "$pct" "$bar" "$pad" \
      "$(helpers_human_bytes "$sp")" \
      "$(helpers_human_bytes "$done")" \
      "$(helpers_human_bytes "$size")" \
      "${dir#$COMFY/}" \
      "$(printf "%-${maxn}s" "$name")"
  done

  echo "--------------------------------------------------------------------------------"
  printf "Group total: speed %s/s, done %s / %s\n" \
    "$(helpers_human_bytes "$total_speed")" \
    "$(helpers_human_bytes "$total_done")" \
    "$(helpers_human_bytes "$total_size")"
  if (( total_speed > 0 && total_size >= total_done && total_size > 0 )); then
    local remain=$(( total_size - total_done )) eta=$(( remain / total_speed ))
    printf "ETA: %02d:%02d\n" $((eta/60)) $((eta%60))
  fi

  # Completed (this session)
  local stopped; stopped="$(helpers_rpc_post '{"jsonrpc":"2.0","id":"s","method":"aria2.tellStopped","params":["'"$tok"'",0,999]}' )" || stopped='{}'
  local cnames=() cpaths=() clens=()
  mapfile -t cnames < <(jq -r '(.result // [])[] | select(.status=="complete") | (.files[0].path // "unknown") | split("/") | last' <<<"$stopped")
  mapfile -t cpaths < <(jq -r '(.result // [])[] | select(.status=="complete") | (.files[0].path // "unknown")' <<<"$stopped")
  mapfile -t clens  < <(jq -r '(.result // [])[] | select(.status=="complete") | (.totalLength // 0)' <<<"$stopped")

  if ((${#cnames[@]} > 0)); then
    local m=0 j
    for ((j=0;j<${#cnames[@]};j++)); do ((${#cnames[j]} > m)) && m=${#cnames[j]}; done
    (( m < 24 )) && m=24
    echo
    echo "Completed (this session)"
    echo "--------------------------------------------------------------------------------"
    for ((j=0;j<${#cnames[@]};j++)); do
      local rel="${cpaths[j]}"
      [[ -n "$COMFY" && "$rel" == "$COMFY"* ]] && rel="${rel#$COMFY/}"
      printf "✔ %-*s  %s  (%s)\n" \
        "$m" "${cnames[j]}" \
        "$rel" \
        "$(helpers_human_bytes "${clens[j]}")"
    done
  fi
}

# ---- Foreground progress with trap ----
helpers_progress_snapshot_loop() {
  local interval="${1:-5}" bar_w="${2:-40}" logf="${3:-$COMFY_LOGS/aria2_progress.log}"
  (
    while :; do
      helpers_progress_snapshot_once "$bar_w" | tee -a "$logf"
      sleep "$interval"
      helpers_have_aria2_rpc || exit 0
      local tok="token:${ARIA2_SECRET}" act wait
      act="$(helpers_rpc_post '{"jsonrpc":"2.0","id":"a","method":"aria2.tellActive","params":["'"$tok"'"]}' \
            | jq -r '(.result // []) | length' 2>/dev/null)" || act=0
      wait="$(helpers_rpc_post '{"jsonrpc":"2.0","id":"w","method":"aria2.tellWaiting","params":["'"$tok"'",0,1]}' \
            | jq -r '(.result // []) | length' 2>/dev/null)" || wait=0
      if [[ "${act:-0}" -eq 0 && "${wait:-0}" -eq 0 ]]; then
        echo; echo "✅ All downloads complete — exiting progress loop."; exit 0
      fi
    done
  ) &
  local loop_pid=$!
  trap 'echo; echo "⚠️  Interrupted — stopping queue…"; aria2_stop_all; kill -TERM '"$loop_pid"' 2>/dev/null || true; wait '"$loop_pid"' 2>/dev/null; return 130' INT TERM
  wait "$loop_pid"
  trap - INT TERM
}

# ---- Manifest Enqueue ----
# Replace helpers_download_from_manifest with this:
helpers_download_from_manifest() {
  command -v curl >/dev/null && command -v jq >/dev/null || { echo "Need curl + jq"; return 1; }
  [[ -z "${MODEL_MANIFEST_URL:-}" ]] && { echo "MODEL_MANIFEST_URL is not set." >&2; return 1; }

  local MAN; MAN="$(mktemp)"
  curl -fsSL "$MODEL_MANIFEST_URL" -o "$MAN" || { echo "Failed to fetch manifest: $MODEL_MANIFEST_URL" >&2; return 1; }

  # Build vars map (manifest vars/paths merged with UPPERCASE env)
  local VARS_JSON
  VARS_JSON="$(
    jq -n --slurpfile m "$MAN" '
      ($m[0].vars // {}) as $v
      | ($m[0].paths // {}) as $p
      | ($v + $p)
    '
  )"
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^[A-Z0-9_]+$ ]] || continue
    VARS_JSON="$(jq --arg k "$k" --arg v "$v" '. + {($k):$v}' <<<"$VARS_JSON")"
  done < <(env)

  # Determine enabled sections
  local SECTIONS_ALL ENABLED sec
  SECTIONS_ALL="$(jq -r '.sections | keys[]' "$MAN")"
  ENABLED=()
  while read -r sec; do
    if [[ "${!sec:-}" == "true" || "${!sec:-}" == "1" ]]; then ENABLED+=("$sec"); fi
    local dl_var="download_${sec}"
    if [[ "${!dl_var:-}" == "true" || "${!dl_var:-}" == "1" ]]; then ENABLED+=("$sec"); fi
  done <<<"$SECTIONS_ALL"

  if ((${#ENABLED[@]}==0)); then
    echo "No sections enabled. Available:"; echo "$SECTIONS_ALL" | sed 's/^/  - /'; return 0
  fi
  mapfile -t ENABLED < <(printf '%s\n' "${ENABLED[@]}" | awk '!seen[$0]++')

  helpers_have_aria2_rpc || helpers_start_aria2_daemon
  helpers_reset_enqueued

  local any=0 url raw_path path dir out gid
  local default_dir="${DEFAULT_DOWNLOAD_DIR:-$COMFY}"

  for sec in "${ENABLED[@]}"; do
    echo ">>> Enqueue section: $sec"

    # Collect pairs first to avoid subshell write-loss
    local -a pairs=()
    mapfile -t pairs < <(jq -r --arg sec "$sec" --arg default_dir "$default_dir" '
      def as_obj:
        if (type=="object") then {url:(.url // ""), path:(.path // ((.dir // "") + (if .out then "/" + .out else "" end)))}
        elif (type=="array") then {url:(.[0] // ""), path:(.[1] // "")}
        elif (type=="string") then {url:., path:""}
        else {url:"", path:""} end;
      (.sections[$sec] // [])[]
      | as_obj
      | .url as $u
      | ( if (.path|length)>0 then .path
          else ( if ($default_dir|length)>0
                 then ($default_dir + "/" + ($u|sub("^.*/";"")))
                 else ($u|sub("^.*/";"")) end )
          end ) as $p
      | select(($u|type)=="string" and ($p|type)=="string" and ($u|length)>0 and ($p|length)>0)
      | [$u, $p] | @tsv
    ' "$MAN")

    for line in "${pairs[@]}"; do
      IFS=$'\t' read -r url raw_path <<<"$line"
      [[ -z "$url" || -z "$raw_path" ]] && { echo "⚠️  Skipping invalid item"; continue; }

      path="$(helpers_resolve_placeholders "$raw_path" "$VARS_JSON")"
      dir="$(dirname -- "$path")"
      out="$(basename -- "$path")"
      mkdir -p -- "$dir"

      # If file exists with non-zero size, skip
      if [[ -s "$path" ]]; then
        local sz; sz="$(helpers_human_bytes "$(stat -c%s -- "$path" 2>/dev/null || wc -c <"$path")")"
        echo "✅ $(basename -- "$path") exists (${sz}), skipping."
        continue
      fi

      echo "📥 Queue: $out"
      gid="$(helpers_rpc_add_uri "$url" "$dir" "$out" "")"
      if [[ -n "$gid" ]]; then
        any=1
        helpers_record_gid "$gid"
      else
        echo "❌ addUri failed for $out"
      fi
    done
  done

  echo "$any"
}

# ---- Top-level: enqueue + progress ----
aria2_enqueue_and_wait_from_manifest() {
  [[ -z "${MODEL_MANIFEST_URL:-}" ]] && { echo "MODEL_MANIFEST_URL is not set." >&2; return 1; }
  aria2_clear_results >/dev/null 2>&1 || true
  helpers_have_aria2_rpc || helpers_start_aria2_daemon
  echo "▶ Starting aria2 RPC daemon…"

  local any; any="$(helpers_download_from_manifest || echo 0)"
  if [[ "$any" == "0" ]]; then
    echo "Nothing enqueued. Exiting without starting progress loop."
    return 0
  fi

  helpers_progress_snapshot_loop "$ARIA2_PROGRESS_INTERVAL" "$ARIA2_PROGRESS_BAR_WIDTH" "$COMFY_LOGS/aria2_progress.log"
  aria2_clear_results >/dev/null 2>&1 || true
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