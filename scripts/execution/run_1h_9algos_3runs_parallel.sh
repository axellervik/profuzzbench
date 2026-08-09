#!/bin/bash
# run_1h_9algos_3runs_parallel.sh — 1-hour pilot with all 9 algorithms, 3 runs each, 3 parallel batches
#
# Runs all algorithms (3 baselines + 6 MAB) with 3 repetitions each, organized in 3 concurrent batches:
#   Batch 1: s1 RANDOM, s2 ROUND-ROBIN, s3 FAVOR         (all parallel in background)
#   Batch 2: s4 EXP3, s5 EXP3-IX, s6 SB-EXP3             (all parallel in background)
#   Batch 3: s7 SB-EXP3-IX, s8 UCB1, s9 THOMPSON         (all parallel in background)
#
# Each batch runs its 3 algorithms sequentially, with 3 containers in parallel per algorithm.
# Total: 9 algorithms × 3 reps = 27 containers, wall time ~1h (all batches finish together).
#
# Phase 1 (parallel execution):
#   Three batch jobs launched in background, each running 3 algorithms sequentially.
#   (~1 h total wall time — all batches finish simultaneously)
#
# Phase 2 (result collection):
#   Wait for all 3 batch jobs to complete, extract tarballs immediately.
#
# Phase 3 (post-processing):
#   Extract remaining tarballs, print summary table, render IPSM PNGs, verify MAB outputs.
#
# Designed to run unsupervised. All output is tee'd to a timestamped log file.
# The script traps SIGINT/SIGTERM and cleans up any live containers before exit.
#
# Prerequisites:
#   source ~/fuzz/profuzzbench/fuzz-env.sh
#   bash run_1h_9algos_3runs_parallel.sh
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

RUNS=3                                # repetitions per algorithm
TIMEOUT=3600                          # 1 hour per run
SKIPCOUNT=5                           # gcovr every 5 seeds
IMAGE="openssl-mabflnet"
COMMON_OPTS="-P TLS -D 10000 -q 3 -E -K -R -W 100"
MIN_DISK_MB=10240                     # refuse to start if < 10 GB free (27 × 500 MB ≈ 13 GB)
CONTAINER_START_WAIT=15               # seconds to wait before liveness check
RESULTS_DIR="${RESULTS}/1h-9algos-3runs-parallel"
LOG_FILE="${RESULTS_DIR}/run_$(date +%Y%m%d_%H%M%S).log"

# All 9 algorithms
ALL_ALGOS=(
  "1:RANDOM"
  "2:ROUND-ROBIN"
  "3:FAVOR"
  "4:EXP3"
  "5:EXP3-IX"
  "6:SB-EXP3"
  "7:SB-EXP3-IX"
  "8:UCB1"
  "9:THOMPSON"
)

# Batch groupings (3 algos per batch)
BATCH_1_ALGOS=(
  "1:RANDOM"
  "2:ROUND-ROBIN"
  "3:FAVOR"
)

BATCH_2_ALGOS=(
  "4:EXP3"
  "5:EXP3-IX"
  "6:SB-EXP3"
)

BATCH_3_ALGOS=(
  "7:SB-EXP3-IX"
  "8:UCB1"
  "9:THOMPSON"
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
  log "  Total algorithms:   ${#ALL_ALGOS[@]}"
  log "  Total containers:   $((${#ALL_ALGOS[@]} * RUNS))"
  log "  Batches:            3 (parallel)"
  log "  Estimated wall time: ~$((TIMEOUT / 3600))h"
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
# Usage: run_algo_single S NAME BATCH_NAME
#
# Tarballs:      ${RESULTS_DIR}/${OUTDIR}_1.tar.gz .. ${OUTDIR}_${RUNS}.tar.gz
# Extracted dirs: ${RESULTS_DIR}/${OUTDIR}_1/     .. ${OUTDIR}_${RUNS}/
# ---------------------------------------------------------------------------

run_algo_single() {
  local S="$1" NAME="$2" BATCH_NAME="${3:-}"
  local OUTDIR="out-1h-${BATCH_NAME}s${S}-${NAME}"
  local OPTS="${COMMON_OPTS} -s ${S}"

  log "${BATCH_NAME:+[$BATCH_NAME] }--- Starting s${S} (${NAME}) — ${RUNS} reps in parallel ---"
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
    log "${BATCH_NAME:+[$BATCH_NAME] }  rep${i} container started: ${CID}"
  done

  # Liveness check
  sleep "$CONTAINER_START_WAIT"
  for i in "${!cids[@]}"; do
    local CID="${cids[$i]}"
    local rep=$((i + 1))
    if ! docker inspect --format='{{.State.Running}}' "$CID" 2>/dev/null | grep -q "true"; then
      warn "${BATCH_NAME:+[$BATCH_NAME] }  rep${rep} container ${CID} exited within ${CONTAINER_START_WAIT}s."
      docker logs --tail 30 "$CID" 2>&1 | while IFS= read -r line; do warn "${BATCH_NAME:+[$BATCH_NAME] }    $line"; done
    else
      log "${BATCH_NAME:+[$BATCH_NAME] }  rep${rep} container ${CID}: running (liveness OK)"
    fi
  done

  # Wait for all reps to finish
  log "${BATCH_NAME:+[$BATCH_NAME] }  Waiting for all ${RUNS} reps to finish..."
  for CID in "${cids[@]}"; do
    docker wait "$CID" > /dev/null || warn "${BATCH_NAME:+[$BATCH_NAME] }  docker wait returned non-zero for ${CID}."
  done
  log "${BATCH_NAME:+[$BATCH_NAME] }  All reps finished."

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
        log "${BATCH_NAME:+[$BATCH_NAME] }  rep${rep}: tarball copied → ${TARBALL}"
        break
      else
        warn "${BATCH_NAME:+[$BATCH_NAME] }  rep${rep}: docker cp attempt ${attempt}/3 failed."
        sleep 5
      fi
      if [ "$attempt" -eq 3 ]; then
        warn "${BATCH_NAME:+[$BATCH_NAME] }  rep${rep}: could not copy tarball after 3 attempts."
      fi
    done

    # Extract; tarball contains ${OUTDIR}/ at top level — rename to ${OUTDIR}_${rep}/
    if [ -f "$TARBALL" ]; then
      if [ -d "$REP_DIR" ]; then
        log "${BATCH_NAME:+[$BATCH_NAME] }  rep${rep}: ${REP_DIR} already exists — skipping extraction."
      else
        tar -xzf "$TARBALL" -C "$RESULTS_DIR" \
          && mv "${RESULTS_DIR}/${OUTDIR}" "$REP_DIR" \
          && log "${BATCH_NAME:+[$BATCH_NAME] }  rep${rep}: extracted → ${REP_DIR}" \
          || warn "${BATCH_NAME:+[$BATCH_NAME] }  rep${rep}: extraction/rename failed for ${TARBALL}"
      fi
      quick_stats "$REP_DIR" "$rep"
    fi

    docker rm "$CID" > /dev/null 2>&1 || true
    LIVE_CONTAINERS=("${LIVE_CONTAINERS[@]/$CID/}")
  done

  log "${BATCH_NAME:+[$BATCH_NAME] }--- s${S} (${NAME}) done ---"
  echo ""
}

# ---------------------------------------------------------------------------
# Run a batch of algorithms sequentially (but with parallel reps within each).
# Used as a background job.
#
# Usage: run_batch_algos BATCH_NAME ALGO1 ALGO2 ALGO3 ...
# ---------------------------------------------------------------------------

run_batch_algos() {
  local BATCH_NAME="$1"
  shift
  local -a algos=("$@")

  log "[$BATCH_NAME] Starting batch with ${#algos[@]} algorithms..."
  echo ""

  for entry in "${algos[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    run_algo_single "$S" "$NAME" "${BATCH_NAME}:"
  done

  log "[$BATCH_NAME] Batch complete."
  echo ""
}

# ---------------------------------------------------------------------------
# Extract any tarballs not yet extracted (fallback — run_algo_single extracts
# immediately, so this is a safety net).
# ---------------------------------------------------------------------------

extract_remaining() {
  log "=== Extracting any remaining tarballs ==="
  local found_any=0

  for entry in "${ALL_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"

    # Check all possible batch prefixes
    for batch_prefix in "batch1:" "batch2:" "batch3:"; do
      local OUTDIR="out-1h-${batch_prefix}s${S}-${NAME}"

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
            || warn "  Failed to extract: ${TARBALL}"
        else
          warn "  Tarball not found: ${TARBALL}"
        fi
      done
    done
  done

  [ "$found_any" -eq 0 ] && log "  All directories already present — nothing to do."
  echo ""
}

# ---------------------------------------------------------------------------
# Summary table — one row per algorithm, aggregated over RUNS reps.
# Columns: execs min/mean/max, paths min/mean/max, total crashes, mean mab_rounds
# ---------------------------------------------------------------------------

print_summary() {
  log "=== Summary (${RUNS} reps per algorithm) ==="
  printf "%-6s %-14s %22s %22s %8s %12s\n" \
    "s" "Algorithm" "execs (min/mean/max)" "paths (min/mean/max)" "crashes" "mab_rounds"
  printf "%-6s %-14s %22s %22s %8s %12s\n" \
    "------" "--------------" "----------------------" "----------------------" "--------" "------------"

  for entry in "${ALL_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"

    local -a execs_vals=() paths_vals=()
    local crashes_sum=0 mab_rounds=0 rep_count=0

    # Try all batch prefixes to find results
    for batch_prefix in "batch1:" "batch2:" "batch3:"; do
      local OUTDIR="out-1h-${batch_prefix}s${S}-${NAME}"

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
  echo ""
}

# ---------------------------------------------------------------------------
# Render IPSM PNGs — one per rep
# ---------------------------------------------------------------------------

render_ipsm() {
  if ! command -v dot &>/dev/null; then
    warn "graphviz not found — skipping IPSM rendering."
    return
  fi

  log "=== Rendering IPSM graphs ==="
  for entry in "${ALL_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"

    for batch_prefix in "batch1:" "batch2:" "batch3:"; do
      local OUTDIR="out-1h-${batch_prefix}s${S}-${NAME}"

      for i in $(seq 1 "$RUNS"); do
        local REP_DIR="${RESULTS_DIR}/${OUTDIR}_${i}"
        local DOTFILE="${REP_DIR}/ipsm.dot"
        local PNGFILE="${REP_DIR}/ipsm.png"
        if [ -f "$DOTFILE" ]; then
          dot -Tpng "$DOTFILE" -o "$PNGFILE" \
            && log "  s${S} (${NAME}) rep${i}: $PNGFILE" \
            || warn "  s${S} (${NAME}) rep${i}: dot failed"
        fi
      done
    done
  done
  echo ""
}

# ---------------------------------------------------------------------------
# Verify mab_reward_log, mab_stats for all MAB reps (s4–s9)
# ---------------------------------------------------------------------------

verify_mab_outputs() {
  log "=== Verifying MAB-specific outputs ==="
  local mab_algos=("4:EXP3" "5:EXP3-IX" "6:SB-EXP3" "7:SB-EXP3-IX" "8:UCB1" "9:THOMPSON")

  for entry in "${mab_algos[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local algo_ok=1

    for batch_prefix in "batch1:" "batch2:" "batch3:"; do
      local OUTDIR="out-1h-${batch_prefix}s${S}-${NAME}"

      for i in $(seq 1 "$RUNS"); do
        local REP_DIR="${RESULTS_DIR}/${OUTDIR}_${i}"
        local rep_ok=1

        if [ ! -d "$REP_DIR" ]; then
          continue
        fi

        for f in mab_reward_log mab_stats; do
          if [ -f "${REP_DIR}/${f}" ]; then
            local lines
            lines=$(wc -l < "${REP_DIR}/${f}")
            log "  s${S} (${NAME}) rep${i} ${f}: ${lines} lines OK"
          else
            warn "  s${S} (${NAME}) rep${i} ${f}: MISSING"
            rep_ok=0
            algo_ok=0
          fi
        done
        [ "$rep_ok" -eq 1 ] \
          && log "  s${S} (${NAME}) rep${i}: all MAB outputs present" \
          || warn "  s${S} (${NAME}) rep${i}: some MAB outputs missing"
      done
    done

    [ "$algo_ok" -eq 1 ] \
      && log "  s${S} (${NAME}): all ${RUNS} reps OK" \
      || warn "  s${S} (${NAME}): some reps had missing MAB outputs"
  done
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "======================================================"
log "  run_1h_9algos_3runs_parallel.sh  —  $(date)"
log "======================================================"
log "  Image:          $IMAGE"
log "  Runs per algo:  $RUNS"
log "  Timeout/run:    ${TIMEOUT}s"
log "  Results dir:    $RESULTS_DIR"
log "  Log file:       $LOG_FILE"
log "======================================================"
echo ""

preflight
check_disk "execution start"

# ── Phase 1: Launch 3 batch jobs in parallel ──────────────────────────────

log "====== Phase 1: Launching 3 batch jobs in parallel ======"
log "  Batch 1: ${BATCH_1_ALGOS[*]}"
log "  Batch 2: ${BATCH_2_ALGOS[*]}"
log "  Batch 3: ${BATCH_3_ALGOS[*]}"
log "  Estimated wall time: ~$((TIMEOUT / 3600))h"
echo ""

# Launch all 3 batches as background jobs
run_batch_algos "BATCH1" "${BATCH_1_ALGOS[@]}" &
BATCH_1_PID=$!
log "Batch 1 job spawned with PID $BATCH_1_PID"

run_batch_algos "BATCH2" "${BATCH_2_ALGOS[@]}" &
BATCH_2_PID=$!
log "Batch 2 job spawned with PID $BATCH_2_PID"

run_batch_algos "BATCH3" "${BATCH_3_ALGOS[@]}" &
BATCH_3_PID=$!
log "Batch 3 job spawned with PID $BATCH_3_PID"

echo ""
log "All 3 batch jobs launched. Waiting for completion..."
echo ""

# ── Phase 2: Wait for all batches to complete ─────────────────────────────

wait $BATCH_1_PID || warn "Batch 1 job exited with non-zero status."
log "Batch 1 job completed (PID $BATCH_1_PID)"

wait $BATCH_2_PID || warn "Batch 2 job exited with non-zero status."
log "Batch 2 job completed (PID $BATCH_2_PID)"

wait $BATCH_3_PID || warn "Batch 3 job exited with non-zero status."
log "Batch 3 job completed (PID $BATCH_3_PID)"

echo ""
log "====== All batch jobs completed ======"
echo ""

# ── Phase 3: Post-processing ──────────────────────────────────────────────

log "====== Phase 3: Post-processing ======"

extract_remaining
print_summary
render_ipsm
verify_mab_outputs

log "======================================================"
log "  All done. Results in: $RESULTS_DIR"
log "  Log file:             $LOG_FILE"
log "======================================================"
