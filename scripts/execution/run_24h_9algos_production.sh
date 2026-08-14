#!/bin/bash
# run_24h_9algos_production.sh — 24-hour production run, all 9 seed-
#                                 selection algorithms, 10 reps in
#                                 parallel per algorithm, algorithms run
#                                 sequentially in a fixed priority order.
#
# Order (fixed, do not reorder without updating the accompanying plan
# doc .opencode/plans/9x24h-production-run-schedule.md):
#   1. s4 EXP3                — core MAB, must finish before user departs
#   2. s5 EXP3-IX              — core MAB
#   3. s6 SLEEPING_BANDIT      — core MAB
#   4. s7 SLEEPING_BANDIT_IX   — core MAB
#   5. s8 UCB1                 — opportunistic MAB
#   6. s9 THOMPSON_SAMPLING    — opportunistic MAB
#   7. s1 RANDOM               — non-MAB baseline
#   8. s2 ROUND-ROBIN          — non-MAB baseline
#   9. s3 FAVOR                — non-MAB baseline (least important; last
#                                 on purpose so fresh data is waiting when
#                                 the user returns from a multi-day trip)
# 10 reps per algorithm, ~24h per algorithm -> ~216h (9 days) total wall
# time, run fully unattended.
#
# This extends run_1h_kcap_pilot.sh with four additional robustness
# mechanisms needed for a multi-day unattended run (see
# .opencode/plans/9x24h-production-run-schedule.md for full rationale):
#
#   1. Periodic mid-run health checks — the blocking `docker wait` used
#      by the 1h pilot is replaced with a polling loop (every
#      POLL_INTERVAL seconds) that re-checks container liveness for the
#      whole duration of each algorithm's batch, not just once at start.
#
#   2. Bounded auto-restart — if a container dies within
#      EARLY_FAILURE_WINDOW seconds of being launched, it is treated as a
#      startup/transient failure and relaunched once with a fresh full
#      TIMEOUT. Containers that die AFTER EARLY_FAILURE_WINDOW are treated
#      as a terminal failure for that rep and are NOT retried: restarting
#      a rep that failed late (e.g. at hour 20 of 24) would delay that
#      whole algorithm's completion — and therefore every subsequent
#      algorithm in this sequential schedule — by nearly another full
#      TIMEOUT, which is not an acceptable risk to the overall 9-day
#      schedule for the sake of one rep out of ten. Algorithms that lose a
#      rep this way simply end up with <RUNS valid reps; this is surfaced
#      explicitly by verify_mab_outputs() and print_summary(), not
#      silently swallowed.
#
#   3. Continuous (non-fatal) disk monitoring — check_disk_nonfatal() is
#      called on every poll cycle and only warns; it never stops an
#      already-running batch (killing 10 live 24h fuzzing runs to "save"
#      disk space would destroy far more data than it protects). The
#      existing fatal check_disk() still gates the START of each new
#      algorithm's batch.
#
#   4. Persistent run-state file (${RESULTS_DIR}/.run_state.json) —
#      tracks which algorithms have fully completed. If this script is
#      re-invoked (e.g. after a host reboot), it detects the most recent
#      incomplete results directory and resumes at the first algorithm
#      not yet marked complete, skipping ones already done.
#      IMPORTANT CAVEAT: plain `docker run -d` containers with no
#      `--restart` policy and no bind mount do NOT survive a host reboot,
#      and produce no tarball until they finish normally. So resume is
#      only ever algorithm-granular, not mid-batch: worst case, a reboot
#      costs the one algorithm that was in flight at the time (up to one
#      TIMEOUT, ~24-25.5h), not the rest of the 9-day schedule. This
#      script does NOT relaunch itself on boot — if reboot-resume should
#      actually trigger automatically, the host OS must be separately
#      configured to re-run this script on startup (e.g. `crontab
#      @reboot`). This is a safety net, not the primary reliability
#      mechanism, and is expected to be unnecessary in normal operation.
#
# Everything else (auto-incrementing results dir, tee'd timestamped log,
# container registry + SIGINT/TERM/HUP cleanup trap, per-rep MAB stats
# parsing, incremental per-algorithm tarball extraction immediately after
# that algorithm's reps finish, output-file verification, aggregated
# summary table) is carried over unchanged from run_1h_kcap_pilot.sh.
#
# Designed to run unsupervised for ~9 days. Output tee'd to a timestamped
# log file. Traps SIGINT/SIGTERM and cleans up live containers before
# exit (does not, and cannot, survive a host power-off/reboot itself —
# see caveat #4 above).
#
# Prerequisites:
#   source ~/fuzz/profuzzbench/fuzz-env.sh
#   bash run_24h_9algos_production.sh
#
# Required env vars (set by fuzz-env.sh):
#   PFBENCH   — path to profuzzbench repo  (e.g. ~/fuzz/profuzzbench)
#   RESULTS   — path to results root       (e.g. ~/fuzz/results)
#
# Required tools on host:
#   docker, awk, grep, df, jq
#
# Before launching, confirm on the actual fuzzing host:
#   - docker image inspect openssl-mabflnet-kcap   (image already built)
#   - df -h on the results volume                  (plenty of disk)
#   - nproc                                        (8 cores — 10 parallel
#     --cpus=1 containers per algorithm is intentional/expected; matches
#     every prior pilot/production run on this same host, so cross-run
#     comparability is preserved even though absolute throughput per
#     container is somewhat below the 1.0-core cap under contention)
#
# --smoke-test mode:
#   Before committing to the real ~9-day run, exercise the whole
#   orchestration machinery (sequencing, polling loop, auto-restart,
#   disk checks, state file, resume) end-to-end in a few minutes instead
#   of 9 days, using the SAME docker image/options as production (only
#   the timing/scale knobs are shrunk):
#
#     bash run_24h_9algos_production.sh --smoke-test
#
#   Defaults under --smoke-test (each individually overridable — see
#   --help): RUNS=2, TIMEOUT=120s, POLL_INTERVAL=20s,
#   EARLY_FAILURE_WINDOW=40s, CONTAINER_START_WAIT=5s, and only the
#   first 2 entries of ALL_ALGOS are run (override with --smoke-algos).
#
#   Smoke-test runs are written under a distinctly-suffixed results
#   directory (...-SMOKETEST, ...-SMOKETEST-2, ...) and use a separate
#   auto-increment/resume chain from real production runs, so a smoke
#   test can NEVER be mistaken for, resumed into, or interfere with real
#   production data. Run `bash run_24h_9algos_production.sh --help` for
#   the full flag list.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

RUNS=10                               # repetitions per algorithm (parallel)
TIMEOUT=86400                         # 24 hours per run
SKIPCOUNT=5                           # gcovr every 5 seeds
IMAGE="openssl-mabflnet-kcap"
COMMON_OPTS="-P TLS -D 10000 -q 3 -E -K -R -W 100"
MIN_DISK_MB=5120                      # refuse to start a new algo if < 5 GB free
CONTAINER_START_WAIT=15               # seconds before initial liveness check
POLL_INTERVAL=900                     # 15 min — health/disk re-check cadence
EARLY_FAILURE_WINDOW=1800             # 30 min — auto-restart window

# Fixed priority order — see header comment. Do not reorder without
# updating .opencode/plans/9x24h-production-run-schedule.md.
ALL_ALGOS=(
  "4:EXP3"
  "5:EXP3-IX"
  "6:SLEEPING_BANDIT"
  "7:SLEEPING_BANDIT_IX"
  "8:UCB1"
  "9:THOMPSON_SAMPLING"
  "1:RANDOM"
  "2:ROUND-ROBIN"
  "3:FAVOR"
)

MAX_SEEDS_PER_STATE=30                # must match config.h

# ---------------------------------------------------------------------------
# CLI argument parsing — --smoke-test and individual overrides.
#
# Smoke-test mode exercises the full orchestration machinery (sequential
# algorithms, parallel reps, polling loop, health checks, bounded
# auto-restart, non-fatal disk monitoring, state-file resume) in minutes
# instead of days, using the same IMAGE/COMMON_OPTS as production so the
# actual `run mabflnet ...` invocation path is genuinely exercised.
# ---------------------------------------------------------------------------

SMOKE_TEST=0
SMOKE_ALGOS_COUNT=2   # how many entries of ALL_ALGOS to run under --smoke-test

print_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Production mode (default): 9 algorithms x 10 reps x 24h each, sequential.

Options:
  --smoke-test              Shrink RUNS/TIMEOUT/POLL_INTERVAL/
                             EARLY_FAILURE_WINDOW/CONTAINER_START_WAIT to
                             smoke-test defaults and only run the first
                             --smoke-algos algorithms. Writes to a
                             distinctly-suffixed results directory
                             (...-SMOKETEST) that is never shared with,
                             auto-incremented alongside, or resumable
                             into/from real production runs.
  --smoke-algos N            Number of algorithms to run under
                             --smoke-test (default: ${SMOKE_ALGOS_COUNT}).
                             Ignored without --smoke-test.
  --runs N                   Override RUNS (reps per algorithm).
  --timeout SECONDS          Override TIMEOUT (per-run duration).
  --poll-interval SECONDS    Override POLL_INTERVAL (health/disk re-check
                             cadence).
  --early-failure-window S   Override EARLY_FAILURE_WINDOW (auto-restart
                             eligibility window).
  --container-start-wait S   Override CONTAINER_START_WAIT (initial
                             liveness-check delay).
  -h, --help                 Show this help and exit.

Examples:
  # Full end-to-end smoke test (2 algos x 2 reps x 2 min, fast poll/
  # restart windows) — recommended before the real production launch:
  bash $0 --smoke-test

  # Smoke test all 9 algorithms (still fast per-algorithm) instead of
  # just the first 2:
  bash $0 --smoke-test --smoke-algos 9

  # Custom one-off (e.g. re-run just a shorter validation duration at
  # full 10-rep scale, without full smoke-test shrinkage of RUNS):
  bash $0 --timeout 3600 --runs 10
EOF
}

# Track which knobs the user explicitly overrode via CLI, so --smoke-test
# defaults only fill in the ones NOT explicitly set (explicit flags always
# win over smoke-test defaults, even when combined with --smoke-test).
RUNS_EXPLICIT=0
TIMEOUT_EXPLICIT=0
POLL_INTERVAL_EXPLICIT=0
EARLY_FAILURE_WINDOW_EXPLICIT=0
CONTAINER_START_WAIT_EXPLICIT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --smoke-test)
      SMOKE_TEST=1
      shift
      ;;
    --smoke-algos)
      SMOKE_ALGOS_COUNT="$2"
      shift 2
      ;;
    --runs)
      RUNS="$2"
      RUNS_EXPLICIT=1
      shift 2
      ;;
    --timeout)
      TIMEOUT="$2"
      TIMEOUT_EXPLICIT=1
      shift 2
      ;;
    --poll-interval)
      POLL_INTERVAL="$2"
      POLL_INTERVAL_EXPLICIT=1
      shift 2
      ;;
    --early-failure-window)
      EARLY_FAILURE_WINDOW="$2"
      EARLY_FAILURE_WINDOW_EXPLICIT=1
      shift 2
      ;;
    --container-start-wait)
      CONTAINER_START_WAIT="$2"
      CONTAINER_START_WAIT_EXPLICIT=1
      shift 2
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "FATAL: unknown argument: $1" >&2
      print_help
      exit 1
      ;;
  esac
done

RESULTS_DIR_SUFFIX=""
if [ "$SMOKE_TEST" -eq 1 ]; then
  # Smoke-test defaults — only applied to knobs the user did NOT already
  # explicitly override above. (Uses if/then rather than `[ cond ] &&
  # cmd` as a bare statement, since the latter's non-zero exit status
  # when the condition is false would trip `set -e` and abort the whole
  # script.)
  if [ "$RUNS_EXPLICIT" -eq 0 ]; then RUNS=2; fi
  if [ "$TIMEOUT_EXPLICIT" -eq 0 ]; then TIMEOUT=120; fi
  if [ "$POLL_INTERVAL_EXPLICIT" -eq 0 ]; then POLL_INTERVAL=20; fi
  if [ "$EARLY_FAILURE_WINDOW_EXPLICIT" -eq 0 ]; then EARLY_FAILURE_WINDOW=40; fi
  if [ "$CONTAINER_START_WAIT_EXPLICIT" -eq 0 ]; then CONTAINER_START_WAIT=5; fi
  ALL_ALGOS=("${ALL_ALGOS[@]:0:$SMOKE_ALGOS_COUNT}")
  RESULTS_DIR_SUFFIX="-SMOKETEST"
  MIN_DISK_MB=512   # smoke-test footprint is tiny; don't require 5 GB free
fi

command -v jq &>/dev/null || {
  echo "FATAL: jq is required for run-state tracking. Install jq first." >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Results directory — auto-increment, but resume into the most recent
# INCOMPLETE run (one with a .run_state.json whose completed_algos count
# is less than the full algorithm count) instead of always creating a new
# directory. This is what makes host-reboot resume work: a fresh
# invocation of this script will find and continue the interrupted run.
# ---------------------------------------------------------------------------

_base="${RESULTS}/24h-9algos-10runs-production${RESULTS_DIR_SUFFIX}"
_n=1
_candidate="$_base"
RESULTS_DIR=""

while [ -d "$_candidate" ]; do
  _candidate_state="${_candidate}/.run_state.json"
  if [ -f "$_candidate_state" ]; then
    _completed_n=$(jq '.completed_algos | length' "$_candidate_state" 2>/dev/null || echo 0)
    if [ "$_completed_n" -lt "${#ALL_ALGOS[@]}" ]; then
      RESULTS_DIR="$_candidate"
      break
    fi
  fi
  _n=$((_n + 1))
  _candidate="${_base}-${_n}"
done

[ -z "$RESULTS_DIR" ] && RESULTS_DIR="$_candidate"
unset _base _n _candidate _candidate_state _completed_n

STATE_FILE="${RESULTS_DIR}/.run_state.json"
LOG_FILE="${RESULTS_DIR}/run_$(date +%Y%m%d_%H%M%S).log"

# ---------------------------------------------------------------------------
# Logging helper — every echo goes to both stdout and the log file
# ---------------------------------------------------------------------------

mkdir -p "$RESULTS_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2; }
die()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Persistent run-state file (reboot-resume support)
# ---------------------------------------------------------------------------

init_state_file() {
  if [ ! -f "$STATE_FILE" ]; then
    echo '{"phase":"not_started","current_algo":null,"algo_start_epoch":null,"completed_algos":[]}' \
      | jq '.' > "$STATE_FILE"
  fi
}

write_state() {
  # Usage: write_state PHASE ALGO_KEY
  local phase="$1" algo_key="$2"
  local tmp="${STATE_FILE}.tmp"
  jq --arg phase "$phase" --arg algo "$algo_key" --argjson ts "$(date +%s)" \
    '.phase = $phase | .current_algo = $algo | .algo_start_epoch = $ts' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

mark_algo_done() {
  local algo_key="$1"
  local tmp="${STATE_FILE}.tmp"
  jq --arg algo "$algo_key" \
    '.completed_algos += [$algo] | .phase = "done" | .current_algo = null' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

is_algo_completed() {
  local algo_key="$1"
  jq -e --arg a "$algo_key" '(.completed_algos // []) | index($a) != null' \
    "$STATE_FILE" >/dev/null 2>&1
}

init_state_file

# ---------------------------------------------------------------------------
# Container registry — track every container we start so we can clean up
# ---------------------------------------------------------------------------

declare -a LIVE_CONTAINERS=()

register_container() { LIVE_CONTAINERS+=("$1"); }

cleanup_containers() {
  if [ ${#LIVE_CONTAINERS[@]} -gt 0 ]; then
    log "Cleaning up ${#LIVE_CONTAINERS[@]} live container(s)..."
    for cid in "${LIVE_CONTAINERS[@]}"; do
      [ -z "$cid" ] && continue
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

  if [ "$SMOKE_TEST" -eq 1 ]; then
    log "  *** SMOKE-TEST MODE *** (results dir suffixed '${RESULTS_DIR_SUFFIX}',"
    log "  fully separate from and never resumable into real production runs)"
  fi

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

  # Resume status
  local completed_count
  completed_count=$(jq '.completed_algos | length' "$STATE_FILE")
  if [ "$completed_count" -gt 0 ]; then
    log "  RESUMING previous run: ${completed_count}/${#ALL_ALGOS[@]} algorithm(s) already completed."
    log "  Completed: $(jq -r '.completed_algos | join(", ")' "$STATE_FILE")"
  else
    log "  Starting fresh run (no algorithms completed yet)."
  fi

  log "  Algorithms:          ${#ALL_ALGOS[@]} (sequential, fixed priority order)"
  log "  Reps per algorithm:  $RUNS (parallel)"
  log "  Timeout per run:     ${TIMEOUT}s (~$((TIMEOUT / 3600))h)"
  log "  Health/disk re-check every: $((POLL_INTERVAL / 60)) min"
  log "  Auto-restart window: $((EARLY_FAILURE_WINDOW / 60)) min (one attempt per rep)"
  log "  Estimated wall time: ~$(( (TIMEOUT * ${#ALL_ALGOS[@]}) / 3600 ))h (${#ALL_ALGOS[@]} algorithms, nominal; real-world runs have historically overrun by up to ~1h35m per 24h batch)"
  log "=== Pre-flight OK ==="
  echo ""
}

# ---------------------------------------------------------------------------
# Disk space guards
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

# Non-fatal — called periodically while a batch is running. Never stops
# already-running containers; only warns, so a live 24h+ batch is never
# killed to "save" disk space.
check_disk_nonfatal() {
  local free_mb
  free_mb=$(df -m "$RESULTS_DIR" | awk 'NR==2 {print $4}')
  if [ "$free_mb" -lt "$MIN_DISK_MB" ]; then
    warn "LOW DISK: only ${free_mb} MB free (threshold ${MIN_DISK_MB} MB). Not stopping running containers; will re-check before starting the next algorithm."
  fi
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
# an eviction.
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
# reward anywhere in the log.
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
# Run RUNS containers for one algorithm in parallel, poll for completion
# (with periodic health/disk checks and bounded auto-restart), then copy
# and immediately extract results.
#
# Usage: run_algo_single S NAME
#
# Tarballs:       ${RESULTS_DIR}/${OUTDIR}_1.tar.gz .. ${OUTDIR}_${RUNS}.tar.gz
# Extracted dirs: ${RESULTS_DIR}/${OUTDIR}_1/       .. ${OUTDIR}_${RUNS}/
# ---------------------------------------------------------------------------

run_algo_single() {
  local S="$1" NAME="$2"
  local OUTDIR="out-24h-mab-s${S}-${NAME}-production"
  local OPTS="${COMMON_OPTS} -s ${S}"
  local ALGO_KEY="${S}:${NAME}"

  log "--- Starting s${S} (${NAME}) — ${RUNS} reps in parallel ---"
  check_disk "s${S} (${NAME})"
  write_state "launching" "$ALGO_KEY"

  local -A rep_cid=()       # rep index -> current container id
  local -A cid_start_ts=()  # container id -> epoch seconds when launched
  local -A cid_restarted=() # container id -> 1 once it has used its one restart

  # Launch all RUNS containers
  local i
  for i in $(seq 1 "$RUNS"); do
    local CID
    CID=$(docker run --cpus=1 -d \
      "$IMAGE" \
      /bin/bash -c \
      "cd /home/ubuntu/experiments && run mabflnet '${OUTDIR}' '${OPTS}' ${TIMEOUT} ${SKIPCOUNT}")
    register_container "$CID"
    rep_cid[$i]="$CID"
    cid_start_ts[$CID]=$(date +%s)
    log "  rep${i} container started: ${CID}"
  done

  # Initial liveness check
  sleep "$CONTAINER_START_WAIT"
  for i in $(seq 1 "$RUNS"); do
    local CID="${rep_cid[$i]}"
    if ! docker inspect --format='{{.State.Running}}' "$CID" 2>/dev/null | grep -q "true"; then
      warn "  rep${i} container ${CID} exited within ${CONTAINER_START_WAIT}s."
      docker logs --tail 30 "$CID" 2>&1 | while IFS= read -r line; do warn "    $line"; done
    else
      log "  rep${i} container ${CID}: running (liveness OK)"
    fi
  done

  write_state "running" "$ALGO_KEY"

  # Poll until all reps have stopped, re-checking health and disk every
  # POLL_INTERVAL seconds, and auto-restarting reps that die early.
  log "  Waiting for all ${RUNS} reps to finish (~$((TIMEOUT / 3600))h, polling every $((POLL_INTERVAL / 60)) min)..."
  local pending=$RUNS
  while [ "$pending" -gt 0 ]; do
    sleep "$POLL_INTERVAL"
    check_disk_nonfatal
    pending=0
    for i in $(seq 1 "$RUNS"); do
      local CID="${rep_cid[$i]}"
      [ -z "$CID" ] && continue

      local running
      running=$(docker inspect --format='{{.State.Running}}' "$CID" 2>/dev/null || echo "false")
      if [ "$running" = "true" ]; then
        pending=$((pending + 1))
        continue
      fi

      # Container has stopped (finished normally, crashed, or was removed).
      local start_ts="${cid_start_ts[$CID]:-0}"
      local elapsed=$(( $(date +%s) - start_ts ))

      if [ "$elapsed" -lt "$EARLY_FAILURE_WINDOW" ] && [ -z "${cid_restarted[$CID]:-}" ]; then
        warn "  rep${i}: container ${CID} died after ${elapsed}s (< $((EARLY_FAILURE_WINDOW / 60)) min) — auto-restarting (one attempt)."
        docker logs --tail 30 "$CID" 2>&1 | while IFS= read -r line; do warn "    $line"; done
        docker rm "$CID" >/dev/null 2>&1 || true
        LIVE_CONTAINERS=("${LIVE_CONTAINERS[@]/$CID/}")

        local NEW_CID
        NEW_CID=$(docker run --cpus=1 -d \
          "$IMAGE" \
          /bin/bash -c \
          "cd /home/ubuntu/experiments && run mabflnet '${OUTDIR}' '${OPTS}' ${TIMEOUT} ${SKIPCOUNT}")
        register_container "$NEW_CID"
        rep_cid[$i]="$NEW_CID"
        cid_start_ts[$NEW_CID]=$(date +%s)
        cid_restarted[$NEW_CID]=1
        log "  rep${i}: restarted as container ${NEW_CID}"
        pending=$((pending + 1))
      else
        log "  rep${i}: container ${CID} finished/stopped after ${elapsed}s — treated as complete."
      fi
    done
    log "  Still running: ${pending}/${RUNS}"
  done
  log "  All reps finished (or exhausted their restart budget)."

  write_state "extracting" "$ALGO_KEY"

  # Copy tarballs, extract immediately into _N dirs, print quick stats
  local failed_reps=0
  for i in $(seq 1 "$RUNS"); do
    local CID="${rep_cid[$i]:-}"
    local TARBALL="${RESULTS_DIR}/${OUTDIR}_${i}.tar.gz"
    local REP_DIR="${RESULTS_DIR}/${OUTDIR}_${i}"

    if [ -z "$CID" ]; then
      warn "  rep${i}: no container recorded — marking as failed."
      failed_reps=$((failed_reps + 1))
      continue
    fi

    # Copy (retry up to 3x)
    local attempt copied=0
    for attempt in 1 2 3; do
      if docker cp "${CID}:/home/ubuntu/experiments/${OUTDIR}.tar.gz" "$TARBALL" 2>/dev/null; then
        log "  rep${i}: tarball copied → ${TARBALL}"
        copied=1
        break
      else
        warn "  rep${i}: docker cp attempt ${attempt}/3 failed."
        sleep 5
      fi
    done
    if [ "$copied" -eq 0 ]; then
      warn "  rep${i}: could not copy tarball after 3 attempts — marking as failed."
      failed_reps=$((failed_reps + 1))
    fi

    # Extract; tarball contains ${OUTDIR}/ at top level — rename to ${OUTDIR}_${i}/
    if [ -f "$TARBALL" ]; then
      if [ -d "$REP_DIR" ]; then
        log "  rep${i}: ${REP_DIR} already exists — skipping extraction."
      else
        tar -xzf "$TARBALL" -C "$RESULTS_DIR" \
          && mv "${RESULTS_DIR}/${OUTDIR}" "$REP_DIR" \
          && log "  rep${i}: extracted → ${REP_DIR}" \
          || warn "  rep${i}: extraction/rename failed for ${TARBALL}"
      fi
      [ -d "$REP_DIR" ] && quick_stats "$REP_DIR" "$i"
    fi

    docker rm "$CID" > /dev/null 2>&1 || true
    LIVE_CONTAINERS=("${LIVE_CONTAINERS[@]/$CID/}")
  done

  if [ "$failed_reps" -gt 0 ]; then
    warn "  s${S} (${NAME}): ${failed_reps}/${RUNS} rep(s) failed to produce usable data."
  fi

  mark_algo_done "$ALGO_KEY"
  log "--- s${S} (${NAME}) done ---"
  echo ""
}

# ---------------------------------------------------------------------------
# Run all algorithms sequentially (one at a time, 10 reps in parallel
# within each), skipping any already marked complete in the state file
# (resume support).
# ---------------------------------------------------------------------------

run_all_algos_sequentially() {
  log "====== Running ${#ALL_ALGOS[@]} algorithms sequentially ======"
  local idx=1
  for entry in "${ALL_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    if is_algo_completed "$entry"; then
      log "  [$idx/${#ALL_ALGOS[@]}] Algorithm: s${S} (${NAME}) — already completed, skipping (resume)."
      idx=$((idx + 1))
      continue
    fi
    log "  [$idx/${#ALL_ALGOS[@]}] Algorithm: s${S} (${NAME})"
    run_algo_single "$S" "$NAME"
    idx=$((idx + 1))
  done
  log "====== All ${#ALL_ALGOS[@]} algorithms complete ======"
  echo ""
}

# ---------------------------------------------------------------------------
# Extract any tarballs not yet extracted (fallback — run_algo_single
# extracts immediately, so this is a safety net).
# ---------------------------------------------------------------------------

extract_remaining() {
  log "=== Extracting any remaining tarballs ==="
  local found_any=0

  for entry in "${ALL_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-24h-mab-s${S}-${NAME}-production"

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
# algorithms, and report per-algorithm rep-failure counts.
# ---------------------------------------------------------------------------

verify_mab_outputs() {
  log "=== Verifying MAB output files ==="
  local total_missing=0
  local total_found=0

  for entry in "${ALL_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-24h-mab-s${S}-${NAME}-production"
    local algo_missing_reps=0

    for i in $(seq 1 "$RUNS"); do
      local REP_DIR="${RESULTS_DIR}/${OUTDIR}_${i}"

      if [ -d "$REP_DIR" ]; then
        local rep_ok=1
        for file in mab_stats mab_reward_log mab_seed_map; do
          if [ -f "${REP_DIR}/${file}" ]; then
            total_found=$((total_found + 1))
          else
            warn "  Missing: ${REP_DIR}/${file}"
            total_missing=$((total_missing + 1))
            rep_ok=0
          fi
        done
        [ "$rep_ok" -eq 0 ] && algo_missing_reps=$((algo_missing_reps + 1))
      else
        warn "  Missing directory: ${REP_DIR}"
        total_missing=$((total_missing + 3))
        algo_missing_reps=$((algo_missing_reps + 1))
      fi
    done

    if [ "$algo_missing_reps" -gt 0 ]; then
      warn "  s${S} (${NAME}): ${algo_missing_reps}/${RUNS} rep(s) missing/incomplete."
    else
      log "  s${S} (${NAME}): all ${RUNS} reps present."
    fi
  done

  log "  Found ${total_found} MAB output files, missing ${total_missing}"
  log "=== Verification done ==="
  echo ""
}

# ---------------------------------------------------------------------------
# Print summary table — one row per algorithm, aggregated over RUNS reps.
# ---------------------------------------------------------------------------

print_summary() {
  log "=== Summary (${RUNS} reps per algorithm, 24h production run) ==="
  log ""
  printf "%-6s %-18s %10s %12s %10s %10s %8s %8s %10s %10s\n" \
    "s" "Algorithm" "execs" "mab_rounds" "zero_pct" "sat_pct" "arms" "cov" "evictions" "anomalies"
  printf "%-6s %-18s %10s %12s %10s %10s %8s %8s %10s %10s\n" \
    "------" "------------------" "--------" "----------" "--------" "--------" "--------" "--------" "----------" "----------"

  for entry in "${ALL_ALGOS[@]}"; do
    local S="${entry%%:*}"
    local NAME="${entry##*:}"
    local OUTDIR="out-24h-mab-s${S}-${NAME}-production"

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

    log "  ${NAME}: total crashes across ${rep_count} reps = ${crashes_sum} (${rep_count}/${RUNS} reps present)"
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
  log "  Reps present may be < ${RUNS} if a rep crashed after the"
  log "  ${EARLY_FAILURE_WINDOW}s auto-restart window and was not retried"
  log "  (see script header for rationale)."
  log "=== Summary done ==="
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  log "======================================================================"
  if [ "$SMOKE_TEST" -eq 1 ]; then
    log "SMOKE TEST: ${#ALL_ALGOS[@]} algorithm(s) x ${RUNS} reps — sequential"
    log "(shrunk timing knobs; NOT a production run — results dir suffixed"
    log "'${RESULTS_DIR_SUFFIX}', kept fully separate from production data)"
  else
    log "24h Production Run: 9 algorithms x 10 reps — sequential"
  fi
  log "======================================================================"
  log "Order: ${ALL_ALGOS[*]}"
  log "Reps per algorithm (parallel): $RUNS"
  log "Timeout per algorithm: ${TIMEOUT}s"
  log "Robustness: periodic health checks every $((POLL_INTERVAL / 60)) min,"
  log "bounded auto-restart (< $((EARLY_FAILURE_WINDOW / 60)) min elapsed, one"
  log "attempt per rep), continuous non-fatal disk monitoring, persistent"
  log "run-state file for algorithm-granular resume after interruption."
  log "======================================================================"
  echo ""

  preflight
  check_disk "execution start"
  run_all_algos_sequentially
  extract_remaining
  verify_mab_outputs
  print_summary

  log "======================================================================"
  if [ "$SMOKE_TEST" -eq 1 ]; then
    log "SMOKE TEST COMPLETE"
    log "If everything above looks correct (sequencing, extraction, summary),"
    log "the orchestration logic is validated. Proceed with the real"
    log "production run: bash $0"
  else
    log "24h 9-Algorithm Production Run COMPLETE"
  fi
  log "======================================================================"
  log "Results: $RESULTS_DIR"
  log "Log file: $LOG_FILE"
  log ""
}

main "$@"
