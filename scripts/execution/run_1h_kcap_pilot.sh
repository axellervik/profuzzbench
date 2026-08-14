#!/bin/bash
# run_1h_kcap_pilot.sh — 1-hour pilot, EXP3 / EXP3-IX / SLEEPING_BANDIT /
#                         SLEEPING_BANDIT_IX / UCB1 / THOMPSON_SAMPLING,
#                         10 reps in parallel per algorithm, algorithms
#                         run sequentially.
#
# Validates mab_cap_seeds() in afl-fuzz.c: caps each state's seed/arm pool
# at MAX_SEEDS_PER_STATE (30), evicting the lowest-performing arm (never
# the one in flight this round) once the cap is exceeded.
#
# The first 4 algorithms need a fresh baseline anyway (their prior runs
# predate the percentile-rank reward fix), so this pilot triple-duties
# as: K-cap validation, sleeping-bandit asleep-predicate re-validation,
# and a non-stale baseline. UCB1 and Thompson Sampling are included
# opportunistically to get fresh K-cap data on them too.
#
# Layout:
#   s4 EXP3              — 10 reps in parallel (~1h)
#   s5 EXP3-IX           — 10 reps in parallel (~1h)
#   s6 SLEEPING_BANDIT   — 10 reps in parallel (~1h)
#   s7 SLEEPING_BANDIT_IX— 10 reps in parallel (~1h)
#   s8 UCB1              — 10 reps in parallel (~1h)
#   s9 THOMPSON_SAMPLING — 10 reps in parallel (~1h)
# Algorithms run sequentially — total wall time ~6h.
#
# Checks printed per rep and aggregated in the summary:
#   - crashes (should be 0 unless a real bug is found)
#   - mab_rounds (sanity: round rate not badly disrupted by eviction work)
#   - zero_pct/sat_pct (reward composition sanity, carried over)
#   - state 0 arm count (should be capped at 30 once seeds_count exceeds it)
#   - eviction count (duplicate arm_idx rows in mab_seed_map for state 0)
#   - arm discriminability: coefficient of variation of cumul_reward/
#     pull_count across pulled arms in state 0
#   - reward-log anomaly count: zero/negative/NaN reward rows anywhere in
#     the log (coarse proxy only — mab_seed_map has no timestamp column,
#     so exact correlation with eviction events isn't possible; a nonzero
#     eviction count alongside a nonzero anomaly count warrants a manual
#     look, but the script does not attempt to line them up in time)
#
# Designed to run unsupervised. Output tee'd to a timestamped log file.
# Traps SIGINT/SIGTERM and cleans up live containers before exit.
#
# Prerequisites:
#   source ~/fuzz/profuzzbench/fuzz-env.sh
#   bash run_1h_kcap_pilot.sh
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

RUNS=10                               # repetitions per algorithm (parallel)
TIMEOUT=3600                          # 1 hour per run
SKIPCOUNT=5                           # gcovr every 5 seeds
IMAGE="openssl-mabflnet-kcap"
COMMON_OPTS="-P TLS -D 10000 -q 3 -E -K -R -W 100"
MIN_DISK_MB=5120                      # refuse to start if < 5 GB free (10 x ~500MB per algo)
CONTAINER_START_WAIT=15               # seconds before liveness check

# Auto-increment results directory: 1h-kcap-6mab-10runs, -2, -3, ...
_base="${RESULTS}/1h-kcap-6mab-10runs"
if [ ! -d "$_base" ]; then
  RESULTS_DIR="$_base"
else
  _n=2
  while [ -d "${_base}-${_n}" ]; do _n=$((_n + 1)); done
  RESULTS_DIR="${_base}-${_n}"
fi
unset _base _n
LOG_FILE="${RESULTS_DIR}/run_$(date +%Y%m%d_%H%M%S).log"

# 4 algorithms needing a fresh baseline + UCB1/Thompson opportunistically,
# run sequentially in this order
MAB_ALGOS=(
  "4:EXP3"
  "5:EXP3-IX"
  "6:SLEEPING_BANDIT"
  "7:SLEEPING_BANDIT_IX"
  "8:UCB1"
  "9:THOMPSON_SAMPLING"
)

MAX_SEEDS_PER_STATE=30                # must match config.h

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
    || die "Docker image '$IMAGE' not found. Build it first (must include mab_cap_seeds() in afl-fuzz.c)."
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

  log "  Algorithms:          ${#MAB_ALGOS[@]} (sequential)"
  log "  Reps per algorithm:  $RUNS (parallel)"
  log "  Timeout per run:     ${TIMEOUT}s"
  log "  Estimated wall time: ~$(( (TIMEOUT * ${#MAB_ALGOS[@]}) / 3600 ))h"
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
# State 0's arm count and discriminability from mab_stats.
#
# mab_stats format (after an 8-line header block + 1 blank line + 1
# column-header comment line):
#   state_id  arm_idx  pull_count  log_weight  cumul_reward  last_selected
#
# Usage: kcap_stats MAB_STATS_FILE
# Prints: "arms=<n> capped=<yes|no> cov=<val> arms_pulled=<n>"
#   arms:    total arm rows for state 0 (should be <= MAX_SEEDS_PER_STATE)
#   capped:  yes if arms == MAX_SEEDS_PER_STATE (cap is actively binding)
#   cov:     coefficient of variation of cumul_reward/pull_count across
#            pulled arms (higher = arms are more discriminable)
# ---------------------------------------------------------------------------

kcap_stats() {
  local mabstats="$1"
  if [ ! -f "$mabstats" ]; then
    echo "arms=- capped=- cov=- arms_pulled=-"
    return
  fi

  awk -v cap="$MAX_SEEDS_PER_STATE" '
    BEGIN { in_data = 0 }
    /^# state_id/ { in_data = 1; next }
    in_data && NF >= 5 && $1 == 0 {
      n_arms++
      if ($3 > 0) {
        avg = $5 / $3
        avgs[n_pulled] = avg
        n_pulled++
        sum += avg
      }
    }
    END {
      capped = (n_arms >= cap) ? "yes" : "no"
      if (n_pulled < 2) {
        printf "arms=%d capped=%s cov=- arms_pulled=%d\n", n_arms, capped, n_pulled
        exit
      }
      mean = sum / n_pulled
      ss = 0
      for (i = 0; i < n_pulled; i++) { d = avgs[i] - mean; ss += d * d }
      sd = sqrt(ss / n_pulled)
      cov = (mean != 0) ? (sd / mean) : 0
      printf "arms=%d capped=%s cov=%.3f arms_pulled=%d\n", n_arms, capped, cov, n_pulled
    }
  ' "$mabstats"
}

# ---------------------------------------------------------------------------
# Eviction count for state 0 — number of duplicate (state_id, arm_idx)
# rows in mab_seed_map, i.e. how many times an arm slot was reused after
# an eviction. 0 means the cap never fired (state 0 stayed under 30 seeds
# the whole run); anything > 0 confirms mab_cap_seeds() is active.
#
# Usage: eviction_count MAB_SEED_MAP_FILE
# Prints: "evictions=<n>"
# ---------------------------------------------------------------------------

eviction_count() {
  local mapfile="$1"
  if [ ! -f "$mapfile" ]; then
    echo "evictions=-"
    return
  fi
  awk -F',' '
    NR > 1 && $1 == 0 { seen[$2]++ }
    END {
      n = 0
      for (k in seen) if (seen[k] > 1) n += (seen[k] - 1)
      printf "evictions=%d\n", n
    }
  ' "$mapfile"
}

# ---------------------------------------------------------------------------
# Reward-log anomaly count — rows with zero, negative, or non-numeric
# reward anywhere in the log. Coarse proxy for check #6 (no timestamp
# column in mab_seed_map to correlate with eviction events precisely).
#
# Usage: reward_anomaly_count MAB_REWARD_LOG_FILE
# Prints: "anomalies=<n>"
# ---------------------------------------------------------------------------

reward_anomaly_count() {
  local rewardfile="$1"
  if [ ! -f "$rewardfile" ]; then
    echo "anomalies=-"
    return
  fi
  tail -n +2 "$rewardfile" | awk -F',' '
    {
      r = $6
      if (r !~ /^-?[0-9]+(\.[0-9]+)?$/ || r + 0 < 0) c++
    }
    END { printf "anomalies=%d\n", c + 0 }
  '
}

# ---------------------------------------------------------------------------
# Print a quick per-rep stats line for one extracted rep directory.
# Usage: quick_stats REP_DIR REP_INDEX
# ---------------------------------------------------------------------------

quick_stats() {
  local dir="$1" rep="$2"
  local statsfile="${dir}/fuzzer_stats"
  local mabfile="${dir}/mab_reward_log"
  local mabstats="${dir}/mab_stats"
  local mapfile="${dir}/mab_seed_map"

  if [ ! -f "$statsfile" ]; then
    log "    rep${rep}: fuzzer_stats not found"
    return
  fi

  local execs paths crashes mab_rounds zero_reward_rounds sat_rounds zero_pct sat_pct
  execs=$(grep   "^execs_done"     "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')
  paths=$(grep   "^paths_total"    "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')
  crashes=$(grep "^unique_crashes" "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')

  if [ -f "$mabfile" ]; then
    mab_rounds=$(tail -n +2 "$mabfile" | wc -l)
    # Column 6 (1-indexed) is "reward" in the CSV:
    # timestamp_ms,state_id,arm_idx,edges_before,edges_after,reward,
    # distinct_edges_credited,rarity_sum_raw,raw_score
    zero_reward_rounds=$(tail -n +2 "$mabfile" | awk -F',' '$6+0==0 {c++} END{print c+0}')
    sat_rounds=$(tail -n +2 "$mabfile" | awk -F',' '$6+0>=1.0 {c++} END{print c+0}')
    if [ "$mab_rounds" -gt 0 ]; then
      zero_pct=$(awk -v z="$zero_reward_rounds" -v n="$mab_rounds" 'BEGIN{printf "%.1f", (z/n)*100}')
      sat_pct=$(awk -v s="$sat_rounds" -v n="$mab_rounds" 'BEGIN{printf "%.1f", (s/n)*100}')
    else
      zero_pct="0.0"
      sat_pct="0.0"
    fi
  else
    mab_rounds="-"
    zero_pct="-"
    sat_pct="-"
  fi

  local kcap evict anom
  kcap=$(kcap_stats "$mabstats" 2>/dev/null) || kcap="arms=? capped=? cov=? arms_pulled=?"
  evict=$(eviction_count "$mapfile" 2>/dev/null) || evict="evictions=?"
  anom=$(reward_anomaly_count "$mabfile" 2>/dev/null) || anom="anomalies=?"

  log "    rep${rep}: execs=${execs} paths=${paths} crashes=${crashes} mab_rounds=${mab_rounds} zero_reward=(${zero_pct}%) saturated=(${sat_pct}%) state0[${kcap}] ${evict} ${anom}"
}

# ---------------------------------------------------------------------------
# Run RUNS containers for one algorithm in parallel, wait for all, copy and
# immediately extract results.
#
# Usage: run_algo_single S NAME
#
# Tarballs:       ${RESULTS_DIR}/${OUTDIR}_1.tar.gz .. ${OUTDIR}_${RUNS}.tar.gz
# Extracted dirs: ${RESULTS_DIR}/${OUTDIR}_1/       .. ${OUTDIR}_${RUNS}/
# ---------------------------------------------------------------------------

run_algo_single() {
  local S="$1" NAME="$2"
  local OUTDIR="out-1h-mab-s${S}-${NAME}-kcap"
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
  log "  Waiting for all ${RUNS} reps to finish (~$((TIMEOUT / 60)) min)..."
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
# Run all algorithms sequentially (one at a time, 10 reps in parallel
# within each).
# ---------------------------------------------------------------------------

run_all_algos_sequentially() {
  log "====== Running ${#MAB_ALGOS[@]} MAB algorithms sequentially ======"
  local idx=1
  for entry in "${MAB_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    log "  [$idx/${#MAB_ALGOS[@]}] Algorithm: s${S} (${NAME})"
    run_algo_single "$S" "$NAME"
    idx=$((idx + 1))
  done
  log "====== All ${#MAB_ALGOS[@]} algorithms complete ======"
  echo ""
}

# ---------------------------------------------------------------------------
# Extract any tarballs not yet extracted (fallback — run_algo_single
# extracts immediately, so this is a safety net).
# ---------------------------------------------------------------------------

extract_remaining() {
  log "=== Extracting any remaining tarballs ==="
  local found_any=0

  for entry in "${MAB_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-1h-mab-s${S}-${NAME}-kcap"

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
# Verify mab_reward_log, mab_stats, mab_seed_map for all reps of all
# algorithms
# ---------------------------------------------------------------------------

verify_mab_outputs() {
  log "=== Verifying MAB output files ==="
  local missing=0
  local found=0

  for entry in "${MAB_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-1h-mab-s${S}-${NAME}-kcap"

    for i in $(seq 1 "$RUNS"); do
      local REP_DIR="${RESULTS_DIR}/${OUTDIR}_${i}"

      if [ -d "$REP_DIR" ]; then
        for file in mab_stats mab_reward_log mab_seed_map; do
          if [ -f "${REP_DIR}/${file}" ]; then
            found=$((found + 1))
          else
            warn "  Missing: ${REP_DIR}/${file}"
            missing=$((missing + 1))
          fi
        done
      else
        warn "  Missing directory: ${REP_DIR}"
        missing=$((missing + 3))
      fi
    done
  done

  log "  Found ${found} MAB output files, missing ${missing}"
  log "=== Verification done ==="
  echo ""
}

# ---------------------------------------------------------------------------
# Print summary table — one row per algorithm, aggregated over RUNS reps.
# ---------------------------------------------------------------------------

print_summary() {
  log "=== Summary (${RUNS} reps per algorithm, K-cap validation) ==="
  log ""
  printf "%-6s %-18s %10s %12s %10s %10s %8s %8s %10s %10s\n" \
    "s" "Algorithm" "execs" "mab_rounds" "zero_pct" "sat_pct" "arms" "cov" "evictions" "anomalies"
  printf "%-6s %-18s %10s %12s %10s %10s %8s %8s %10s %10s\n" \
    "------" "------------------" "--------" "----------" "--------" "--------" "--------" "--------" "----------" "----------"

  for entry in "${MAB_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-1h-mab-s${S}-${NAME}-kcap"

    local -a execs_vals=() zero_pct_vals=() sat_pct_vals=() arms_vals=() cov_vals=() evict_vals=() anom_vals=()
    local rep_count=0 mab_rounds_sum=0 crashes_sum=0

    for i in $(seq 1 "$RUNS"); do
      local REP_DIR="${RESULTS_DIR}/${OUTDIR}_${i}"
      local statsfile="${REP_DIR}/fuzzer_stats"
      local rewardfile="${REP_DIR}/mab_reward_log"
      local mabstats="${REP_DIR}/mab_stats"
      local mapfile="${REP_DIR}/mab_seed_map"

      [ -f "$statsfile" ] || continue
      rep_count=$((rep_count + 1))

      local e r z s zp sp cr kcap arms cov evict evict_n anom anom_n
      e=$(grep "^execs_done" "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')
      cr=$(grep "^unique_crashes" "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')
      r=$(tail -n +2 "$rewardfile" 2>/dev/null | wc -l)
      z=$(tail -n +2 "$rewardfile" 2>/dev/null | awk -F',' '$6+0==0 {c++} END{print c+0}')
      s=$(tail -n +2 "$rewardfile" 2>/dev/null | awk -F',' '$6+0>=1.0 {c++} END{print c+0}')
      if [ "${r:-0}" -gt 0 ]; then
        zp=$(awk -v z="${z:-0}" -v n="${r:-1}" 'BEGIN{printf "%.1f", (z/n)*100}')
        sp=$(awk -v s="${s:-0}" -v n="${r:-1}" 'BEGIN{printf "%.1f", (s/n)*100}')
      else
        zp="0.0"
        sp="0.0"
      fi

      kcap=$(kcap_stats "$mabstats" 2>/dev/null) || kcap=""
      arms=$(echo "$kcap" | grep -oP 'arms=\K[0-9]+' 2>/dev/null || echo "0")
      cov=$(echo "$kcap" | grep -oP 'cov=\K[0-9.]+' 2>/dev/null || echo "0.000")
      [ -z "$arms" ] && arms="0"
      [ -z "$cov" ] && cov="0.000"

      evict=$(eviction_count "$mapfile" 2>/dev/null) || evict=""
      evict_n=$(echo "$evict" | grep -oP 'evictions=\K[0-9]+' 2>/dev/null || echo "0")
      [ -z "$evict_n" ] && evict_n="0"

      anom=$(reward_anomaly_count "$rewardfile" 2>/dev/null) || anom=""
      anom_n=$(echo "$anom" | grep -oP 'anomalies=\K[0-9]+' 2>/dev/null || echo "0")
      [ -z "$anom_n" ] && anom_n="0"

      execs_vals+=("${e:-0}")
      zero_pct_vals+=("${zp:-0}")
      sat_pct_vals+=("${sp:-0}")
      arms_vals+=("${arms}")
      cov_vals+=("${cov}")
      evict_vals+=("${evict_n}")
      anom_vals+=("${anom_n}")
      mab_rounds_sum=$((mab_rounds_sum + ${r:-0}))
      crashes_sum=$((crashes_sum + ${cr:-0}))
    done

    if [ "$rep_count" -eq 0 ]; then
      printf "%-6s %-18s %10s %12s %10s %10s %8s %8s %10s %10s\n" \
        "s${S}" "$NAME" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
      continue
    fi

    local execs_stat zero_pct_stat sat_pct_stat arms_stat cov_stat evict_stat anom_stat mab_rounds_mean
    execs_stat=$(printf '%s\n' "${execs_vals[@]}" \
      | awk '{sum+=$1;n++} END{printf "%d", int(sum/n)}')
    zero_pct_stat=$(printf '%s\n' "${zero_pct_vals[@]}" \
      | awk '{sum+=$1;n++} END{printf "%.1f", sum/n}')
    sat_pct_stat=$(printf '%s\n' "${sat_pct_vals[@]}" \
      | awk '{sum+=$1;n++} END{printf "%.1f", sum/n}')
    arms_stat=$(printf '%s\n' "${arms_vals[@]}" \
      | awk '{sum+=$1;n++} END{printf "%d", int(sum/n)}')
    cov_stat=$(printf '%s\n' "${cov_vals[@]}" \
      | awk '{sum+=$1;n++} END{printf "%.3f", sum/n}')
    evict_stat=$(printf '%s\n' "${evict_vals[@]}" \
      | awk '{sum+=$1;n++} END{printf "%d", int(sum/n)}')
    anom_stat=$(printf '%s\n' "${anom_vals[@]}" \
      | awk '{sum+=$1;n++} END{printf "%d", int(sum/n)}')
    mab_rounds_mean=$((mab_rounds_sum / rep_count))

    printf "%-6s %-18s %10s %12s %10s %10s %8s %8s %10s %10s\n" \
      "s${S}" "$NAME" "$execs_stat" "$mab_rounds_mean" "${zero_pct_stat}%" "${sat_pct_stat}%" "$arms_stat" "$cov_stat" "$evict_stat" "$anom_stat"

    log "  ${NAME}: total crashes across ${rep_count} reps = ${crashes_sum}"
  done
  log ""
  log "  zero_pct/sat_pct: mean %% of rounds with reward==0 / reward>=1.0 (sanity check only)."
  log "  arms: mean state-0 arm count (should be <= ${MAX_SEEDS_PER_STATE}; ~${MAX_SEEDS_PER_STATE} means cap is binding)."
  log "  cov: coefficient of variation of cumul_reward/pull_count in state 0"
  log "    (arm discriminability — higher means arms are more distinguishable)."
  log "  evictions: mean count of duplicate arm_idx reuse in state 0's seed map"
  log "    (0 means the cap never fired for that algorithm/rep)."
  log "  anomalies: mean count of zero/negative/non-numeric reward rows"
  log "    (coarse proxy only — not time-correlated with evictions)."
  log "  mab_rounds: expect ~52 rounds/state/hour if K-cap overhead is negligible."
  log "=== Summary done ==="
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  log "======================================================================"
  log "1h Pilot: EXP3/EXP3-IX/SLEEPING_BANDIT/SLEEPING_BANDIT_IX/UCB1/THOMPSON — K-cap"
  log "======================================================================"
  log "Algorithms (sequential): ${MAB_ALGOS[*]}"
  log "Reps per algorithm (parallel): $RUNS"
  log "Testing: mab_cap_seeds() — caps each state's seed/arm pool at"
  log "MAX_SEEDS_PER_STATE (${MAX_SEEDS_PER_STATE}), evicting the lowest-"
  log "performing arm (never the one in flight this round)."
  log "Checks: no crashes; state 0 arm count caps at ${MAX_SEEDS_PER_STATE};"
  log "evictions occur (duplicate arm_idx in mab_seed_map); round rate"
  log "roughly unaffected; arm discriminability (cov) reasonable; no obvious"
  log "reward-log anomalies."
  log "======================================================================"
  echo ""

  preflight
  check_disk "execution start"
  run_all_algos_sequentially
  extract_remaining
  verify_mab_outputs
  print_summary

  log "======================================================================"
  log "1h K-cap Pilot COMPLETE"
  log "======================================================================"
  log "Results: $RESULTS_DIR"
  log "Log file: $LOG_FILE"
  log ""
}

main "$@"
