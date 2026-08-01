#!/bin/bash
# run_30min_mab_parallel.sh — 30-minute MAB validation pilots
#
# All 6 MAB algorithms run 10 repetitions in parallel (60 containers total).
# Each run is 30 minutes (1800 seconds). Total wall time: ~30 minutes.
#
# Designed to run unsupervised. All output is tee'd to a timestamped log file.
# The script traps SIGINT/SIGTERM and cleans up any live containers before exit.
#
# Prerequisites:
#   source ~/fuzz/profuzzbench/fuzz-env.sh
#   bash run_30min_mab_parallel.sh
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

RUNS=10                               # repetitions per MAB algorithm
TIMEOUT=1800                          # 30 minutes per run
SKIPCOUNT=5                           # gcovr every 5 seeds
IMAGE="openssl-mabflnet"
COMMON_OPTS="-P TLS -D 10000 -q 3 -E -K -R -W 100"
MIN_DISK_MB=5120                      # refuse to start if < 5 GB free
CONTAINER_START_WAIT=15               # seconds to wait before liveness check
RESULTS_DIR="${RESULTS}/30min-mab-parallel"
LOG_FILE="${RESULTS_DIR}/run_$(date +%Y%m%d_%H%M%S).log"

MAB_ALGOS=(
  "4:EXP3"
  "5:EXP3-IX"
  "6:SB-EXP3"
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

  docker info &>/dev/null || die "Docker daemon not running."
  log "  Docker daemon: OK"

  docker image inspect "$IMAGE" &>/dev/null \
    || die "Docker image '$IMAGE' not found. Build it first."
  log "  Image '$IMAGE': found"

  [ -n "${PFBENCH:-}" ] || die "PFBENCH is not set. Source fuzz-env.sh first."
  [ -n "${RESULTS:-}" ] || die "RESULTS is not set. Source fuzz-env.sh first."
  log "  PFBENCH=$PFBENCH"
  log "  RESULTS=$RESULTS"

  mkdir -p "$RESULTS_DIR"
  touch "${RESULTS_DIR}/.write_test" \
    && rm "${RESULTS_DIR}/.write_test" \
    || die "Results directory not writable: $RESULTS_DIR"
  log "  Results dir: $RESULTS_DIR (writable)"

  if ! command -v dot &>/dev/null; then
    warn "'dot' (graphviz) not found — IPSM PNGs will be skipped."
    warn "Install with: sudo apt-get install graphviz"
  else
    log "  graphviz: OK"
  fi

  log "  Runs per algorithm: $RUNS"
  log "  Timeout per run:    ${TIMEOUT}s (30 minutes)"
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
    mab_rounds=$(awk '!/^mab/ && !/^timestamp/ && !/^#/ && !/^[[:space:]]*$/ && NF>=6 \
      {if($6+0 > max) max=$6+0} END {print (max>0?max:"0")}' "$mabfile")
    if [ -z "$mab_rounds" ]; then mab_rounds="0"; fi
  else
    mab_rounds="-"
  fi

  log "    rep${rep}: execs=${execs} paths=${paths} crashes=${crashes} mab_rounds=${mab_rounds}"
}

# ---------------------------------------------------------------------------
# Run all MAB algorithms in parallel — all 4 algos × 10 reps = 40 containers
# ---------------------------------------------------------------------------

run_all_parallel() {
  local -a all_cids=()
  local -a all_names=()     # parallel arrays: algo name for each container
  local -a all_outdirs=()   # base OUTDIR (without _N suffix)
  local -a all_reps=()      # rep index for each container
  local -a all_s_values=()  # seed selection algo number

  check_disk "parallel MAB algorithms"

  local total=$(( ${#MAB_ALGOS[@]} * RUNS ))
  log "--- Starting all MAB algorithms: ${#MAB_ALGOS[@]} algos × ${RUNS} reps = ${total} containers ---"

  for entry in "${MAB_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-30m-s${S}-${NAME}"
    local OPTS="${COMMON_OPTS} -s ${S}"

    for i in $(seq 1 "$RUNS"); do
      local CID
      CID=$(docker run --cpus=1 -d \
        "$IMAGE" \
        /bin/bash -c \
        "cd /home/ubuntu/experiments && run mabflnet '${OUTDIR}' '${OPTS}' ${TIMEOUT} ${SKIPCOUNT}")
      register_container "$CID"
      all_cids+=("$CID")
      all_names+=("$NAME")
      all_outdirs+=("$OUTDIR")
      all_reps+=("$i")
      all_s_values+=("$S")
      log "  s${S} (${NAME}) rep${i} container started: ${CID}"
    done
  done

  # Liveness check
  sleep "$CONTAINER_START_WAIT"
  for i in "${!all_cids[@]}"; do
    local CID="${all_cids[$i]}"
    if ! docker inspect --format='{{.State.Running}}' "$CID" 2>/dev/null | grep -q "true"; then
      warn "  ${all_names[$i]} rep${all_reps[$i]} container ${CID} exited within ${CONTAINER_START_WAIT}s."
      docker logs --tail 30 "$CID" 2>&1 | while IFS= read -r line; do warn "    $line"; done
    fi
  done
  log "  Liveness checks done."

  # Wait for all containers
  log "  Waiting for all ${total} containers to finish (${TIMEOUT}s + post-run overhead)..."
  for CID in "${all_cids[@]}"; do
    docker wait "$CID" > /dev/null || warn "  docker wait non-zero for ${CID}."
  done
  log "  All containers finished."

  # Copy, extract, quick stats
  for i in "${!all_cids[@]}"; do
    local CID="${all_cids[$i]}"
    local OUTDIR="${all_outdirs[$i]}"
    local NAME="${all_names[$i]}"
    local rep="${all_reps[$i]}"
    local S="${all_s_values[$i]}"
    local TARBALL="${RESULTS_DIR}/${OUTDIR}_${rep}.tar.gz"
    local REP_DIR="${RESULTS_DIR}/${OUTDIR}_${rep}"

    local attempt
    for attempt in 1 2 3; do
      if docker cp "${CID}:/home/ubuntu/experiments/${OUTDIR}.tar.gz" "$TARBALL" 2>/dev/null; then
        log "  s${S} (${NAME}) rep${rep}: tarball copied → ${TARBALL}"
        break
      else
        warn "  s${S} (${NAME}) rep${rep}: docker cp attempt ${attempt}/3 failed."
        sleep 5
      fi
      if [ "$attempt" -eq 3 ]; then
        warn "  s${S} (${NAME}) rep${rep}: could not copy tarball after 3 attempts."
      fi
    done

    if [ -f "$TARBALL" ]; then
      if [ -d "$REP_DIR" ]; then
        log "  s${S} (${NAME}) rep${rep}: ${REP_DIR} already exists — skipping extraction."
      else
        tar -xzf "$TARBALL" -C "$RESULTS_DIR" \
          && mv "${RESULTS_DIR}/${OUTDIR}" "$REP_DIR" \
          && log "  s${S} (${NAME}) rep${rep}: extracted → ${REP_DIR}" \
          || warn "  s${S} (${NAME}) rep${rep}: extraction/rename failed for ${TARBALL}"
      fi
      quick_stats "$REP_DIR" "$rep"
    fi

    docker rm "$CID" > /dev/null 2>&1 || true
    LIVE_CONTAINERS=("${LIVE_CONTAINERS[@]/$CID/}")
  done

  log "--- All MAB containers done ---"
  echo ""
}

# ---------------------------------------------------------------------------
# Extract any remaining tarballs
# ---------------------------------------------------------------------------

extract_remaining() {
  log "=== Extracting any remaining tarballs ==="
  local found_any=0

  for entry in "${MAB_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-30m-s${S}-${NAME}"

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

  [ "$found_any" -eq 0 ] && log "  All directories already present — nothing to do."
  echo ""
}

# ---------------------------------------------------------------------------
# Summary table — one row per algorithm, aggregated over RUNS reps.
# ---------------------------------------------------------------------------

print_summary() {
  log "=== Summary (${RUNS} reps per algorithm, 30 min each) ==="
  printf "%-6s %-14s %20s %20s %8s %12s\n" \
    "s" "Algorithm" "execs (min/mean/max)" "paths (min/mean/max)" "crashes" "mab_rounds"
  printf "%-6s %-14s %20s %20s %8s %12s\n" \
    "------" "--------------" "--------------------" "--------------------" "--------" "------------"

  for entry in "${MAB_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-30m-s${S}-${NAME}"

    execs_vals=()
    paths_vals=()
    crashes_sum=0
    mab_rounds=0
    rep_count=0

    for i in $(seq 1 "$RUNS"); do
      REP_DIR="${RESULTS_DIR}/${OUTDIR}_${i}"
      statsfile="${REP_DIR}/fuzzer_stats"
      mabfile="${REP_DIR}/mab_stats"

      [ -f "$statsfile" ] || continue
      rep_count=$((rep_count + 1))

      # Extract from fuzzer_stats
      execs=$(grep "^execs_done"     "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')
      paths=$(grep "^paths_total"    "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')
      crashes=$(grep "^unique_crashes" "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')
      
      execs_vals+=("${execs:-0}")
      paths_vals+=("${paths:-0}")
      crashes_sum=$((crashes_sum + ${crashes:-0}))

      # Extract max mab_round from mab_stats if it exists (max last_selected, field 6)
      if [ -f "$mabfile" ]; then
        rounds=$(awk '!/^mab/ && !/^timestamp/ && !/^#/ && !/^[[:space:]]*$/ && NF>=6 \
          {if($6+0 > max) max=$6+0} END {print (max>0?max:"0")}' "$mabfile")
        mab_rounds=$((mab_rounds + ${rounds:-0}))
      fi
    done

    if [ "$rep_count" -eq 0 ]; then
      printf "%-6s %-14s %20s %20s %8s %12s\n" \
        "s${S}" "$NAME" "N/A" "N/A" "N/A" "N/A"
      continue
    fi

    # Compute min/mean/max for execs and paths
    execs_stat=$(printf '%s\n' "${execs_vals[@]}" \
      | awk 'BEGIN{min=999999999;max=0;sum=0;n=0}
             {n++;sum+=$1; if($1<min)min=$1; if($1>max)max=$1}
             END{printf "%d/%d/%d", min, int(sum/n), max}')
    paths_stat=$(printf '%s\n' "${paths_vals[@]}" \
      | awk 'BEGIN{min=999999999;max=0;sum=0;n=0}
             {n++;sum+=$1; if($1<min)min=$1; if($1>max)max=$1}
             END{printf "%d/%d/%d", min, int(sum/n), max}')

    printf "%-6s %-14s %20s %20s %8s %12s\n" \
      "s${S}" "$NAME" "$execs_stat" "$paths_stat" "$crashes_sum" "$mab_rounds"
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
  for entry in "${MAB_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-30m-s${S}-${NAME}"

    for i in $(seq 1 "$RUNS"); do
      local REP_DIR="${RESULTS_DIR}/${OUTDIR}_${i}"
      local DOTFILE="${REP_DIR}/ipsm.dot"
      local PNGFILE="${REP_DIR}/ipsm.png"
      if [ -f "$DOTFILE" ]; then
        dot -Tpng "$DOTFILE" -o "$PNGFILE" \
          && log "  s${S} (${NAME}) rep${i}: $PNGFILE" \
          || warn "  s${S} (${NAME}) rep${i}: dot failed"
      else
        warn "  s${S} (${NAME}) rep${i}: ipsm.dot not found"
      fi
    done
  done
  echo ""
}

# ---------------------------------------------------------------------------
# Verify mab_reward_log, mab_stats for all MAB reps
# ---------------------------------------------------------------------------

verify_mab_outputs() {
  log "=== Verifying MAB-specific outputs ==="
  for entry in "${MAB_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-30m-s${S}-${NAME}"
    local algo_ok=1

    for i in $(seq 1 "$RUNS"); do
      local REP_DIR="${RESULTS_DIR}/${OUTDIR}_${i}"
      local rep_ok=1

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
log "  run_30min_mab_parallel.sh  —  $(date)"
log "======================================================"
log "  Image:          $IMAGE"
log "  Runs per algo:  $RUNS"
log "  Timeout/run:    ${TIMEOUT}s (30 minutes)"
log "  Total algos:    ${#MAB_ALGOS[@]}"
log "  Total containers: $(( ${#MAB_ALGOS[@]} * RUNS ))"
log "  Results dir:    $RESULTS_DIR"
log "  Log file:       $LOG_FILE"
log "======================================================"
echo ""

preflight

# ── Main execution: All MAB algorithms in parallel ────────────────────────

log "====== Running all MAB algorithms in parallel ======"
log "  Algorithms: ${MAB_ALGOS[*]}"
log "  Estimated wall time: ~30 min + post-run overhead"
echo ""

run_all_parallel

# ── Post-processing ────────────────────────────────────────────────────────

log "====== Post-processing ======"

extract_remaining
print_summary
render_ipsm
verify_mab_outputs

log "======================================================"
log "  All done. Results in: $RESULTS_DIR"
log "  Log file:             $LOG_FILE"
log "======================================================"
