#!/bin/bash
# run_1h_pilots.sh — 1-hour MAB validation pilots + baseline comparison
#
# Phase 1 (sequential): MAB algorithms s4..s7, one at a time (1 h each).
# Phase 2 (parallel):   Baselines s1, s2, s3 run simultaneously (1 h total).
# Phase 3:              Extract tarballs, print summary table, render IPSM PNGs.
#
# Designed to run unsupervised. All output is tee'd to a timestamped log file.
# The script traps SIGINT/SIGTERM and cleans up any live containers before exit.
#
# Prerequisites:
#   source ~/fuzz/profuzzbench/fuzz-env.sh
#   bash run_1h_pilots.sh
#
# Required env vars (set by fuzz-env.sh):
#   PFBENCH   — path to profuzzbench repo  (e.g. ~/fuzz/profuzzbench)
#   RESULTS   — path to results root       (e.g. ~/fuzz/results)
#
# Required tools on host:
#   docker, graphviz (dot), awk, grep, df

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TIMEOUT=3600                          # 1 hour per run
SKIPCOUNT=5                           # gcovr every 5 seeds
IMAGE="openssl-mabflnet"
COMMON_OPTS="-P TLS -D 10000 -q 3 -E -K -R -W 100"
MIN_DISK_MB=5120                      # refuse to start a run if < 5 GB free
CONTAINER_START_WAIT=15               # seconds to wait before checking liveness
RESULTS_DIR="${RESULTS}/1h-pilots"
LOG_FILE="${RESULTS_DIR}/run_$(date +%Y%m%d_%H%M%S).log"

MAB_ALGOS=(
  "4:EXP3"
  "5:EXP3-IX"
  "6:SB-EXP3"
  "7:SB-EXP3-IX"
)

BASELINE_ALGOS=(
  "1:RANDOM"
  "2:ROUND-ROBIN"
  "3:FAVOR"
)

# ---------------------------------------------------------------------------
# Logging helper — every echo goes to both stdout and the log file
# ---------------------------------------------------------------------------

mkdir -p "$RESULTS_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2; }
die()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Container registry — track every container we start so we can clean up
# ---------------------------------------------------------------------------

declare -a LIVE_CONTAINERS=()

register_container() { LIVE_CONTAINERS+=("$1"); }

cleanup_containers() {
  if [ ${#LIVE_CONTAINERS[@]} -gt 0 ]; then
    log "Cleaning up ${#LIVE_CONTAINERS[@]} live container(s)..."
    for cid in "${LIVE_CONTAINERS[@]}"; do
      if docker inspect "$cid" &>/dev/null; then
        docker stop "$cid" 2>/dev/null || true
        docker rm   "$cid" 2>/dev/null || true
        log "  Removed container $cid"
      fi
    done
    LIVE_CONTAINERS=()
  fi
}

trap 'log "Caught signal — cleaning up..."; cleanup_containers; exit 1' \
  INT TERM HUP

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

preflight() {
  log "=== Pre-flight checks ==="

  # Docker daemon
  docker info &>/dev/null || die "Docker daemon not running."
  log "  Docker daemon: OK"

  # Image exists
  docker image inspect "$IMAGE" &>/dev/null \
    || die "Docker image '$IMAGE' not found. Build it first."
  log "  Image '$IMAGE': found"

  # Required env vars
  [ -n "${PFBENCH:-}" ] || die "PFBENCH is not set. Source fuzz-env.sh first."
  [ -n "${RESULTS:-}" ] || die "RESULTS is not set. Source fuzz-env.sh first."
  log "  PFBENCH=$PFBENCH"
  log "  RESULTS=$RESULTS"

  # Results dir writable
  mkdir -p "$RESULTS_DIR"
  touch "${RESULTS_DIR}/.write_test" \
    && rm "${RESULTS_DIR}/.write_test" \
    || die "Results directory not writable: $RESULTS_DIR"
  log "  Results dir: $RESULTS_DIR (writable)"

  # graphviz
  if ! command -v dot &>/dev/null; then
    warn "'dot' (graphviz) not found — IPSM PNGs will be skipped."
    warn "Install with: sudo apt-get install graphviz"
  else
    log "  graphviz: OK"
  fi

  log "=== Pre-flight OK ==="
  echo ""
}

# ---------------------------------------------------------------------------
# Disk space guard
# ---------------------------------------------------------------------------

check_disk() {
  local label="$1"
  local free_mb
  free_mb=$(df -m "$RESULTS_DIR" | awk 'NR==2 {print $4}')
  if [ "$free_mb" -lt "$MIN_DISK_MB" ]; then
    die "Insufficient disk space before $label: ${free_mb} MB free, need ${MIN_DISK_MB} MB."
  fi
  log "  Disk OK: ${free_mb} MB free before $label"
}

# ---------------------------------------------------------------------------
# Run one container, wait for it, copy results out.
#
# Usage: run_one S NAME OUTDIR
# ---------------------------------------------------------------------------

run_one() {
  local S="$1" NAME="$2" OUTDIR="$3"
  local OPTS="${COMMON_OPTS} -s ${S}"

  log "--- Starting s${S} (${NAME}) ---"
  check_disk "s${S} (${NAME})"

  # Start container (detached)
  local CID
  CID=$(docker run --cpus=1 -d \
    "$IMAGE" \
    /bin/bash -c \
    "cd /home/ubuntu/experiments && run mabflnet '${OUTDIR}' '${OPTS}' ${TIMEOUT} ${SKIPCOUNT}")

  register_container "$CID"
  log "  Container started: ${CID}"

  # Liveness check — give the fork server a few seconds to come up
  sleep "$CONTAINER_START_WAIT"
  if ! docker inspect --format='{{.State.Running}}' "$CID" 2>/dev/null | grep -q "true"; then
    warn "Container ${CID} exited within ${CONTAINER_START_WAIT}s — possible startup failure."
    warn "Fetching last 30 lines of container log:"
    docker logs --tail 30 "$CID" 2>&1 | while IFS= read -r line; do warn "  $line"; done
    # Still attempt to collect results in case the run completed very quickly
  else
    log "  Container is running (liveness check passed)."
  fi

  # Wait for container to finish
  log "  Waiting for container ${CID} to finish (timeout=${TIMEOUT}s + post-run overhead)..."
  if ! docker wait "$CID" > /dev/null; then
    warn "docker wait returned non-zero for ${CID}."
  fi
  log "  Container ${CID} finished."

  # Copy tarball out (retry up to 3 times)
  local TARBALL="${RESULTS_DIR}/${OUTDIR}_1.tar.gz"
  local attempt
  for attempt in 1 2 3; do
    if docker cp "${CID}:/home/ubuntu/experiments/${OUTDIR}.tar.gz" "$TARBALL" 2>/dev/null; then
      log "  Results copied: $TARBALL"
      break
    else
      warn "  docker cp attempt ${attempt}/3 failed for ${CID}."
      sleep 5
    fi
    if [ "$attempt" -eq 3 ]; then
      warn "  Could not copy results for s${S} (${NAME}) after 3 attempts."
    fi
  done

  # Remove container
  docker rm "$CID" > /dev/null 2>&1 || true
  LIVE_CONTAINERS=("${LIVE_CONTAINERS[@]/$CID/}")  # remove from registry
  log "--- s${S} (${NAME}) done ---"
  echo ""
}

# ---------------------------------------------------------------------------
# Run multiple containers in parallel, wait for all, copy all results.
# Usage: run_parallel ENTRY...  where ENTRY is "S:NAME"
# ---------------------------------------------------------------------------

run_parallel() {
  local entries=("$@")
  local -a cids=()
  local -a names=()
  local -a outdirs=()

  check_disk "parallel baselines"

  log "--- Starting parallel baselines: ${entries[*]} ---"

  for entry in "${entries[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-1h-s${S}-${NAME}"
    local OPTS="${COMMON_OPTS} -s ${S}"

    local CID
    CID=$(docker run --cpus=1 -d \
      "$IMAGE" \
      /bin/bash -c \
      "cd /home/ubuntu/experiments && run mabflnet '${OUTDIR}' '${OPTS}' ${TIMEOUT} ${SKIPCOUNT}")

    register_container "$CID"
    cids+=("$CID")
    names+=("$NAME")
    outdirs+=("$OUTDIR")
    log "  s${S} (${NAME}) container started: ${CID}"
  done

  # Liveness check for all
  sleep "$CONTAINER_START_WAIT"
  for i in "${!cids[@]}"; do
    local CID="${cids[$i]}"
    if ! docker inspect --format='{{.State.Running}}' "$CID" 2>/dev/null | grep -q "true"; then
      warn "Container ${CID} (${names[$i]}) exited within ${CONTAINER_START_WAIT}s — possible startup failure."
      docker logs --tail 30 "$CID" 2>&1 | while IFS= read -r line; do warn "  $line"; done
    else
      log "  ${names[$i]} container ${CID}: running (liveness OK)"
    fi
  done

  # Wait for all containers to finish
  log "  Waiting for all parallel containers to finish..."
  for CID in "${cids[@]}"; do
    docker wait "$CID" > /dev/null || warn "docker wait non-zero for $CID"
  done
  log "  All parallel containers finished."

  # Copy results from each
  for i in "${!cids[@]}"; do
    local CID="${cids[$i]}"
    local OUTDIR="${outdirs[$i]}"
    local NAME="${names[$i]}"
    local entry="${entries[$i]}"
    local S="${entry%%:*}"
    local TARBALL="${RESULTS_DIR}/${OUTDIR}_1.tar.gz"
    local attempt
    for attempt in 1 2 3; do
      if docker cp "${CID}:/home/ubuntu/experiments/${OUTDIR}.tar.gz" "$TARBALL" 2>/dev/null; then
        log "  s${S} (${NAME}) results copied: $TARBALL"
        break
      else
        warn "  docker cp attempt ${attempt}/3 failed for ${CID} (${NAME})."
        sleep 5
      fi
      if [ "$attempt" -eq 3 ]; then
        warn "  Could not copy results for s${S} (${NAME}) after 3 attempts."
      fi
    done
    docker rm "$CID" > /dev/null 2>&1 || true
    LIVE_CONTAINERS=("${LIVE_CONTAINERS[@]/$CID/}")
  done

  log "--- Parallel baselines done ---"
  echo ""
}

# ---------------------------------------------------------------------------
# Extract all tarballs
# ---------------------------------------------------------------------------

extract_results() {
  log "=== Extracting tarballs ==="
  for entry in "${MAB_ALGOS[@]}" "${BASELINE_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-1h-s${S}-${NAME}"
    local TARBALL="${RESULTS_DIR}/${OUTDIR}_1.tar.gz"
    if [ -f "$TARBALL" ]; then
      tar -xzf "$TARBALL" -C "$RESULTS_DIR" \
        && log "  Extracted: $TARBALL" \
        || warn "  Failed to extract: $TARBALL"
    else
      warn "  Tarball not found: $TARBALL"
    fi
  done
  echo ""
}

# ---------------------------------------------------------------------------
# Summary table
# ---------------------------------------------------------------------------

print_summary() {
  log "=== Summary ==="
  printf "%-6s %-14s %10s %8s %8s %8s %12s\n" \
    "s" "Algorithm" "Execs" "States" "Paths" "Crashes" "MAB_rounds"
  printf "%-6s %-14s %10s %8s %8s %8s %12s\n" \
    "------" "--------------" "----------" "--------" "--------" "--------" "------------"

  for entry in "${MAB_ALGOS[@]}" "${BASELINE_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-1h-s${S}-${NAME}"
    local STATSFILE="${RESULTS_DIR}/${OUTDIR}/fuzzer_stats"
    local DOTFILE="${RESULTS_DIR}/${OUTDIR}/ipsm.dot"
    local MABFILE="${RESULTS_DIR}/${OUTDIR}/mab_stats"

    if [ ! -f "$STATSFILE" ]; then
      printf "%-6s %-14s %10s %8s %8s %8s %12s\n" \
        "s${S}" "$NAME" "N/A" "N/A" "N/A" "N/A" "N/A"
      continue
    fi

    local EXECS PATHS CRASHES STATES MAB_ROUNDS
    EXECS=$(grep   "^execs_done"     "$STATSFILE" | awk -F': ' '{print $2}' | tr -d ' ')
    PATHS=$(grep   "^paths_total"    "$STATSFILE" | awk -F': ' '{print $2}' | tr -d ' ')
    CRASHES=$(grep "^unique_crashes" "$STATSFILE" | awk -F': ' '{print $2}' | tr -d ' ')

    if [ -f "$DOTFILE" ]; then
      STATES=$(grep -c '^\s*[0-9]' "$DOTFILE" 2>/dev/null || echo "?")
    else
      STATES="?"
    fi

    # Total MAB rounds = max value in last_selected column of mab_stats
    if [ -f "$MABFILE" ]; then
      MAB_ROUNDS=$(grep -v '^#' "$MABFILE" | grep -v '^mab' | grep -v '^timestamp' \
        | awk 'NF>=6 {if($6+0 > max) max=$6+0} END {print (max>0?max:"0")}')
    else
      MAB_ROUNDS="-"
    fi

    printf "%-6s %-14s %10s %8s %8s %8s %12s\n" \
      "s${S}" "$NAME" "$EXECS" "$STATES" "$PATHS" "$CRASHES" "$MAB_ROUNDS"
  done
  echo ""
}

# ---------------------------------------------------------------------------
# Render IPSM PNGs
# ---------------------------------------------------------------------------

render_ipsm() {
  if ! command -v dot &>/dev/null; then
    warn "graphviz not found — skipping IPSM rendering."
    return
  fi

  log "=== Rendering IPSM graphs ==="
  for entry in "${MAB_ALGOS[@]}" "${BASELINE_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-1h-s${S}-${NAME}"
    local DOTFILE="${RESULTS_DIR}/${OUTDIR}/ipsm.dot"
    local PNGFILE="${RESULTS_DIR}/${OUTDIR}/ipsm.png"
    if [ -f "$DOTFILE" ]; then
      dot -Tpng "$DOTFILE" -o "$PNGFILE" \
        && log "  s${S} (${NAME}): $PNGFILE" \
        || warn "  s${S} (${NAME}): dot failed"
    else
      warn "  s${S} (${NAME}): ipsm.dot not found"
    fi
  done
  echo ""
}

# ---------------------------------------------------------------------------
# Verify mab_reward_log, mab_stats, mab_seed_map were produced for MAB runs
# ---------------------------------------------------------------------------

verify_mab_outputs() {
  log "=== Verifying MAB-specific outputs ==="
  for entry in "${MAB_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-1h-s${S}-${NAME}"
    local DIR="${RESULTS_DIR}/${OUTDIR}"

    local ok=1
    for f in mab_reward_log mab_stats mab_seed_map; do
      if [ -f "${DIR}/${f}" ]; then
        local lines
        lines=$(wc -l < "${DIR}/${f}")
        log "  s${S} (${NAME}) ${f}: ${lines} lines OK"
      else
        warn "  s${S} (${NAME}) ${f}: MISSING"
        ok=0
      fi
    done
    [ "$ok" -eq 1 ] \
      && log "  s${S} (${NAME}): all MAB outputs present" \
      || warn "  s${S} (${NAME}): some MAB outputs missing"
  done
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "======================================================"
log "  run_1h_pilots.sh  —  $(date)"
log "======================================================"
log "  Image:        $IMAGE"
log "  Timeout:      ${TIMEOUT}s per run"
log "  Results dir:  $RESULTS_DIR"
log "  Log file:     $LOG_FILE"
log "======================================================"
echo ""

preflight

# ── Phase 1: MAB algorithms sequentially ─────────────────────────────────────

log "====== Phase 1: MAB algorithms (sequential) ======"
log "  Algorithms: ${MAB_ALGOS[*]}"
log "  Estimated wall time: ~$((${#MAB_ALGOS[@]} * TIMEOUT / 3600))h"
echo ""

for entry in "${MAB_ALGOS[@]}"; do
  S="${entry%%:*}"
  NAME="${entry##*:}"
  OUTDIR="out-1h-s${S}-${NAME}"
  run_one "$S" "$NAME" "$OUTDIR"
done

# ── Phase 2: Baselines in parallel ───────────────────────────────────────────

log "====== Phase 2: Baselines (parallel) ======"
log "  Algorithms: ${BASELINE_ALGOS[*]}"
log "  Estimated wall time: ~$((TIMEOUT / 3600))h (all run simultaneously)"
echo ""

run_parallel "${BASELINE_ALGOS[@]}"

# ── Phase 3: Post-processing ──────────────────────────────────────────────────

log "====== Phase 3: Post-processing ======"

extract_results
print_summary
render_ipsm
verify_mab_outputs

log "======================================================"
log "  All done. Results in: $RESULTS_DIR"
log "  Log file:             $LOG_FILE"
log "======================================================"
