#!/bin/bash
# run_1h_exp3_rarity_reward_pilot.sh — 1-hour EXP3-only pilot for the
#                                       rarity-weighted reward fix
#
# Validates: the rarity-weighted edge term in mab_update_reward(), which
#            replaces the virgin_bits-diff term to fix the reward-plateau
#            problem (rounds scoring exactly zero once an edge has been
#            seen once anywhere by any seed).
#
# Expected outcome: near-zero zero-reward rounds (vs ~18.7% baseline in
#                    1h-mab-diagnostic-6), reward-vs-time curve should
#                    stay flatter instead of collapsing toward zero
#                    partway through the run.
#
# Phase 1 (parallel):
#   EXP3 (-s 4) with 10 parallel repetitions (~1 h wall time)
#
# Phase 2 (post-processing):
#   Extract tarballs, print stats, verify MAB outputs.
#
# Designed to run unsupervised. All output is tee'd to a timestamped log file.
# The script traps SIGINT/SIGTERM and cleans up any live containers before exit.
#
# Prerequisites:
#   source ~/fuzz/profuzzbench/fuzz-env.sh
#   bash run_1h_exp3_rarity_reward_pilot.sh
#
# Required env vars (set by fuzz-env.sh):
#   PFBENCH   — path to profuzzbench repo  (e.g. ~/fuzz/profuzzbench)
#   RESULTS   — path to results root       (e.g. ~/fuzz/results)
#
# Required tools on host:
#   docker, awk, grep, df

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

RUNS=10                               # repetitions
TIMEOUT=3600                          # 1 hour per run
SKIPCOUNT=5                           # gcovr every 5 seeds
IMAGE="openssl-mabflnet"
COMMON_OPTS="-P TLS -D 10000 -q 3 -E -K -R -W 100"
MIN_DISK_MB=5120                      # refuse to start if < 5 GB free
CONTAINER_START_WAIT=15               # seconds before liveness check
# Auto-increment results directory: 1h-exp3-rarity-reward, -2, -3, ...
_base="${RESULTS}/1h-exp3-rarity-reward"
if [ ! -d "$_base" ]; then
  RESULTS_DIR="$_base"
else
  _n=2
  while [ -d "${_base}-${_n}" ]; do _n=$((_n + 1)); done
  RESULTS_DIR="${_base}-${_n}"
fi
unset _base _n
LOG_FILE="${RESULTS_DIR}/run_$(date +%Y%m%d_%H%M%S).log"

# Algorithm: EXP3 only
S=4
NAME="EXP3"
OUTDIR="out-1h-mab-s${S}-${NAME}-rarity-reward"

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

  log "  Runs: $RUNS repetitions (parallel)"
  log "  Timeout per run: ${TIMEOUT}s"
  log "  Expected wall time: ~1h (${RUNS} parallel containers)"
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
  local mabfile="${dir}/mab_reward_log"

  if [ ! -f "$statsfile" ]; then
    log "    rep${rep}: fuzzer_stats not found"
    return
  fi

  local execs paths crashes mab_rounds zero_reward_rounds zero_pct
  execs=$(grep   "^execs_done"     "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')
  paths=$(grep   "^paths_total"    "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')
  crashes=$(grep "^unique_crashes" "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')

  if [ -f "$mabfile" ]; then
    mab_rounds=$(tail -n +2 "$mabfile" | wc -l)
    # Column 6 (1-indexed) is "reward" in the CSV
    # (timestamp_ms,state_id,arm_idx,edges_before,edges_after,reward,distinct_edges_credited,rarity_sum_raw)
    zero_reward_rounds=$(tail -n +2 "$mabfile" | awk -F',' '$6+0==0 {c++} END{print c+0}')
    if [ "$mab_rounds" -gt 0 ]; then
      zero_pct=$(awk -v z="$zero_reward_rounds" -v n="$mab_rounds" 'BEGIN{printf "%.1f", (z/n)*100}')
    else
      zero_pct="0.0"
    fi
  else
    mab_rounds="-"
    zero_reward_rounds="-"
    zero_pct="-"
  fi

  log "    rep${rep}: execs=${execs} paths=${paths} crashes=${crashes} mab_rounds=${mab_rounds} zero_reward=${zero_reward_rounds} (${zero_pct}%)"
}

# ---------------------------------------------------------------------------
# Run RUNS containers in parallel, wait for all, copy and extract results.
# ---------------------------------------------------------------------------

run_pilot() {
  local OPTS="${COMMON_OPTS} -s ${S}"

  log "--- Starting EXP3 rarity-weighted reward pilot — ${RUNS} reps in parallel ---"
  check_disk "pilot"

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

    # Extract
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

  log "--- Pilot execution complete ---"
  echo ""
}

# ---------------------------------------------------------------------------
# Extract any tarballs not yet extracted (fallback).
# ---------------------------------------------------------------------------

extract_remaining() {
  log "=== Extracting any remaining tarballs ==="
  local found_any=0

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

  if [ "$found_any" -eq 0 ]; then
    log "  (all tarballs already extracted)"
  fi
  log "=== Extraction phase done ==="
  echo ""
}

# ---------------------------------------------------------------------------
# Verify MAB output files exist for all reps
# ---------------------------------------------------------------------------

verify_mab_outputs() {
  log "=== Verifying MAB output files ==="
  local missing=0
  local found=0

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

  log "  Found ${found} MAB output files, missing ${missing}"
  log "=== Verification done ==="
  echo ""
}

# ---------------------------------------------------------------------------
# Print summary table with zero-reward-round metric (the key metric for
# validating the plateau fix)
# ---------------------------------------------------------------------------

print_summary() {
  log "=== Summary table (EXP3 rarity-weighted reward pilot) ==="
  log ""
  printf "%-6s %10s %12s %14s %10s %10s %10s\n" \
    "rep" "execs" "mab_rounds" "zero_reward" "zero_pct" "paths" "crashes"
  printf "%-6s %10s %12s %14s %10s %10s %10s\n" \
    "------" "----------" "----------" "------------" "--------" "--------" "--------"

  local -a rounds_vals=() zero_vals=() zero_pct_vals=()
  local rep_count=0

  for i in $(seq 1 "$RUNS"); do
    local REP_DIR="${RESULTS_DIR}/${OUTDIR}_${i}"
    local statsfile="${REP_DIR}/fuzzer_stats"
    local rewardfile="${REP_DIR}/mab_reward_log"

    [ -f "$statsfile" ] || continue
    rep_count=$((rep_count + 1))

    local e p c r z zp
    e=$(grep "^execs_done"     "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')
    p=$(grep "^paths_total"    "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')
    c=$(grep "^unique_crashes" "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')
    r=$(tail -n +2 "$rewardfile" 2>/dev/null | wc -l)
    z=$(tail -n +2 "$rewardfile" 2>/dev/null | awk -F',' '$6+0==0 {c++} END{print c+0}')
    if [ "${r:-0}" -gt 0 ]; then
      zp=$(awk -v z="${z:-0}" -v n="${r:-1}" 'BEGIN{printf "%.1f", (z/n)*100}')
    else
      zp="0.0"
    fi

    rounds_vals+=("${r:-0}")
    zero_vals+=("${z:-0}")
    zero_pct_vals+=("${zp:-0}")

    printf "%-6s %10s %12s %14s %10s %10s %10s\n" \
      "rep${i}" "$e" "$r" "$z" "${zp}%" "$p" "$c"
  done

  log ""
  if [ "$rep_count" -gt 0 ]; then
    local rounds_stat zero_stat zero_pct_stat
    rounds_stat=$(printf '%s\n' "${rounds_vals[@]}" \
      | awk 'BEGIN{mn=999999999;mx=0;sum=0;n=0}
             {n++;sum+=$1; if($1<mn)mn=$1; if($1>mx)mx=$1}
             END{printf "%d/%d/%d", mn, int(sum/n), mx}')
    zero_stat=$(printf '%s\n' "${zero_vals[@]}" \
      | awk 'BEGIN{mn=999999999;mx=0;sum=0;n=0}
             {n++;sum+=$1; if($1<mn)mn=$1; if($1>mx)mx=$1}
             END{printf "%d/%d/%d", mn, int(sum/n), mx}')
    zero_pct_stat=$(printf '%s\n' "${zero_pct_vals[@]}" \
      | awk 'BEGIN{mn=999999;mx=0;sum=0;n=0}
             {n++;sum+=$1; if($1<mn)mn=$1; if($1>mx)mx=$1}
             END{printf "%.1f/%.1f/%.1f", mn, sum/n, mx}')

    log ""
    log "STATS (min/mean/max):"
    log "  mab_rounds:      $rounds_stat"
    log "  zero_reward:     $zero_stat"
    log "  zero_reward_pct: $zero_pct_stat  (compare vs ~18.7% in 1h-mab-diagnostic-6 baseline)"
    log ""
  fi

  log "=== Summary done ==="
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  log "======================================================================"
  log "1h EXP3 Pilot: Rarity-Weighted Reward Validation"
  log "======================================================================"
  log "Testing: rarity-weighted edge term in mab_update_reward(), replacing"
  log "the virgin_bits-diff term to fix the reward-plateau problem."
  log "Expected: zero-reward round % well below the ~18.7% pre-fix baseline."
  log "======================================================================"
  echo ""

  preflight
  run_pilot
  extract_remaining
  verify_mab_outputs
  print_summary

  log "======================================================================"
  log "1h EXP3 Rarity-Weighted Reward Pilot COMPLETE"
  log "======================================================================"
  log "Results: $RESULTS_DIR"
  log "Log file: $LOG_FILE"
  log ""
}

main "$@"
