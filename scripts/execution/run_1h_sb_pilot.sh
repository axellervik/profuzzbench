#!/bin/bash
# run_1h_sb_pilot.sh — 1-hour Sleeping-Bandit-only validation pilot
#                      10 repetitions per algorithm, sequential algorithms
# Validates: the exhaustion-based sleeping-bandit redesign (SB-EXP3 -s 6,
#            SB-EXP3-IX -s 7) — i.e. that "asleep" now tracks AFLNet's own
#            was_fuzzed/favored/queue_cycle bookkeeping instead of a MAB
#            recency window, and that SB behaves differently from plain
#            EXP3/EXP3-IX.
#
# This is a narrower, faster companion to run_1h_mab_diagnostic.sh: it only
# runs the two sleeping-bandit variants, not the full 6-algorithm suite.
# It does NOT re-run EXP3 (-s 4) / EXP3-IX (-s 5) baselines — the analysis
# script (analyse_full.py) reuses the s4/s5 mab_stats already produced by
# results/1h-mab-diagnostic-5, since the EXP3/EXP3-IX code paths are
# unchanged since that run.
#
# Phase 1 (sequential per algo, parallel within):
#   MAB algorithms s6..s7, one algo at a time, 10 containers in parallel each.
#   (~2 h total wall time, 10 cores per algo)
#
# Phase 2 (post-processing):
#   Extract tarballs, print summary table, render IPSM PNGs, verify MAB outputs.
#
# Designed to run unsupervised. All output is tee'd to a timestamped log file.
# The script traps SIGINT/SIGTERM and cleans up any live containers before exit.
#
# Prerequisites:
#   source ~/fuzz/profuzzbench/fuzz-env.sh
#   bash run_1h_sb_pilot.sh
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

RUNS=10                               # repetitions per algorithm
TIMEOUT=3600                          # 1 hour per run
SKIPCOUNT=5                           # gcovr every 5 seeds
IMAGE="openssl-mabflnet"
COMMON_OPTS="-P TLS -D 10000 -q 3 -E -K -R -W 100"
MIN_DISK_MB=5120                      # refuse to start a phase if < 5 GB free
CONTAINER_START_WAIT=15               # seconds to wait before liveness check
# Auto-increment results directory: 1h-sb-pilot, -2, -3, ...
_base="${RESULTS}/1h-sb-pilot"
if [ ! -d "$_base" ]; then
  RESULTS_DIR="$_base"
else
  _n=2
  while [ -d "${_base}-${_n}" ]; do _n=$((_n + 1)); done
  RESULTS_DIR="${_base}-${_n}"
fi
unset _base _n
LOG_FILE="${RESULTS_DIR}/run_$(date +%Y%m%d_%H%M%S).log"

MAB_ALGOS=(
  "6:SB-EXP3"
  "7:SB-EXP3-IX"
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

  log "  Runs per algorithm: $RUNS"
  log "  Timeout per run:    ${TIMEOUT}s"
  log "  Total wall time:    ~$(( ${#MAB_ALGOS[@]} * TIMEOUT / 3600 ))h (${#MAB_ALGOS[@]} algos × ${RUNS} parallel)"
  log "  Note: EXP3 (s4) / EXP3-IX (s5) baselines are NOT run here — analysis"
  log "        reuses results/1h-mab-diagnostic-5's s4/s5 mab_stats."
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
# Print a quick per-rep stats line for one extracted rep directory.
# Usage: quick_stats REP_DIR REP_INDEX
# ---------------------------------------------------------------------------

quick_stats() {
  local dir="$1" rep="$2"
  local statsfile="${dir}/fuzzer_stats"
  local mabfile="${dir}/mab_stats"

  if [ ! -f "$statsfile" ]; then
    log "    rep${rep}: fuzzer_stats not found"
    return
  fi

  local execs paths crashes mab_rounds
  execs=$(grep   "^execs_done"     "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')
  paths=$(grep   "^paths_total"    "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')
  crashes=$(grep "^unique_crashes" "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')

  if [ -f "$mabfile" ]; then
    # Maximum last_selected value across all data rows = total MAB rounds fired
    mab_rounds=$(awk '!/^mab/ && !/^timestamp/ && !/^#/ && !/^[[:space:]]*$/ && NF>=6 \
      {if($6+0 > max) max=$6+0} END {print (max>0?max:"0")}' "$mabfile")
    if [ -z "$mab_rounds" ]; then mab_rounds="0"; fi
  else
    mab_rounds="-"
  fi

  log "    rep${rep}: execs=${execs} paths=${paths} crashes=${crashes} mab_rounds=${mab_rounds}"
}

# ---------------------------------------------------------------------------
# Run RUNS containers for one algorithm in parallel, wait for all, copy and
# immediately extract results.
#
# Usage: run_algo S NAME
#
# Tarballs:      ${RESULTS_DIR}/${OUTDIR}_1.tar.gz .. ${OUTDIR}_${RUNS}.tar.gz
# Extracted dirs: ${RESULTS_DIR}/${OUTDIR}_1/     .. ${OUTDIR}_${RUNS}/
# ---------------------------------------------------------------------------

run_algo() {
  local S="$1" NAME="$2"
  local OUTDIR="out-1h-mab-s${S}-${NAME}"
  local OPTS="${COMMON_OPTS} -s ${S}"

  log "--- Starting s${S} (${NAME}) — ${RUNS} reps in parallel ---"
  check_disk "s${S} (${NAME})"

  # Launch all RUNS containers
  local -a cids=()
  local i
  for i in $(seq 1 "$RUNS"); do
    local CID
    CID=$(docker run --cpus=1 -d \
      "$IMAGE" \
      /bin/bash -c \
      "cd /home/ubuntu/experiments && run mabflnet '${OUTDIR}' '${OPTS}' ${TIMEOUT} ${SKIPCOUNT}")
    register_container "$CID"
    cids+=("$CID")
    log "  rep${i} container started: ${CID}"
  done

  # Liveness check
  sleep "$CONTAINER_START_WAIT"
  for i in "${!cids[@]}"; do
    local CID="${cids[$i]}"
    local rep=$((i + 1))
    if ! docker inspect --format='{{.State.Running}}' "$CID" 2>/dev/null | grep -q "true"; then
      warn "  rep${rep} container ${CID} exited within ${CONTAINER_START_WAIT}s."
      docker logs --tail 30 "$CID" 2>&1 | while IFS= read -r line; do warn "    $line"; done
    else
      log "  rep${rep} container ${CID}: running (liveness OK)"
    fi
  done

  # Wait for all reps to finish
  log "  Waiting for all ${RUNS} reps to finish..."
  for CID in "${cids[@]}"; do
    docker wait "$CID" > /dev/null || warn "  docker wait returned non-zero for ${CID}."
  done
  log "  All reps finished."

  # Copy tarballs, extract immediately into _N dirs, print quick stats
  for i in "${!cids[@]}"; do
    local CID="${cids[$i]}"
    local rep=$((i + 1))
    local TARBALL="${RESULTS_DIR}/${OUTDIR}_${rep}.tar.gz"
    local REP_DIR="${RESULTS_DIR}/${OUTDIR}_${rep}"

    # Copy (retry up to 3x)
    local attempt
    for attempt in 1 2 3; do
      if docker cp "${CID}:/home/ubuntu/experiments/${OUTDIR}.tar.gz" "$TARBALL" 2>/dev/null; then
        log "  rep${rep}: tarball copied → ${TARBALL}"
        break
      else
        warn "  rep${rep}: docker cp attempt ${attempt}/3 failed."
        sleep 5
      fi
      if [ "$attempt" -eq 3 ]; then
        warn "  rep${rep}: could not copy tarball after 3 attempts."
      fi
    done

    # Extract; tarball contains ${OUTDIR}/ at top level — rename to ${OUTDIR}_${rep}/
    if [ -f "$TARBALL" ]; then
      if [ -d "$REP_DIR" ]; then
        log "  rep${rep}: ${REP_DIR} already exists — skipping extraction."
      else
        tar -xzf "$TARBALL" -C "$RESULTS_DIR" \
          && mv "${RESULTS_DIR}/${OUTDIR}" "$REP_DIR" \
          && log "  rep${rep}: extracted → ${REP_DIR}" \
          || warn "  rep${rep}: extraction/rename failed for ${TARBALL}"
      fi
      quick_stats "$REP_DIR" "$rep"
    fi

    docker rm "$CID" > /dev/null 2>&1 || true
    LIVE_CONTAINERS=("${LIVE_CONTAINERS[@]/$CID/}")
  done

  log "--- s${S} (${NAME}) done ---"
  echo ""
}

# ---------------------------------------------------------------------------
# Extract any tarballs not yet extracted (fallback).
# ---------------------------------------------------------------------------

extract_remaining() {
  log "=== Extracting any remaining tarballs ==="
  local found_any=0

  for entry in "${MAB_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-1h-mab-s${S}-${NAME}"

    for i in $(seq 1 "$RUNS"); do
      local TARBALL="${RESULTS_DIR}/${OUTDIR}_${i}.tar.gz"
      local REP_DIR="${RESULTS_DIR}/${OUTDIR}_${i}"

      if [ -d "$REP_DIR" ]; then
        continue  # already extracted
      fi
      found_any=1
      if [ -f "$TARBALL" ]; then
        tar -xzf "$TARBALL" -C "$RESULTS_DIR" \
          && mv "${RESULTS_DIR}/${OUTDIR}" "$REP_DIR" \
          && log "  Extracted: ${REP_DIR}" \
          || warn "  Extraction failed: ${TARBALL}"
      fi
    done
  done

  if [ "$found_any" -eq 0 ]; then
    log "  (all tarballs already extracted)"
  fi
  log "=== Extraction phase done ==="
  echo ""
}

# ---------------------------------------------------------------------------
# Render IPSM PNGs if graphviz is available
# ---------------------------------------------------------------------------

render_ipsm() {
  if ! command -v dot &>/dev/null; then
    log "graphviz not found — skipping IPSM PNG rendering"
    return
  fi

  log "=== Rendering IPSM PNGs ==="
  local rendered=0

  for entry in "${MAB_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-1h-mab-s${S}-${NAME}"

    for i in $(seq 1 "$RUNS"); do
      local REP_DIR="${RESULTS_DIR}/${OUTDIR}_${i}"
      local DOT_FILE="${REP_DIR}/ipsm.dot"
      local PNG_FILE="${REP_DIR}/ipsm.png"

      if [ -f "$DOT_FILE" ] && [ ! -f "$PNG_FILE" ]; then
        if dot -Tpng "$DOT_FILE" -o "$PNG_FILE" 2>/dev/null; then
          rendered=$((rendered + 1))
        fi
      fi
    done
  done

  log "  Rendered ${rendered} IPSM PNGs"
  log "=== IPSM rendering done ==="
  echo ""
}

# ---------------------------------------------------------------------------
# Verify MAB output files exist for all reps
# ---------------------------------------------------------------------------

verify_mab_outputs() {
  log "=== Verifying MAB output files ==="
  local missing=0
  local found=0

  for entry in "${MAB_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-1h-mab-s${S}-${NAME}"

    for i in $(seq 1 "$RUNS"); do
      local REP_DIR="${RESULTS_DIR}/${OUTDIR}_${i}"

      if [ -d "$REP_DIR" ]; then
        for file in mab_stats mab_reward_log; do
          if [ -f "${REP_DIR}/${file}" ]; then
            found=$((found + 1))
          else
            warn "  Missing: ${REP_DIR}/${file}"
            missing=$((missing + 1))
          fi
        done
      fi
    done
  done

  log "  Found ${found} MAB output files, missing ${missing}"
  log "=== Verification done ==="
  echo ""
}

# ---------------------------------------------------------------------------
# Print summary table
# ---------------------------------------------------------------------------

print_summary() {
  log "=== Summary table ==="
  log ""
  printf "%-6s %-14s %22s %22s %8s %12s\n" \
    "s" "Algorithm" "execs (min/mean/max)" "paths (min/mean/max)" "crashes" "mab_rounds"
  printf "%-6s %-14s %22s %22s %8s %12s\n" \
    "------" "--------------" "----------------------" "----------------------" "--------" "------------"

  for entry in "${MAB_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-1h-mab-s${S}-${NAME}"

    local -a execs_vals=() paths_vals=()
    local crashes_sum=0 mab_rounds=0 rep_count=0

    for i in $(seq 1 "$RUNS"); do
      local REP_DIR="${RESULTS_DIR}/${OUTDIR}_${i}"
      local statsfile="${REP_DIR}/fuzzer_stats"
      local mabfile="${REP_DIR}/mab_stats"

      [ -f "$statsfile" ] || continue
      rep_count=$((rep_count + 1))

      local e p c
      e=$(grep "^execs_done"     "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')
      p=$(grep "^paths_total"    "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')
      c=$(grep "^unique_crashes" "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')
      execs_vals+=("${e:-0}")
      paths_vals+=("${p:-0}")
      crashes_sum=$((crashes_sum + ${c:-0}))

      if [ -f "$mabfile" ]; then
        local rounds
        rounds=$(awk '!/^mab/ && !/^timestamp/ && !/^#/ && !/^[[:space:]]*$/ && NF>=6 \
          {if($6+0 > max) max=$6+0} END {print (max>0?max:"0")}' "$mabfile")
        mab_rounds=$((mab_rounds + ${rounds:-0}))
      fi
    done

    if [ "$rep_count" -eq 0 ]; then
      printf "%-6s %-14s %22s %22s %8s %12s\n" \
        "s${S}" "$NAME" "N/A" "N/A" "N/A" "N/A"
      continue
    fi

    local execs_stat paths_stat
    execs_stat=$(printf '%s\n' "${execs_vals[@]}" \
      | awk 'BEGIN{mn=999999999;mx=0;sum=0;n=0}
             {n++;sum+=$1; if($1<mn)mn=$1; if($1>mx)mx=$1}
             END{printf "%d/%d/%d", mn, int(sum/n), mx}')
    paths_stat=$(printf '%s\n' "${paths_vals[@]}" \
      | awk 'BEGIN{mn=999999999;mx=0;sum=0;n=0}
             {n++;sum+=$1; if($1<mn)mn=$1; if($1>mx)mx=$1}
             END{printf "%d/%d/%d", mn, int(sum/n), mx}')

    printf "%-6s %-14s %22s %22s %8s %12s\n" \
      "s${S}" "$NAME" "$execs_stat" "$paths_stat" "$crashes_sum" "$mab_rounds"
  done

  log ""
  log "=== Summary done ==="
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  log "======================================================================"
  log "1h Sleeping-Bandit Pilot (exhaustion-based redesign validation)"
  log "======================================================================"
  echo ""

  preflight

  # Run sleeping-bandit algorithms sequentially, each with 10 parallel reps
  for entry in "${MAB_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    run_algo "$S" "$NAME"
  done

  # Post-processing
  extract_remaining
  render_ipsm
  verify_mab_outputs
  print_summary

  log "======================================================================"
  log "1h Sleeping-Bandit Pilot COMPLETE"
  log "======================================================================"
  log "Results: $RESULTS_DIR"
  log "Log file: $LOG_FILE"
  log ""
  log "NOTE: EXP3 (s4) / EXP3-IX (s5) baselines were not run in this pilot."
  log "      analyse_full.py will read them from results/1h-mab-diagnostic-5"
  log "      for the pulled-arm-set comparison (Section H)."
}

main "$@"
