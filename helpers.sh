# helpers.sh
# Guard against double-sourcing
if [[ -n "${HELPERS_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
HELPERS_SH_LOADED=1

# Optional: only turn on bash options if running as "source"d, not executed
# (don't set -e here; leave that to the caller)
shopt -s extglob

# Expect these, but don't explode if unset
PY_BIN="${PY:-/opt/venv/bin/python}"
PIP_BIN="${PIP:-/opt/venv/bin/pip}"

build_sage() {
  local commit="$1"
  echo "  -> trying commit: $commit"
  ( set -e
    cd /tmp/SageAttention
    git fetch --all --tags
    git reset --hard "$commit"

    # Environment to help nvcc/torch extensions:
    export MAX_JOBS="${MAX_JOBS:-32}"
    export EXT_PARALLEL="${EXT_PARALLEL:-4}"
    export NVCC_APPEND_FLAGS="--threads 8"
    export FORCE_CUDA=1
    export CXX="${CXX:-g++}"
    export CC="${CC:-gcc}"

    # Feed explicit gencode flags via env Torch respects:
    export EXTRA_NVCCFLAGS="${SAGE_GENCODE}"

    # No isolation so it sees torch headers in the venv
    $PIP install --no-build-isolation -e . 
  )
}

ensure_comfy() {
  # If it looks like a valid git checkout, hard-reset it
  if [ -d "$COMFY_HOME/.git" ] && [ -f "$COMFY_HOME/main.py" ]; then
    git -C "$COMFY_HOME" fetch --depth=1 origin
    git -C "$COMFY_HOME" reset --hard origin/master || git -C "$COMFY_HOME" reset --hard origin/main || true
  else
    # Anything else (empty/invalid dir) → replace cleanly
    rm -rf "$COMFY_HOME"
    git clone --depth=1 "$REPO_URL" "$COMFY_HOME"
  fi

  # deps (safe to re-run)
  $PIP install -U pip wheel setuptools
  [ -f "$COMFY_HOME/requirements.txt" ] && $PIP install -r "$COMFY_HOME/requirements.txt" || true

  # keep /ComfyUI pointing to the workspace copy
  ln -sfn "$COMFY_HOME" /ComfyUI
}

# Multi-connection download helper
dl() { 
  aria2c -x16 -s16 -k1M --continue=true -d "$(dirname "$2")" -o "$(basename "$2")" "$1"; 
}

# Telegram notify helper
tg() {
  if [ -n "${TELEGRAM_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=$1" >/dev/null || true
  fi
}

# Ensure git-lfs etc are present
need_tools_for_hf() {
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y jq git git-lfs >/dev/null 2>&1 || true
  git lfs install --system || true
}

# Build a pin signature from the currently active venv
pins_signature() {
  "$PY" - <<'PY'
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

bundle_ts() { date +%Y%m%d-%H%M; }  # sortable

bundle_base() {
  local tag="${1:?tag}" pins="${2:?pins}" ts="${3:-$(bundle_ts)}"
  echo "custom_nodes_bundle_${tag}_${pins}_${ts}"
}

manifest_name()   { echo "custom_nodes_manifest_${1:?tag}.json"; }
reqs_name()       { echo "consolidated_requirements_${1:?tag}.txt"; }
sha_name()        { echo "${1}.sha256"; }

# Download a file from HF to local dest
hf_download_to() {
  local REPO_PATH="$1"   # e.g. bundles/custom_nodes_bundle_np2d2d6_cupy13d6d0_cv4d12d0d88_20251103-0943.tgz
  local DEST="$2"
  local url="$HF_API_BASE/$HF_REPO_ID/resolve/$CN_BRANCH/$REPO_PATH"
  aria2c -x16 -s16 -k1M -o "$(basename "$DEST")" -d "$(dirname "$DEST")" "$url"
}

hf_push_files() {
  local MSG="${1:-"update bundles"}"; shift || true
  local FILES=( "$@" )
  local tmp="/workspace/.hf_push.$$"
  rm -rf "$tmp"
  git lfs install
  git clone "$(hf_remote_url)" "$tmp"
  cd "$tmp"
  git checkout "$CN_BRANCH" 2>/dev/null || git checkout -b "$CN_BRANCH"
  mkdir -p bundles meta requirements

  for f in "${FILES[@]}"; do
    case "$f" in
      *.tgz) cp -f "$f" bundles/ ;;
      *.sha256) cp -f "$f" bundles/ ;;
      *.json) cp -f "$f" meta/ ;;
      *.txt) cp -f "$f" requirements/ ;;
      *) cp -f "$f" bundles/ ;;
    esac
  done

  git lfs track "bundles/*.tgz"
  git add .gitattributes bundles meta requirements
  git commit -m "$MSG" || true
  git push origin "$CN_BRANCH"
  cd /; rm -rf "$tmp"
}

ensure_nodes_from_bundle_or_build() {
  local tag="${BUNDLE_TAG:?BUNDLE_TAG required}"
  local pins="${PINS:-$(pins_signature)}"
  local cache="${CACHE_DIR:-/workspace/cache}"
  mkdir -p "$cache"

  echo "[custom-nodes] Looking for bundle tag=${tag}, pins=${pins} in HF…"
  local tgz
  tgz="$(hf_fetch_latest_bundle "$tag" "$pins")"

  if [ -n "${tgz:-}" ] && [ -s "$tgz" ]; then
    echo "[custom-nodes] Found bundle: $(basename "$tgz") — installing"
    install_custom_nodes_bundle "$tgz"
    return 0
  fi

  echo "[custom-nodes] No matching bundle found. Building from NODES list…"
  install_custom_nodes_set || return $?

  if [ "${PUSH_BUNDLE:-0}" = "1" ]; then
    local base tarpath manifest reqs sha
    base="$(bundle_base "$tag" "$pins")"
    tarpath="$(build_custom_nodes_bundle "$tag" "$pins")"
    manifest="${CACHE_DIR}/$(manifest_name "$tag")"
    reqs="${CACHE_DIR}/$(reqs_name "$tag")"
    sha="${CACHE_DIR}/$(sha_name "$base")"
    echo "[custom-nodes] Pushing bundle + metadata to HF…"
    hf_push_files "add ${base}" "$tarpath" "$sha" "$manifest" "$reqs"
  fi
}

# Pull a custom_nodes.txt (list of repos) if present; echo the path or empty
hf_fetch_nodes_list() {
  local OUT="/workspace/cache/custom_nodes.txt"
  mkdir -p /workspace/cache
  local url="$HF_API_BASE/$HF_REPO_ID/resolve/$CN_BRANCH/custom_nodes.txt"
  if curl -fsSL -H "$HF_AUTH_HEADER" "$url" -o "$OUT"; then
    echo "$OUT"
  else
    echo ""
  fi
}

# Build dataset/model remote
hf_remote_url() {
  : "${HF_TOKEN:?missing HF_TOKEN}" "${HF_REPO_ID:?missing HF_REPO_ID}"
  local t="${HF_REPO_TYPE:-dataset}" host="huggingface.co"
  [ "$t" = "dataset" ] && host="${host}/datasets"
  echo "https://oauth2:${HF_TOKEN}@${host}/${HF_REPO_ID}.git"
}

# Returns local path to downloaded .tgz in CACHE_DIR, or empty if not found
hf_fetch_latest_bundle() {
  local tag="${1:?tag}" pins="${2:?pins}"
  local tmp="/workspace/.hf_pull.$$" cache="${CACHE_DIR:-/workspace/cache}"
  mkdir -p "$cache"; rm -rf "$tmp"
  git lfs install
  git clone --depth=1 "$(hf_remote_url)" "$tmp" >/dev/null 2>&1 || return 0
  cd "$tmp"

  # look under bundles/ for matching pattern
  local patt="bundles/$(bundle_base "$tag" "$pins")"  # without timestamp
  patt="${patt%_*}_*.tgz"  # wildcard timestamp

  # list, pick the lexicographically latest (timestamps sort)
  mapfile -t matches < <(ls -1 $patt 2>/dev/null | sort)
  if (( ${#matches[@]} == 0 )); then
    cd /; rm -rf "$tmp"; return 0
  fi
  local latest="${matches[-1]}"

  # fetch the LFS object for that file only
  git lfs fetch --include="$latest" >/dev/null 2>&1 || true
  git lfs pull  --include="$latest" >/dev/null 2>&1 || true

  # copy to cache and return path
  local out="$cache/$(basename "$latest")"
  cp -f "$latest" "$out"
  cd /; rm -rf "$tmp"
  echo "$out"
}

install_custom_nodes_bundle() {
  local tgz="${1:?tgz}"
  local parent dir
  parent="$(dirname "$CUSTOM_DIR")"
  dir="$(basename "$CUSTOM_DIR")"
  mkdir -p "$parent"
  tar -C "$parent" -xzf "$tgz"
  # Ensure final path exists & is named as expected
  if [ ! -d "$CUSTOM_DIR" ]; then
    # If extracted directory name differs, move it in place
    local extracted="$(tar -tzf "$tgz" | head -1 | cut -d/ -f1)"
    [ -n "$extracted" ] && mv -f "$parent/$extracted" "$CUSTOM_DIR"
  fi
}

# =========================
#  Bundling helpers
# =========================
# Create manifest + consolidated requirements (skips heavy pins we manage)
make_nodes_manifest_and_reqs() {
  local CN="$CUSTOM_DIR"
  local OUTDIR="$1"
  mkdir -p "$OUTDIR"

  # manifest of repo URLs + commit SHAs
  "$PY" - <<PY > "$OUTDIR/custom_nodes_manifest.json"
import os, subprocess, json, glob
cn = os.environ.get("CUSTOM_DIR")
pins={}
for g in glob.glob(os.path.join(cn, "*/.git")):
    repo = os.path.basename(os.path.dirname(g))
    try:
        sha = subprocess.check_output(["git","-C",os.path.dirname(g),"rev-parse","HEAD"], text=True).strip()
        url = subprocess.check_output(["git","-C",os.path.dirname(g),"config","--get","remote.origin.url"], text=True).strip()
        pins[repo]={"commit":sha,"origin":url}
    except Exception: pass
print(json.dumps(pins, indent=2))
PY

  # consolidate requirements
  local REQ_ALL="$OUTDIR/_all_requirements.txt"
  : > "$REQ_ALL"
  find "$CN" -maxdepth 2 -type f -name requirements.txt -print0 \
    | xargs -0 -I{} bash -lc "cat '{}' >> '$REQ_ALL'" || true

  # strip heavy/conflicting libs we pin elsewhere
  grep -vE '^(torch|torchvision|torchaudio|opencv(|-python|-contrib-python|-headless)|cupy(|-cuda.*)|numpy)\b' "$REQ_ALL" \
    | sed '/^\s*#/d;/^\s*$/d' \
    | sort -u > "$OUTDIR/consolidated_requirements.txt"
  rm -f "$REQ_ALL"
}

# Extract a bundle into custom_nodes (overlay)
extract_custom_nodes_bundle() {
  local TARBALL="$1"
  mkdir -p "$CUSTOM_DIR"
  tar -xzf "$TARBALL" -C "$CUSTOM_DIR"
}

# Install consolidated requirements (safe with your pins)
safe_install_consolidated_reqs() {
  local REQS="/workspace/cache/consolidated_requirements.txt"
  [ -f "$REQS" ] || return 0
  $PIP install --no-cache-dir -r "$REQS" || true
}

push_bundle_if_requested() {
  [ "${PUSH_BUNDLE:-0}" = "1" ] || return 0
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

# ---------- helper: safe requirements install (keeps pins intact) ----------
safe_pip_install_reqs() {
  local req="$1"
  # Try normal install; tolerate failures and re-pin afterwards to avoid drift
  $PIP install -r "$req" || true
  $PIP install -U "numpy>=2.0,<2.3" "cupy-cuda12x>=13.0.0" "opencv-contrib-python==4.12.0.88"
}

# --- Helper: safe repo name (dir) ---
repo_dir_name() {
  # Strip trailing .git, take basename
  local u="$1"
  basename "${u%.git}"
}

# --- Helper: clone or pull (supports recursive for specific repos) ---
clone_or_pull() {
  local repo="$1"
  local dst="$2"
  local recursive="$3" # "true" or "false"
  if [[ -d "$dst/.git" ]]; then
    git -C "$dst" fetch --all --prune --tags --depth="$GIT_DEPTH" || true
    # Prefer main/master reset
    git -C "$dst" reset --hard origin/main 2>/dev/null || \
    git -C "$dst" reset --hard origin/master 2>/dev/null || true
  else
    if [[ "$recursive" == "true" ]]; then
      git -C "$CUSTOM_DIR" clone --recursive ${GIT_DEPTH:+--depth "$GIT_DEPTH"} "$repo" "$dst"
    else
      git -C "$CUSTOM_DIR" clone ${GIT_DEPTH:+--depth "$GIT_DEPTH"} "$repo" "$dst"
    fi
  fi
}

# Produces JSON manifest of the currently installed nodes
build_nodes_manifest() {
  local tag="${1:?tag}"
  local out="${2:?out_json}"
  local dir="${CUSTOM_DIR:?CUSTOM_DIR unset}"

  "$PY" - <<PY
import json, os, subprocess, sys
d = os.environ["CUSTOM_DIR"]
items = []
for name in sorted(os.listdir(d)):
    p = os.path.join(d, name)
    if not os.path.isdir(p) or not os.path.isdir(os.path.join(p, ".git")):
        continue
    def run(*args):
        return subprocess.check_output(["git","-C",p,*args], text=True).strip()
    try:
        url = run("config","--get","remote.origin.url")
    except Exception:
        url = ""
    try:
        ref = run("rev-parse","HEAD")
    except Exception:
        ref = ""
    try:
        br = run("rev-parse","--abbrev-ref","HEAD")
    except Exception:
        br = ""
    items.append({"name": name, "path": p, "origin": url, "branch": br, "commit": ref})
with open(sys.argv[1], "w") as f:
    json.dump({"tag": os.environ.get("BUNDLE_TAG",""), "nodes": items}, f, indent=2)
PY
}

# Concatenate node requirements.txt files → de-duped, sorted
build_consolidated_reqs() {
  local tag="${1:?tag}" out="${2:?out_txt}"
  local dir="${CUSTOM_DIR:?CUSTOM_DIR unset}"
  tmp="$(mktemp)"
  ( shopt -s nullglob
    for r in "$dir"/*/requirements.txt; do
      # annotate for traceability
      echo -e "\n# ---- $(dirname "$r")/requirements.txt ----"
      cat "$r"
    done
  ) >"$tmp"
  # strip comments/empties, sort unique (keep simple; resolver runs later)
  grep -E '^[^#[:space:]]' "$tmp" | sort -u > "$out" || true
  rm -f "$tmp"
}

build_custom_nodes_bundle() {
  local tag="${1:?tag}" pins="${2:?pins}" ts="$(bundle_ts)"
  local base cache="${CACHE_DIR:-/workspace/cache}"
  mkdir -p "$cache"
  base="$(bundle_base "$tag" "$pins" "$ts")"

  local tarpath="$cache/${base}.tgz"
  local manifest="$cache/$(manifest_name "$tag")"
  local reqs="$cache/$(reqs_name "$tag")"
  local sha="$cache/$(sha_name "$base")"

  # create manifest & consolidated requirements
  build_nodes_manifest "$tag" "$manifest"
  build_consolidated_reqs "$tag" "$reqs"

  # pack the custom_nodes dir
  tar -C "$(dirname "$CUSTOM_DIR")" -czf "$tarpath" "$(basename "$CUSTOM_DIR")"
  sha256sum "$tarpath" > "$sha"

  # print absolute tgz path (callers capture)
  echo "$tarpath"
}

# --- Helper: per-node build/install (requirements.txt then install.py) ---
build_node() {
  local dst="$1"
  local name
  name="$(basename "$dst")"
  local log="$CUSTOM_LOG_DIR/${name}.log"

  {
    echo "==> [$name] starting at $(date -Is)"
    if [[ -f "$dst/requirements.txt" ]]; then
      echo "==> [$name] pip install -r requirements.txt"
      $PIP install --no-cache-dir -r "$dst/requirements.txt"
    fi
    if [[ -f "$dst/install.py" ]]; then
      echo "==> [$name] python install.py"
      "$PY" "$dst/install.py"
    fi
    echo "==> [$name] done at $(date -Is)"
  } >"$log" 2>&1
}

# --- Nodes that require recursive clone (submodules) ---
needs_recursive() {
  case "$1" in
    *ComfyUI_UltimateSDUpscale*) echo "true" ;;
    *) echo "false" ;;
  esac
}

# ---------- Helper to install nodes ----------
install_node () {
  local repo="$1"
  local dest="$CUSTOM_DIR/$(basename "$repo" .git)"
  if [ ! -d "$dest/.git" ]; then
    if [ "$repo" = "https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git" ]; then
      git -C "$CUSTOM_DIR" clone --recursive "$repo"
    else
      git -C "$CUSTOM_DIR" clone "$repo"
    fi
  else
    git -C "$dest" pull --rebase || true
  fi
  [ -f "$dest/requirements.txt" ] && safe_pip_install_reqs "$dest/requirements.txt" || true
  [ -f "$dest/install.py" ]       && $PY  "$dest/install.py" || true
}

# Resolve the node list (CUSTOM_NODE_LIST_FILE → CUSTOM_NODE_LIST → DEFAULT_NODES)
# Usage: local -a nodes; resolve_nodes_list nodes
resolve_nodes_list() {
  local -n _out="$1"  # nameref to output array
  _out=()
  if [[ -n "${CUSTOM_NODE_LIST_FILE:-}" && -f "${CUSTOM_NODE_LIST_FILE:-}" ]]; then
    mapfile -t _out < <(grep -vE '^\s*(#|$)' "$CUSTOM_NODE_LIST_FILE")
  elif [[ -n "${CUSTOM_NODE_LIST:-}" ]]; then
    # shellcheck disable=SC2206
    _out=(${CUSTOM_NODE_LIST})
  else
    _out=("${DEFAULT_NODES[@]}")
  fi
}

# Install a set of custom nodes in parallel with bounded concurrency.
# Respects: CUSTOM_DIR, CUSTOM_LOG_DIR, MAX_NODE_JOBS
# Optional arg: custom array name to use instead of resolved list
#   e.g., install_custom_nodes_set MY_ARRAY
install_custom_nodes_set() {
  local -a NODES_LIST
  if [[ -n "${1:-}" ]]; then
    # Caller passed an array name
    local -n _src="$1"
    NODES_LIST=("${_src[@]}")
  else
    resolve_nodes_list NODES_LIST
  fi

  local max_jobs="${MAX_NODE_JOBS:-6}"
  mkdir -p "${CUSTOM_DIR:?CUSTOM_DIR not set}" "${CUSTOM_LOG_DIR:?CUSTOM_LOG_DIR not set}"

  # --- Simple semaphore via named pipe ---
  local SEM_FIFO="/tmp/.nodes.sem.$$"
  mkfifo "$SEM_FIFO"
  exec 9<>"$SEM_FIFO"
  rm -f "$SEM_FIFO"
  for _ in $(seq 1 "$max_jobs"); do printf . >&9; done

  local -a pids=()
  local errs=0

  for repo in "${NODES_LIST[@]}"; do
    [[ -n "$repo" ]] || continue
    [[ "$repo" =~ ^# ]] && continue

    # acquire token
    read -r _ <&9

    (
      # always release token on exit of this subshell
      release() { printf . >&9; }
      trap release EXIT

      set -e
      local name dst rec
      name="$(repo_dir_name "$repo")"
      dst="$CUSTOM_DIR/$name"
      rec="$(needs_recursive "$repo")"

      echo "[custom-nodes] $name → $dst"
      mkdir -p "$dst"
      clone_or_pull "$repo" "$dst" "$rec"

      if ! build_node "$dst"; then
        echo "[custom-nodes] ERROR building $name (see $CUSTOM_LOG_DIR/${name}.log)"
        exit 1
      fi

      echo "[custom-nodes] OK $name"
    ) &
    pids+=("$!")
  done

  echo "[custom-nodes] Waiting for parallel node installs to complete…"

  # parent waits on its own children; tally errors
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      errs=$((errs+1))
    fi
  done

  # close semaphore FD
  exec 9>&-

  if (( errs > 0 )); then
    echo "[custom-nodes] Completed with $errs error(s). Check logs: $CUSTOM_LOG_DIR"
    return 2
  else
    echo "[custom-nodes] All nodes installed successfully."
  fi
}

# ---------- Helper to install Loras ----------
