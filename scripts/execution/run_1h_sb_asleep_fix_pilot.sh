#!/bin/bash
# run_1h_sb_asleep_fix_pilot.sh — 1-hour pilot, SLEEPING_BANDIT and
#                                  SLEEPING_BANDIT_IX only, 10 reps in
#                                  parallel per algorithm, algorithms run
#                                  sequentially.
#
# Validates: mab_seed_asleep(), a shared awake/asleep predicate added to
# afl-fuzz.c, replacing the inline check
#   seed_i->was_fuzzed && !seed_i->favored && queue_cycle > 1
# that was previously duplicated across both SLEEPING_BANDIT and
# SLEEPING_BANDIT_IX's draw and reward-update code.
#
# The old inline check let an initial seed's favored bit act as a
# permanent exemption from ever sleeping: cull_queue() only resets
# favored to 0 for non-initial seeds before recomputing bitmap-byte
# ownership (this is original, unmodified AFLNet behaviour), so an
# initial seed's favored bit can go 0->1 but never back to 0. Since the
# initial seed starts out uncontested at t=0, it is favored almost
# immediately and then stays "favored" (and therefore permanently awake)
# for the rest of the run regardless of how redundant it later becomes.
# mab_seed_asleep() special-cases initial seeds to use was_fuzzed &&
# queue_cycle > 1 alone, without depending on a favored bit that cannot
# reflect their actual redundancy.
#
# This pilot is a follow-up to 1h-ix-lockin-fix (which validated the
# gamma_ix implicit-exploration floor fix and, via its arm-0 first-mover
# investigation, is where the above sticky-favored issue was found).
# Only the 2 sleeping-bandit algorithms are re-run here since EXP3 and
# EXP3-IX don't use the awake/asleep concept at all and are structurally
# unaffected by this change.
#
# Layout:
#   Algorithm 1: SLEEPING_BANDIT     (-s 6) — 10 reps in parallel (~1h)
#   Algorithm 2: SLEEPING_BANDIT_IX  (-s 7) — 10 reps in parallel (~1h)
#
# Algorithms run ONE AT A TIME (sequentially) — total wall time ~2h.
# Within each algorithm, all 10 reps run concurrently (~1h each).
#
# Expected outcome: SLEEPING_BANDIT_IX's top-arm pull share (top_pct)
# and Gini coefficient should drop from the 1h-ix-lockin-fix pilot's
# post-gamma_ix-fix values (top_pct mean 22.6%, gini mean 0.856) toward
# something closer to the non-sleeping EXP3-IX baseline from the same
# pilot (top_pct mean 10.3%, gini mean 0.880), since arm 0 (the initial
# seed) can no longer accumulate a permanently-shrinking-denominator
# advantage as competitors correctly fall asleep around it.
# SLEEPING_BANDIT (non-IX) is expected to change much less, since its
# uniform-mixing floor (gamma/K_active in the draw probability) already
# bounded arm 0's advantage even under the old predicate — this pilot
# re-validates that assumption rather than expecting a large shift.
#
# This script prints, per rep, the same top-arm pull share and Gini
# coefficient metrics used in 1h-ix-lockin-fix so the fix can be judged
# without a separate offline analysis pass — full offline analysis
# should still be run afterward to cross-check, and to compare directly
# against the 1h-ix-lockin-fix pilot's post-fix SB-EXP3-IX numbers.
#
# Phase 1 (sequential per algorithm, parallel within):
#   For each of the 2 sleeping-bandit algorithms: launch 10 containers,
#   wait, copy, extract, print quick stats + lock-in stats, then move to
#   the next algorithm.
#
# Phase 2 (post-processing):
#   Extract any remaining tarballs, print a full summary table (including
#   the top-arm-pull-share and Gini columns), verify MAB outputs.
#
# Designed to run unsupervised. All output is tee'd to a timestamped log file.
# The script traps SIGINT/SIGTERM and cleans up any live containers before exit.
#
# Prerequisites:
#   source ~/fuzz/profuzzbench/fuzz-env.sh
#   bash run_1h_sb_asleep_fix_pilot.sh
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
IMAGE="openssl-mabflnet"
COMMON_OPTS="-P TLS -D 10000 -q 3 -E -K -R -W 100"
MIN_DISK_MB=5120                      # refuse to start if < 5 GB free (10 x ~500MB per algo)
CONTAINER_START_WAIT=15               # seconds before liveness check

# Auto-increment results directory: 1h-sb-asleep-fix, -2, -3, ...
_base="${RESULTS}/1h-sb-asleep-fix"
if [ ! -d "$_base" ]; then
  RESULTS_DIR="$_base"
else
  _n=2
  while [ -d "${_base}-${_n}" ]; do _n=$((_n + 1)); done
  RESULTS_DIR="${_base}-${_n}"
fi
unset _base _n
LOG_FILE="${RESULTS_DIR}/run_$(date +%Y%m%d_%H%M%S).log"

# Only the 2 sleeping-bandit algorithms, run sequentially in this order
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
    || die "Docker image '$IMAGE' not found. Build it first (must include mab_seed_asleep() in afl-fuzz.c)."
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
# Compute, for one extracted rep directory's mab_stats file, the top-arm
# pull share and Gini coefficient of pull_count across arms in state 0
# (the state/metric used to originally detect the lock-in bug and its
# residual arm-0 first-mover effect in the 1h-ix-lockin-fix pilot).
#
# mab_stats format (after an 8-line header block + 1 blank line + 1
# column-header comment line):
#   state_id  arm_idx  pull_count  log_weight  cumul_reward  last_selected
#
# Usage: lockin_stats MAB_STATS_FILE
# Prints: "top_pct=<pct> gini=<val> arms_pulled=<n>/<total> max_pulls=<n>"
# ---------------------------------------------------------------------------

lockin_stats() {
  local mabstats="$1"
  if [ ! -f "$mabstats" ]; then
    echo "top_pct=- gini=- arms_pulled=-/- max_pulls=-"
    return
  fi

  awk '
    BEGIN { in_data = 0 }
    /^# state_id/ { in_data = 1; next }
    in_data && NF >= 3 && $1 == 0 { pulls[NR] = $3; total_pulls += $3; n_arms++; if ($3 > 0) n_pulled++ }
    END {
      if (n_arms == 0 || total_pulls == 0) {
        print "top_pct=0.0 gini=0.000 arms_pulled=0/0 max_pulls=0"
        exit
      }
      # Top-arm share
      max_p = 0
      for (k in pulls) if (pulls[k] > max_p) max_p = pulls[k]
      top_pct = (max_p / total_pulls) * 100

      # Gini coefficient over pull_count values (0 = perfectly equal,
      # ~1 = all pulls on one arm). Standard mean-absolute-difference form.
      m = 0
      for (k in pulls) { vals[m] = pulls[k]; m++ }
      abs_sum = 0
      for (i = 0; i < m; i++)
        for (j = 0; j < m; j++) {
          d = vals[i] - vals[j]
          if (d < 0) d = -d
          abs_sum += d
        }
      mean_p = total_pulls / n_arms
      gini = (mean_p > 0) ? (abs_sum / (2 * m * m * mean_p)) : 0

      printf "top_pct=%.1f gini=%.3f arms_pulled=%d/%d max_pulls=%d\n", \
        top_pct, gini, n_pulled, n_arms, max_p
    }
  ' "$mabstats"
}

# ---------------------------------------------------------------------------
# Compute, for one extracted rep directory's mab_stats file, whether arm 0
# (the initial seed, state 0) is still the single most-pulled arm — the
# specific pattern this fix targets (arm 0 winning via a shrinking-awake-
# set advantage rather than legitimate reward).
#
# Usage: arm0_check MAB_STATS_FILE
# Prints: "arm0_is_top=<yes|no> arm0_pulls=<n>"
# ---------------------------------------------------------------------------

arm0_check() {
  local mabstats="$1"
  if [ ! -f "$mabstats" ]; then
    echo "arm0_is_top=? arm0_pulls=?"
    return
  fi

  awk '
    BEGIN { in_data = 0 }
    /^# state_id/ { in_data = 1; next }
    in_data && NF >= 3 && $1 == 0 {
      pulls[$2] = $3
      if ($3 > max_p) { max_p = $3; max_idx = $2 }
      if ($2 == 0) arm0_pulls = $3
    }
    END {
      is_top = (max_idx == 0 && max_p > 0) ? "yes" : "no"
      printf "arm0_is_top=%s arm0_pulls=%d\n", is_top, arm0_pulls + 0
    }
  ' "$mabstats"
}

# ---------------------------------------------------------------------------
# Print a quick per-rep stats line for one extracted rep directory.
# Reports the zero-reward rate and saturation rate (reward composition,
# unaffected by this fix — carried over as a sanity check) AND the
# arm-lock-in stats plus the arm-0-specific check (the thing this pilot
# specifically validates).
# Usage: quick_stats REP_DIR REP_INDEX
# ---------------------------------------------------------------------------

quick_stats() {
  local dir="$1" rep="$2"
  local statsfile="${dir}/fuzzer_stats"
  local mabfile="${dir}/mab_reward_log"
  local mabstats="${dir}/mab_stats"

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

  local lockin arm0
  lockin=$(lockin_stats "$mabstats" 2>/dev/null) \
    || lockin="top_pct=? gini=? arms_pulled=?/? max_pulls=?"
  arm0=$(arm0_check "$mabstats" 2>/dev/null) \
    || arm0="arm0_is_top=? arm0_pulls=?"

  log "    rep${rep}: execs=${execs} paths=${paths} crashes=${crashes} mab_rounds=${mab_rounds} zero_reward=(${zero_pct}%) saturated=(${sat_pct}%) state0[${lockin}] ${arm0}"
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
  local OUTDIR="out-1h-mab-s${S}-${NAME}-sb-asleep-fix"
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
# Run both sleeping-bandit algorithms sequentially (one at a time, 10 reps
# in parallel within each).
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
    local OUTDIR="out-1h-mab-s${S}-${NAME}-sb-asleep-fix"

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
# Verify mab_reward_log, mab_stats for all reps of all algorithms
# ---------------------------------------------------------------------------

verify_mab_outputs() {
  log "=== Verifying MAB output files ==="
  local missing=0
  local found=0

  for entry in "${MAB_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-1h-mab-s${S}-${NAME}-sb-asleep-fix"

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
      else
        warn "  Missing directory: ${REP_DIR}"
        missing=$((missing + 2))
      fi
    done
  done

  log "  Found ${found} MAB output files, missing ${missing}"
  log "=== Verification done ==="
  echo ""
}

# ---------------------------------------------------------------------------
# Print summary table — one row per algorithm, aggregated over RUNS reps.
# Includes top-arm-pull-share and Gini coefficient (the lock-in metrics
# this pilot cross-checks against 1h-ix-lockin-fix), plus the arm-0-is-top
# rate (how many reps still have arm 0 as the single most-pulled arm —
# the specific pattern this fix targets), plus zero/saturation rate
# carried over as a sanity check that the reward computation itself
# wasn't disturbed.
# ---------------------------------------------------------------------------

print_summary() {
  log "=== Summary (${RUNS} reps per algorithm, sleeping-bandit asleep-predicate fix) ==="
  log ""
  printf "%-6s %-12s %10s %12s %10s %10s %10s %10s %10s %12s\n" \
    "s" "Algorithm" "execs" "mab_rounds" "zero_pct" "sat_pct" "top_pct" "gini" "max_pulls" "arm0_top_pct"
  printf "%-6s %-12s %10s %12s %10s %10s %10s %10s %10s %12s\n" \
    "------" "------------" "--------" "----------" "--------" "--------" "--------" "--------" "--------" "------------"

  for entry in "${MAB_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-1h-mab-s${S}-${NAME}-sb-asleep-fix"

    local -a execs_vals=() zero_pct_vals=() sat_pct_vals=() top_pct_vals=() gini_vals=() max_pulls_vals=() arm0_top_vals=()
    local rep_count=0 mab_rounds_sum=0

    for i in $(seq 1 "$RUNS"); do
      local REP_DIR="${RESULTS_DIR}/${OUTDIR}_${i}"
      local statsfile="${REP_DIR}/fuzzer_stats"
      local rewardfile="${REP_DIR}/mab_reward_log"
      local mabstats="${REP_DIR}/mab_stats"

      [ -f "$statsfile" ] || continue
      rep_count=$((rep_count + 1))

      local e r z s zp sp lockin top_pct gini max_pulls arm0 arm0_is_top arm0_top_val
      e=$(grep "^execs_done" "$statsfile" | awk -F': ' '{print $2}' | tr -d ' ')
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

      lockin=$(lockin_stats "$mabstats" 2>/dev/null) || lockin=""
      top_pct=$(echo "$lockin" | grep -oP 'top_pct=\K[0-9.]+' 2>/dev/null || echo "0.0")
      gini=$(echo "$lockin" | grep -oP 'gini=\K[0-9.]+' 2>/dev/null || echo "0.000")
      max_pulls=$(echo "$lockin" | grep -oP 'max_pulls=\K[0-9]+' 2>/dev/null || echo "0")
      [ -z "$top_pct" ] && top_pct="0.0"
      [ -z "$gini" ] && gini="0.000"
      [ -z "$max_pulls" ] && max_pulls="0"

      arm0=$(arm0_check "$mabstats" 2>/dev/null) || arm0=""
      arm0_is_top=$(echo "$arm0" | grep -oP 'arm0_is_top=\K[a-z]+' 2>/dev/null || echo "no")
      arm0_top_val=0
      [ "$arm0_is_top" = "yes" ] && arm0_top_val=100

      execs_vals+=("${e:-0}")
      zero_pct_vals+=("${zp:-0}")
      sat_pct_vals+=("${sp:-0}")
      top_pct_vals+=("${top_pct:-0}")
      gini_vals+=("${gini:-0}")
      max_pulls_vals+=("${max_pulls:-0}")
      arm0_top_vals+=("${arm0_top_val}")
      mab_rounds_sum=$((mab_rounds_sum + ${r:-0}))
    done

    if [ "$rep_count" -eq 0 ]; then
      printf "%-6s %-12s %10s %12s %10s %10s %10s %10s %10s %12s\n" \
        "s${S}" "$NAME" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
      continue
    fi

    local execs_stat zero_pct_stat sat_pct_stat top_pct_stat gini_stat max_pulls_stat mab_rounds_mean arm0_top_stat
    execs_stat=$(printf '%s\n' "${execs_vals[@]}" \
      | awk '{sum+=$1;n++} END{printf "%d", int(sum/n)}')
    zero_pct_stat=$(printf '%s\n' "${zero_pct_vals[@]}" \
      | awk '{sum+=$1;n++} END{printf "%.1f", sum/n}')
    sat_pct_stat=$(printf '%s\n' "${sat_pct_vals[@]}" \
      | awk '{sum+=$1;n++} END{printf "%.1f", sum/n}')
    top_pct_stat=$(printf '%s\n' "${top_pct_vals[@]}" \
      | awk '{sum+=$1;n++} END{printf "%.1f", sum/n}')
    gini_stat=$(printf '%s\n' "${gini_vals[@]}" \
      | awk '{sum+=$1;n++} END{printf "%.3f", sum/n}')
    max_pulls_stat=$(printf '%s\n' "${max_pulls_vals[@]}" \
      | awk '{sum+=$1;n++} END{printf "%d", int(sum/n)}')
    arm0_top_stat=$(printf '%s\n' "${arm0_top_vals[@]}" \
      | awk '{sum+=$1;n++} END{printf "%.0f", sum/n}')
    mab_rounds_mean=$((mab_rounds_sum / rep_count))

    printf "%-6s %-12s %10s %12s %10s %10s %10s %10s %10s %11s%%\n" \
      "s${S}" "$NAME" "$execs_stat" "$mab_rounds_mean" "${zero_pct_stat}%" "${sat_pct_stat}%" "${top_pct_stat}%" "$gini_stat" "$max_pulls_stat" "$arm0_top_stat"
  done
  log ""
  log "  zero_pct/sat_pct: mean %% of rounds with reward==0 / reward>=1.0"
  log "    (unaffected by the asleep-predicate fix — sanity check only)"
  log "  top_pct:   mean %% of state 0's pulls captured by its single most-"
  log "    pulled arm. For SB-EXP3-IX, compare against the pre-this-fix"
  log "    value from 1h-ix-lockin-fix (mean 22.6%%, range 10.9-38.7%%) and"
  log "    against that same pilot's non-sleeping EXP3-IX baseline (mean"
  log "    10.3%%) -- this fix should move SB-EXP3-IX noticeably closer to"
  log "    the EXP3-IX number since arm 0 can no longer ride a shrinking"
  log "    awake-set denominator. SLEEPING_BANDIT (non-IX) should barely"
  log "    move, since its uniform-mixing floor already bounded this."
  log "  gini:      mean Gini coefficient of pull_count across state 0's"
  log "    arms (0 = perfectly equal pulls, ~1 = all pulls on one arm)."
  log "  max_pulls: mean pull_count of state 0's single most-pulled arm."
  log "  arm0_top_pct: %% of reps where arm 0 (the initial seed) is state"
  log "    0's single most-pulled arm. This is the specific pattern the"
  log "    fix targets -- should drop for SB-EXP3-IX if the fix works."
  log "=== Summary done ==="
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  log "======================================================================"
  log "1h Pilot: SLEEPING_BANDIT + SLEEPING_BANDIT_IX — Asleep-Predicate Fix"
  log "======================================================================"
  log "Algorithms (sequential): ${MAB_ALGOS[*]}"
  log "Reps per algorithm (parallel): $RUNS"
  log "Testing: mab_seed_asleep(), which special-cases initial seeds in the"
  log "sleeping-bandit awake/asleep predicate. Previously, an initial"
  log "seed's favored bit could go 0->1 but never back to 0 (cull_queue()"
  log "only clears favored for non-initial seeds), so once favored"
  log "(typically immediately, at t=0) it stayed permanently awake for the"
  log "rest of the run regardless of actual redundancy, while genuinely"
  log "redundant non-initial arms correctly fell asleep around it -- a"
  log "shrinking-denominator advantage in the softmax draw with zero"
  log "additional reward required."
  log "Expected: SB-EXP3-IX's top_pct/gini/arm0_top_pct should drop toward"
  log "the non-sleeping EXP3-IX baseline (top_pct mean 10.3%%, from"
  log "1h-ix-lockin-fix) from its pre-this-fix values (top_pct mean 22.6%%)."
  log "SLEEPING_BANDIT (non-IX) is expected to change much less."
  log "======================================================================"
  echo ""

  preflight
  check_disk "execution start"
  run_all_algos_sequentially
  extract_remaining
  verify_mab_outputs
  print_summary

  log "======================================================================"
  log "1h Sleeping-Bandit Asleep-Predicate Fix Pilot COMPLETE"
  log "======================================================================"
  log "Results: $RESULTS_DIR"
  log "Log file: $LOG_FILE"
  log ""
}

main "$@"
