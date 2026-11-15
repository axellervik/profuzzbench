#!/bin/bash
# run_24h_7algos_production.sh — production run of the selected seed-
#                                 selection algorithms (default: all 7),
#                                 10 reps in parallel per algorithm,
#                                 algorithms run sequentially in a fixed
#                                 priority order.
#
# Order (fixed):
#   1. s4 EXP3                — core MAB, must finish before user departs
#   2. s5 EXP3-IX              — core MAB
#   3. s6 UCB1                 — opportunistic MAB
#   4. s7 THOMPSON_SAMPLING    — opportunistic MAB
#   5. s1 RANDOM               — non-MAB baseline
#   6. s2 ROUND-ROBIN          — non-MAB baseline
#   7. s3 FAVOR                — non-MAB baseline (least important; last
#                                 on purpose so fresh data is waiting when
#                                 the user returns from a multi-day trip)
# 10 reps per algorithm by default (~24h each); total wall time scales
# with the number of algorithms selected (all 7 -> ~168h / 7 days), run
# fully unattended.
#
# This extends run_1h_kcap_pilot.sh with four additional robustness
# mechanisms needed for a multi-day unattended run:
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
#      TIMEOUT, which is not an acceptable risk to the overall 7-day
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
#      TIMEOUT, ~24-25.5h), not the rest of the 7-day schedule. This
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
# Designed to run unsupervised for ~7 days. Output tee'd to a timestamped
# log file. Traps SIGINT/SIGTERM and cleans up live containers before
# exit (does not, and cannot, survive a host power-off/reboot itself —
# see caveat #4 above).
#
# Prerequisites:
#   source ~/fuzz/profuzzbench/fuzz-env.sh
#   bash run_24h_7algos_production.sh
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
#   Before committing to the real ~7-day run, exercise the whole
#   orchestration machinery (sequencing, polling loop, auto-restart,
#   disk checks, state file, resume) end-to-end in a few minutes instead
#   of 7 days, using the SAME docker image/options as production (only
#   the timing/scale knobs are shrunk):
#
#     bash run_24h_7algos_production.sh --smoke-test
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
#   production data. Run `bash run_24h_7algos_production.sh --help` for
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

# Fixed priority order — see header comment.
ALL_ALGOS=(
  "4:EXP3"
  "5:EXP3-IX"
  "6:UCB1"
  "7:THOMPSON_SAMPLING"
  "1:RANDOM"
  "2:ROUND-ROBIN"
  "3:FAVOR"
)

MAX_SEEDS_PER_STATE=30                # must match config.h
COV_FROZEN_RATIO=1.5                  # l_abs last/first below this = frozen (verify_coverage_outputs)
COV_SCRIPT_TMP=""                     # temp dir for the embedded coverage script (set in run_coverage_phase)

# ---------------------------------------------------------------------------
# Embedded per-container coverage measurement script (was
# coverage_regen/robust_cov_script.sh). Written to a temp dir at runtime and
# bind-mounted into each coverage container. Quoted heredoc (<<'ROBUST_COV_EOF')
# so nothing expands at embed time and `set -m` (the job-control fix) is
# preserved in position.
# ---------------------------------------------------------------------------
read -r -d '' EMBEDDED_ROBUST_COV <<'ROBUST_COV_EOF' || true
#!/bin/bash
# robust_cov_script.sh
#
# Drop-in replacement for profuzzbench's subjects/TLS/OpenSSL/cov_script.sh.
#
# WHY THIS EXISTS:
# The stock cov_script.sh silently redirects both the replayer's and the
# s_server's stdout/stderr to /dev/null ("> /dev/null 2>&1"). If a single
# iteration fails (e.g. s_server can't rebind port 4433 because the
# previous instance hasn't released it yet, or aflnet-replay can't connect
# in time), NOTHING in the original script detects or reports this. Because
# gcov counters (.gcda files) are cumulative across process invocations,
# a single silent failure part-way through a long replay (800+ queue files)
# causes ALL subsequent gcovr coverage samples to freeze at whatever value
# was reached right before the failure -- while the loop keeps running
# and backfilling plausible-looking (but stale) Time values for every
# remaining row. This produces exactly the "steep climb then dead flat"
# cov_over_time.csv pattern observed in the 24h-9algos-10runs-production
# results, even though AFL's own live fuzzer_stats shows real, continued
# coverage growth (bitmap_cvg, paths_total) throughout the full 24h run.
#
# This script:
#   1. Verifies the target port is free before each s_server launch
#      (waits/retries instead of racing into a bind failure).
#   2. Captures the replayer's exit code and stderr per file instead of
#      discarding them.
#   3. Retries a failed replay once after a short cooldown -- if the
#      retry also fails, the file/iteration is logged as a genuine
#      replay failure (recorded in the debug log AND flagged inline in
#      the CSV via an extra "replay_ok" column) rather than silently
#      corrupting all later rows.
#   4. Emits the exact same 5-column CSV header the original script used
#      (Time,l_per,l_abs,b_per,b_abs) PLUS a 6th column "replay_ok" so
#      existing/older plotting scripts that only read the first 5 columns
#      keep working unmodified, while new tooling can see exactly which
#      rows are trustworthy.
#
# USAGE (identical positional args to the original cov_script.sh):
#   ./robust_cov_script.sh <folder> <port> <skipcount> <covfile> <fmode> [debuglog]
#
#   folder    fuzzer result folder (contains queue/ or replayable-queue/)
#   port      server's network port (e.g. 4433)
#   skipcount run gcovr after every N test cases
#   covfile   path to output coverage CSV
#   fmode     0 = concatenated (afl-replay/queue), 1 = structured (aflnet-replay/replayable-queue)
#   debuglog  optional path for detailed per-file replay log (default: <covfile>.debug.log)
#
# Must be run from the openssl-gcov build directory (same requirement as
# the original script), with aflnet-replay/afl-replay and openssl s_server
# on PATH / available relative to cwd, exactly as the original run.sh does.
#
# CRITICAL FIX (confirmed via controlled A/B test, fresh containers,
# 2026-08-26): bash disables job control (monitor mode) by default when a
# script is executed as a file, even from an interactive parent shell. This
# script backgrounds the replayer ($replayer ... &) and runs the server in
# the foreground. Without job control, the backgrounded replayer's process
# group / signal handling breaks down in a way that silently prevents the
# TLS handshake from completing -- gcov's .gcda counters then never advance,
# producing a permanent 0 (or frozen-at-whatever-value) coverage reading,
# even though the exact same commands typed one-by-one at an interactive
# prompt work perfectly. `set -m` forces job control on regardless of how
# the script is invoked, which fixes this. Confirmed with a clean fresh-
# container A/B: identical 8-file replay subset, identical everything else,
# WITHOUT set -m => flat 0,0,0,0,0,0 for all 6 sampled rows; WITH set -m =>
# real climbing coverage (18985 -> 19589 lines) across the same 6 rows.
# This is unrelated to Docker's -i/-t flags, CRLF line endings, or which
# aflnet-replay binary is used -- all of those were ruled out first.
set -m
set -u

folder=$1
pno=$2
step=$3
covfile=$4
fmode=$5
debuglog=${6:-"${covfile}.debug.log"}

PORT_WAIT_TIMEOUT_S=5     # max seconds to wait for the port to become free
PORT_POLL_INTERVAL_S=0.2
REPLAY_RETRY_COOLDOWN_S=1
SERVER_TIMEOUT_S=3        # matches original script's "timeout -k 0 3s"

rm -f "$covfile"; touch "$covfile"
: > "$debuglog"

# CRITICAL: Explicitly delete .gcda files before resetting gcov counters.
# `gcovr -r . -s -d` only tells gcov to reinitialize, but doesn't actually
# delete stale .gcda data from prior runs -- old coverage can linger and
# prevent new coverage from accumulating. This is especially important here
# since we might be replaying against a different binary environment than
# the original fuzzing run used.
# NOTE: DO NOT delete .gcno files -- those are the instrumentation metadata
# that gcovr needs to measure coverage. Deleting them breaks instrumentation.
find . -name "*.gcda" -type f -delete 2>/dev/null || true
gcovr -r . -s -d > /dev/null 2>&1

echo "Time,l_per,l_abs,b_per,b_abs,replay_ok" >> "$covfile"

if [ "$fmode" -eq "1" ]; then
  testdir="replayable-queue"
  # CRITICAL: Use explicit path to mabflnet's replayer, not bare "aflnet-replay".
  # The container has BOTH /home/ubuntu/aflnet/aflnet-replay (original, wrong)
  # and /home/ubuntu/mabflnet/aflnet-replay (correct, K-cap-aware). If we use
  # the bare name, whichever appears first in PATH wins -- and that's aflnet,
  # not mabflnet. Using the wrong replayer causes it to either fail to parse
  # mabflnet-generated queue files correctly or exercise different code paths
  # than intended, resulting in .gcda coverage that never advances.
  replayer="/home/ubuntu/mabflnet/aflnet-replay"
else
  testdir="queue"
  replayer="/home/ubuntu/mabflnet/afl-replay"
fi

log() {
  echo "[$(date '+%H:%M:%S')] $*" >> "$debuglog"
}

port_is_free() {
  # Returns 0 (true) if nothing is listening on $pno right now.
  # Prefer `ss` (iproute2, present on modern Ubuntu); fall back to netstat.
  if command -v ss > /dev/null 2>&1; then
    ! ss -ltn "sport = :$pno" 2>/dev/null | grep -q ":$pno"
  elif command -v netstat > /dev/null 2>&1; then
    ! netstat -ltn 2>/dev/null | grep -q ":$pno "
  else
    return 0  # can't check; assume free rather than deadlock
  fi
}

wait_for_port_free() {
  # Pure-integer implementation (no `bc` dependency -- some minimal
  # container images don't have bc installed, and the old bc-based
  # version silently never timed out in that case, risking a hang).
  local max_iters
  max_iters=$(awk -v t="$PORT_WAIT_TIMEOUT_S" -v p="$PORT_POLL_INTERVAL_S" 'BEGIN{printf "%d", (t/p)+0.9999}' 2>/dev/null)
  [ -z "$max_iters" ] && max_iters=25   # fallback: ~5s at 0.2s/iter
  local i=0
  while ! port_is_free; do
    i=$((i+1))
    if [ "$i" -ge "$max_iters" ]; then
      log "WARNING: port $pno still not free after ~${PORT_WAIT_TIMEOUT_S}s wait, proceeding anyway"
      return 1
    fi
    sleep "$PORT_POLL_INTERVAL_S"
  done
  return 0
}

# Run one replay attempt against one queue file.
# Sets global REPLAY_EXIT to the replayer's exit code.
run_one_replay() {
  local f="$1"
  wait_for_port_free
  "$replayer" "$f" TLS "$pno" 100 > "${debuglog}.replayer_stdout" 2> "${debuglog}.replayer_stderr" &
  local replay_pid=$!
  sleep 1  # Give the replayer time to connect before s_server starts listening
  timeout -k 0 "${SERVER_TIMEOUT_S}s" ./apps/openssl s_server -key key.pem -cert cert.pem -4 -naccept 1 -no_anti_replay \
    > "${debuglog}.server_stdout" 2> "${debuglog}.server_stderr"
  local server_status=$?
  wait "$replay_pid"
  REPLAY_EXIT=$?
  # NOTE: with -naccept 1, s_server exits with status 0 on its own once
  # it has handled one connection. Any nonzero server_status means
  # either (a) `timeout` killed it after SERVER_TIMEOUT_S because it
  # never received a connection (exit 124 -- the exact "replay couldn't
  # connect / port still bound by a stale process" scenario this script
  # exists to detect), or (b) s_server crashed/errored on its own (some
  # other nonzero code). Both are genuine failures -- do NOT special-case
  # 124 as "ok", that would defeat the whole point of this check.
  if [ "$REPLAY_EXIT" != "0" ] || [ "$server_status" != "0" ]; then
    log "REPLAY FAILURE on '$f' (replayer_exit=$REPLAY_EXIT server_exit=$server_status)"
    log "  replayer_stderr: $(cat "${debuglog}.replayer_stderr" 2>/dev/null | tr '\n' ' ')"
    log "  server_stderr:   $(cat "${debuglog}.server_stderr" 2>/dev/null | tr '\n' ' ')"
    return 1
  fi
  return 0
}

replay_with_retry() {
  local f="$1"
  if run_one_replay "$f"; then
    echo 1
    return
  fi
  log "Retrying '$f' once after ${REPLAY_RETRY_COOLDOWN_S}s cooldown..."
  sleep "$REPLAY_RETRY_COOLDOWN_S"
  if run_one_replay "$f"; then
    log "Retry succeeded for '$f'"
    echo 1
    return
  fi
  log "Retry FAILED for '$f' -- this row's coverage snapshot is UNRELIABLE"
  echo 0
}

sample_coverage() {
  local time="$1" ok="$2"
  local cov_data l_per l_abs b_per b_abs
  cov_data=$(gcovr -r . -s | grep "[lb][a-z]*:")
  l_per=$(echo "$cov_data" | grep lines | cut -d" " -f2 | rev | cut -c2- | rev)
  l_abs=$(echo "$cov_data" | grep lines | cut -d" " -f3 | cut -c2-)
  b_per=$(echo "$cov_data" | grep branch | cut -d" " -f2 | rev | cut -c2- | rev)
  b_abs=$(echo "$cov_data" | grep branch | cut -d" " -f3 | cut -c2-)
  echo "$time,$l_per,$l_abs,$b_per,$b_abs,$ok" >> "$covfile"
}

log "=== robust_cov_script starting: folder=$folder port=$pno step=$step fmode=$fmode ==="
n_fail=0
n_total=0

# Process seeds first
for f in $(echo "$folder/$testdir"/*.raw); do
  [ -e "$f" ] || continue
  time=$(stat -c %Y "$f")
  ok=$(replay_with_retry "$f")
  n_total=$((n_total+1))
  [ "$ok" = "0" ] && n_fail=$((n_fail+1))
  sample_coverage "$time" "$ok"
done

# Process other testcases
count=0
last_f=""
for f in $(echo "$folder/$testdir"/id*); do
  [ -e "$f" ] || continue
  last_f="$f"
  time=$(stat -c %Y "$f")
  ok=$(replay_with_retry "$f")
  n_total=$((n_total+1))
  [ "$ok" = "0" ] && n_fail=$((n_fail+1))

  count=$((count+1))
  rem=$((count % step))
  if [ "$rem" != "0" ]; then continue; fi
  sample_coverage "$time" "$ok"
done

# Output cov data for the last testcase(s) if step > 1
if [ "$step" -gt 1 ] && [ -n "$last_f" ]; then
  time=$(stat -c %Y "$last_f")
  sample_coverage "$time" "1"
fi

log "=== robust_cov_script finished: $n_total files replayed, $n_fail failed (even after retry) ==="
echo "robust_cov_script: $n_total files replayed, $n_fail failed (even after retry). See $debuglog for details." >&2
ROBUST_COV_EOF

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
PILOT=0
SMOKE_ALGOS_COUNT=2   # how many entries of ALL_ALGOS to run under --smoke-test

print_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

 Production mode (default): all 7 algorithms x 10 reps x 24h each,
 sequential. Select a subset with --algos, or use --pilot for a fast
 1h-per-algorithm validation run.

Options:
  --algos SPEC             Which algorithms to run. A comma-separated list
                           of names and/or -s numbers (e.g.
                           EXP3,EXP3-IX,UCB1,THOMPSON_SAMPLING,FAVOR or
                           4,5,6,7,3), or a preset: all (default, all 7)
                           or rerun (the 5 re-run set: EXP3, EXP3-IX,
                           UCB1, THOMPSON_SAMPLING, FAVOR). Mutually
                           exclusive with --smoke-test.
  --pilot                  Fast validation run: 1h per algorithm (TIMEOUT=
                           3600) at full 10-rep scale, defaulting to the
                           rerun set (5 algorithms) and writing to a
                           -PILOT results directory. Total ~5h.
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

  # Smoke test all 7 algorithms (still fast per-algorithm) instead of
  # just the first 2:
  bash $0 --smoke-test --smoke-algos 7

  # Fast 1h-per-algorithm validation of the 5 re-run algorithms (~5h):
  bash $0 --pilot

  # Re-run just the 5 MAB/FAVOR algorithms at full 24h scale:
  bash $0 --algos rerun

  # Re-run an explicit subset at full scale:
  bash $0 --algos EXP3,EXP3-IX,UCB1,THOMPSON_SAMPLING

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
ALGOS_CSV=""
ALGOS_EXPLICIT=0

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
    --algos)
      ALGOS_CSV="$2"
      ALGOS_EXPLICIT=1
      shift 2
      ;;
    --pilot)
      PILOT=1
      shift
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

# ---------------------------------------------------------------------------
# --algos / --pilot resolution.
#
# --algos selects a subset of ALL_ALGOS (by name, -s number, or preset).
# --pilot defaults to the 5-algo re-run set when --algos is not given.
# This runs BEFORE the smoke-test block so the smoke-test slice (if any)
# applies to the already-filtered list.
# ---------------------------------------------------------------------------

if [ "$PILOT" -eq 1 ] && [ "$SMOKE_TEST" -eq 1 ]; then
  echo "FATAL: --pilot and --smoke-test are mutually exclusive" >&2
  exit 1
fi

if [ "$PILOT" -eq 1 ] && [ "$ALGOS_EXPLICIT" -eq 0 ]; then
  ALGOS_CSV="rerun"
fi

if [ -n "$ALGOS_CSV" ]; then
  declare -A WANTED=()
  IFS=',' read -ra _algos_tokens <<< "$ALGOS_CSV"
  for _tok in "${_algos_tokens[@]}"; do
    _tok="$(echo "$_tok" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$_tok" ] && continue
    _t="$(echo "$_tok" | tr '[:lower:]' '[:upper:]' | tr -d '_-')"
    if [ "$_t" = "ALL" ]; then
      for _e in "${ALL_ALGOS[@]}"; do WANTED["${_e%%:*}"]=1; done
    elif [ "$_t" = "RERUN" ]; then
      for _s in 4 5 6 7 3; do WANTED[$_s]=1; done
    elif [[ "$_t" =~ ^[0-9]+$ ]]; then
      WANTED[$_t]=1
    else
      _matched=0
      for _e in "${ALL_ALGOS[@]}"; do
        _s="${_e%%:*}"; _name="${_e##*:}"
        _nn="$(echo "$_name" | tr '[:lower:]' '[:upper:]' | tr -d '_-')"
        if [ "$_nn" = "$_t" ]; then WANTED[$_s]=1; _matched=1; break; fi
      done
      if [ "$_matched" -eq 0 ]; then
        echo "FATAL: unknown algorithm '$_tok'. Valid: EXP3, EXP3-IX, UCB1, THOMPSON_SAMPLING, RANDOM, ROUND-ROBIN, FAVOR (or -s numbers 1-7, or 'all'/'rerun')." >&2
        exit 1
      fi
    fi
  done
  _filtered=()
  for _e in "${ALL_ALGOS[@]}"; do
    _s="${_e%%:*}"
    if [ -n "${WANTED[$_s]:-}" ]; then _filtered+=("$_e"); fi
  done
  if [ ${#_filtered[@]} -eq 0 ]; then
    echo "FATAL: --algos resolved to an empty set" >&2
    exit 1
  fi
  ALL_ALGOS=("${_filtered[@]}")
  unset WANTED _algos_tokens _filtered _tok _t _e _s _name _nn _matched
fi

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
  if [ "$ALGOS_EXPLICIT" -eq 0 ]; then ALL_ALGOS=("${ALL_ALGOS[@]:0:$SMOKE_ALGOS_COUNT}"); fi
  RESULTS_DIR_SUFFIX="-SMOKETEST"
  MIN_DISK_MB=512   # smoke-test footprint is tiny; don't require 5 GB free
fi

if [ "$PILOT" -eq 1 ]; then
  if [ "$TIMEOUT_EXPLICIT" -eq 0 ]; then TIMEOUT=3600; fi   # 1 h per rep
  if [ "$RUNS_EXPLICIT" -eq 0 ]; then RUNS=10; fi
  RESULTS_DIR_SUFFIX="-PILOT"
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

_base="${RESULTS}/24h-${#ALL_ALGOS[@]}algos-10runs-production${RESULTS_DIR_SUFFIX}"
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

# Human-readable duration formatter — used instead of naive "/ 60" or
# "/ 3600" so smoke-test-scale values (e.g. 20s, 40s) don't misleadingly
# print as "0 min"/"~0h" in the log. Picks whichever unit best represents
# the value: seconds if < 60, minutes if < 3600, hours otherwise.
# Usage: fmt_duration SECONDS
fmt_duration() {
  local secs="$1"
  if [ "$secs" -lt 60 ]; then
    echo "${secs}s"
  elif [ "$secs" -lt 3600 ]; then
    echo "$((secs / 60))min"
  else
    echo "$((secs / 3600))h"
  fi
}

# ---------------------------------------------------------------------------
# Persistent run-state file (reboot-resume support)
# ---------------------------------------------------------------------------

init_state_file() {
  if [ ! -f "$STATE_FILE" ]; then
    echo '{"phase":"not_started","current_algo":null,"algo_start_epoch":null,"completed_algos":[],"coverage":"pending"}' \
      | jq '.' > "$STATE_FILE"
  fi
  # Backfill "coverage" for state files created before this field existed.
  local tmp="${STATE_FILE}.tmp"
  jq 'if has("coverage") then . else . + {"coverage":"pending"} end' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
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

is_coverage_done() { jq -e '.coverage == "done"' "$STATE_FILE" >/dev/null 2>&1; }
mark_coverage_done() {
  local tmp="${STATE_FILE}.tmp"
  jq '.coverage = "done"' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
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

trap 'log "Caught signal — cleaning up..."; cleanup_containers; rm -rf "${COV_SCRIPT_TMP:-}" 2>/dev/null || true; exit 1' \
  INT TERM HUP

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

preflight() {
  log "=== Pre-flight checks ==="

  if [ "$SMOKE_TEST" -eq 1 ]; then
    log "  *** SMOKE-TEST MODE *** (results dir suffixed '${RESULTS_DIR_SUFFIX}',"
    log "  fully separate from and never resumable into real production runs)"
  elif [ "$PILOT" -eq 1 ]; then
    log "  *** PILOT MODE *** (results dir suffixed '${RESULTS_DIR_SUFFIX}',"
    log "  validation run kept separate from production data)"
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
  log "  Timeout per run:     ${TIMEOUT}s (~$(fmt_duration "$TIMEOUT"))"
  log "  Health/disk re-check every: $(fmt_duration "$POLL_INTERVAL")"
  log "  Auto-restart window: $(fmt_duration "$EARLY_FAILURE_WINDOW") (one attempt per rep)"
  log "  Estimated wall time: ~$(fmt_duration "$(( TIMEOUT * ${#ALL_ALGOS[@]} ))") (${#ALL_ALGOS[@]} algorithms, nominal; real-world runs have historically overrun by up to ~1h35m per 24h batch)"
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
#   state_id  arm_idx  pull_count  log_weight  cumul_reward  exp3ix_r
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

  local -A rep_cid=()        # rep index -> current container id
  local -A cid_start_ts=()   # container id -> epoch seconds when launched
  local -A cid_restarted=()  # container id -> 1 once it has used its one restart
  local -A cid_logged_done=() # container id -> 1 once "finished/stopped" has been logged for it

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
  log "  Waiting for all ${RUNS} reps to finish (~$(fmt_duration "$TIMEOUT"), polling every $(fmt_duration "$POLL_INTERVAL"))..."
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
        warn "  rep${i}: container ${CID} died after ${elapsed}s (< $(fmt_duration "$EARLY_FAILURE_WINDOW")) — auto-restarting (one attempt)."
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
        # Log "finished/stopped" only once per rep — without this guard the
        # container is re-detected as stopped (correctly) on every remaining
        # poll cycle of this algorithm's wait and spams the log/re-runs
        # `docker inspect` for no reason. rep_cid[$i] is intentionally left
        # intact (not cleared) since the extraction step below still needs
        # it to `docker cp` the finished container's tarball.
        if [ -z "${cid_logged_done[$CID]:-}" ]; then
          log "  rep${i}: container ${CID} finished/stopped after ${elapsed}s — treated as complete."
          cid_logged_done[$CID]=1
        fi
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
# Phase 2 — sequential coverage generation (self-contained).
#
# Regenerates cov_over_time_v2.csv for every rep, ONE container at a time
# (sequential is the fix for the coverage-freeze bug — never parallel).
# Idempotent: skips reps that already have a _v2.csv, so a reboot mid-phase
# resumes cleanly. The per-container measurement script is embedded above
# (EMBEDDED_ROBUST_COV) and written to a temp dir to bind-mount.
# ---------------------------------------------------------------------------

run_coverage_orchestrator() {
  local cov_script_tmp="$1"
  local scratch_root="${RESULTS_DIR}/_coverage_regen_scratch"
  mkdir -p "$scratch_root"
  shopt -s nullglob
  local tarballs=("$RESULTS_DIR"/*.tar.gz)
  if [ ${#tarballs[@]} -eq 0 ]; then
    warn "No .tar.gz files found in $RESULTS_DIR — nothing to regenerate."
    return 0
  fi
  log "  Found ${#tarballs[@]} archives to process."
  local tb base out_csv_v2 out_log_v2 work extracted_dir container_name n_files n_fail_line
  for tb in "${tarballs[@]}"; do
    base=$(basename "$tb" .tar.gz)
    out_csv_v2="${RESULTS_DIR}/${base}.cov_over_time_v2.csv"
    out_log_v2="${RESULTS_DIR}/${base}.cov_over_time_v2.debug.log"
    if [ -f "$out_csv_v2" ]; then
      log "  [skip] $base — already has $out_csv_v2"
      continue
    fi
    log "  [process] $base"
    work="$scratch_root/$base"
    rm -rf "$work"
    mkdir -p "$work"
    if ! tar -xzf "$tb" -C "$work"; then
      warn "  ERROR: corrupt/unreadable tarball $tb, skipping"
      continue
    fi
    extracted_dir=$(find "$work" -maxdepth 1 -mindepth 1 -type d | head -n1)
    if [ -z "$extracted_dir" ]; then
      warn "  ERROR: could not find extracted OUTDIR inside $tb, skipping"
      continue
    fi
    if [ ! -d "$extracted_dir/replayable-queue" ]; then
      warn "  ERROR: $extracted_dir has no replayable-queue/, skipping"
      continue
    fi
    chmod -R a+rwX "$extracted_dir"
    n_files=$(find "$extracted_dir/replayable-queue" -type f | wc -l)
    log "    replayable-queue has $n_files files"
    container_name="covregen_${base}_$$"
    docker run --rm --name "$container_name" \
      -v "$extracted_dir:/mnt/outdir" \
      -v "$cov_script_tmp:/mnt/scripts" \
      "$IMAGE" /bin/bash -c "
        set -e
        cd /home/ubuntu/experiments/openssl-gcov
        chmod +x /mnt/scripts/robust_cov_script.sh
        /mnt/scripts/robust_cov_script.sh /mnt/outdir 4433 5 /mnt/outdir/cov_over_time_v2.csv 1 /mnt/outdir/cov_over_time_v2.debug.log
      " || warn "  WARNING: container exited non-zero for $base (see debug log if produced)"
    if [ -f "$extracted_dir/cov_over_time_v2.csv" ]; then
      cp "$extracted_dir/cov_over_time_v2.csv" "$out_csv_v2"
      log "    -> wrote $out_csv_v2"
    else
      warn "  ERROR: no cov_over_time_v2.csv produced for $base"
    fi
    if [ -f "$extracted_dir/cov_over_time_v2.debug.log" ]; then
      cp "$extracted_dir/cov_over_time_v2.debug.log" "$out_log_v2"
      n_fail_line=$(grep -c "REPLAY FAILURE" "$out_log_v2" || true)
      log "    -> wrote $out_log_v2 ($n_fail_line individual replay failures logged, retried automatically)"
    fi
    rm -rf "$work"
  done
  log "  Coverage regeneration loop done."
}

verify_coverage_outputs() {
  log "=== Verifying coverage outputs ==="
  shopt -s nullglob
  local tarballs=("$RESULTS_DIR"/*.tar.gz)
  local expect=${#tarballs[@]} n_found=0 n_missing=0 n_frozen=0 tb base out ratio
  for tb in "${tarballs[@]}"; do
    base=$(basename "$tb" .tar.gz)
    out="$RESULTS_DIR/${base}.cov_over_time_v2.csv"
    if [ ! -f "$out" ]; then n_missing=$((n_missing+1)); warn "  MISSING: $out"; continue; fi
    n_found=$((n_found+1))
    # col 3 = l_abs (absolute line count); must climb over the replay.
    ratio=$(awk -F',' 'NR>1 && $3+0>0 {if(f==""){f=$3} l=$3} END{ if(f=="") print "NA"; else printf "%.2f", l/f }' "$out" 2>/dev/null)
    if [ "$ratio" = "NA" ] || { [ "$ratio" != "NA" ] && awk -v r="$ratio" -v th="$COV_FROZEN_RATIO" 'BEGIN{exit !(r<th)}'; }; then
      n_frozen=$((n_frozen+1)); warn "  FROZEN/ZERO: $out (l_abs last/first=$ratio)"
    fi
  done
  log "  _v2.csv: $n_found/$expect present, $n_missing missing, $n_frozen frozen/zero"
  if [ "$n_missing" -gt 0 ] || [ "$n_frozen" -gt 0 ]; then
    warn "  Coverage problems found. Delete the affected _v2.csv and re-invoke to retry (idempotent)."
    return 1
  fi
  log "  Coverage verification: OK"
  return 0
}

run_coverage_phase() {
  log "=== Phase 2: sequential coverage generation (one container at a time) ==="
  if [ "$SMOKE_TEST" -eq 1 ]; then log "  Phase 2 skipped (smoke test)."; return 0; fi
  local completed_n
  completed_n=$(jq '.completed_algos | length' "$STATE_FILE" 2>/dev/null || echo 0)
  if [ "$completed_n" -lt "${#ALL_ALGOS[@]}" ]; then
    warn "Phase 2 skipped: Phase 1 incomplete (${completed_n}/${#ALL_ALGOS[@]} algos). Finish Phase 1 first."
    return 0
  fi
  if is_coverage_done; then
    log "  Coverage already marked done; re-running verification only."
    verify_coverage_outputs || true
    return 0
  fi
  check_disk "coverage phase"
  COV_SCRIPT_TMP=$(mktemp -d)
  printf '%s\n' "$EMBEDDED_ROBUST_COV" > "$COV_SCRIPT_TMP/robust_cov_script.sh"
  chmod +x "$COV_SCRIPT_TMP/robust_cov_script.sh"
  log "  Running sequential coverage regeneration (one container at a time)..."
  run_coverage_orchestrator "$COV_SCRIPT_TMP"
  rm -rf "$COV_SCRIPT_TMP"
  local cov_ok=1
  verify_coverage_outputs || cov_ok=0
  if [ "$cov_ok" -eq 0 ]; then
    if [ "$PILOT" -eq 1 ]; then
      warn "  PILOT: coverage problems found (see above). Eyeball the l_abs values in the _v2.csv files before the full run."
    else
      die "  Coverage verification FAILED (missing or frozen/zero _v2.csv). Delete the affected _v2.csv file(s) and re-invoke to retry (idempotent)."
    fi
  fi
  if [ "$cov_ok" -eq 1 ]; then
    mark_coverage_done
  fi
  log "=== Phase 2 complete ==="
  echo ""
}

# ---------------------------------------------------------------------------
# Print summary table — one row per algorithm, aggregated over RUNS reps.
# ---------------------------------------------------------------------------

print_summary() {
  local _mode_label
  if [ "$SMOKE_TEST" -eq 1 ]; then
    _mode_label="smoke test"
  elif [ "$PILOT" -eq 1 ]; then
    _mode_label="pilot run"
  else
    _mode_label="production run"
  fi
  log "=== Summary (${#ALL_ALGOS[@]} algorithms x ${RUNS} reps, ${_mode_label}) ==="
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
  if [ "$SMOKE_TEST" -eq 1 ]; then
    log "  Coverage (Phase 2): skipped (smoke test)."
  else
    local cov_expected=0 cov_found=0 _tb _base
    shopt -s nullglob
    for _tb in "$RESULTS_DIR"/*.tar.gz; do
      cov_expected=$((cov_expected+1))
      _base=$(basename "$_tb" .tar.gz)
      [ -f "$RESULTS_DIR/${_base}.cov_over_time_v2.csv" ] && cov_found=$((cov_found+1))
    done
    shopt -u nullglob
    local _cov_state
    _cov_state=$(jq -r '.coverage // "pending"' "$STATE_FILE" 2>/dev/null || echo "pending")
    if [ "$cov_expected" -gt 0 ] && [ "$cov_found" -eq "$cov_expected" ] && [ "$_cov_state" = "done" ]; then
      log "  Coverage (Phase 2): OK — ${cov_found}/${cov_expected} _v2.csv present, all verified."
    else
      log "  Coverage (Phase 2): ${cov_found}/${cov_expected} _v2.csv present (state: ${_cov_state})."
    fi
  fi
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
  elif [ "$PILOT" -eq 1 ]; then
    log "PILOT: ${#ALL_ALGOS[@]} algorithm(s) x ${RUNS} reps x ${TIMEOUT}s — sequential"
    log "(validation run — results dir suffixed '${RESULTS_DIR_SUFFIX}',"
    log "kept separate from production data)"
  else
    log "24h Production Run: ${#ALL_ALGOS[@]} algorithms x ${RUNS} reps — sequential"
  fi
  log "======================================================================"
  log "Order: ${ALL_ALGOS[*]}"
  log "Reps per algorithm (parallel): $RUNS"
  log "Timeout per algorithm: ${TIMEOUT}s"
  log "Robustness: periodic health checks every $(fmt_duration "$POLL_INTERVAL"),"
  log "bounded auto-restart (< $(fmt_duration "$EARLY_FAILURE_WINDOW") elapsed, one"
  log "attempt per rep), continuous non-fatal disk monitoring, persistent"
  log "run-state file for algorithm-granular resume after interruption."
  log "======================================================================"
  echo ""

  preflight
  check_disk "execution start"
  run_all_algos_sequentially
  extract_remaining
  verify_mab_outputs
  run_coverage_phase
  print_summary

  log "======================================================================"
  if [ "$SMOKE_TEST" -eq 1 ]; then
    log "SMOKE TEST COMPLETE"
    log "If everything above looks correct (sequencing, extraction, summary),"
    log "the orchestration logic is validated. Proceed with the real"
    log "production run: bash $0"
  elif [ "$PILOT" -eq 1 ]; then
    log "PILOT COMPLETE"
    log "If the coverage verification above passed (all _v2.csv present and"
    log "not frozen), the pipeline is validated. Proceed with the full run:"
    log "bash $0 --algos rerun"
  else
    log "24h ${#ALL_ALGOS[@]}-Algorithm Production Run COMPLETE"
  fi
  log "======================================================================"
  log "Results: $RESULTS_DIR"
  log "Log file: $LOG_FILE"
  log ""
}

main "$@"
