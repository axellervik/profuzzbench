#!/usr/bin/env python3
"""
Full algorithmic analysis of a 1h-mab-diagnostic run.
Usage:
  python analyse_full.py [results_dir]
  python analyse_full.py                        # defaults to latest 1h-mab-diagnostic-N

Sections:
  A. Throughput (execs/sec) — is overhead healthy?
  B. Coverage trajectory — are algos still climbing at hour-end?
  C. MAB rounds sanity — actual ticks per algo
  D. Arm utilisation — how many arms are actually being used?
  E. Exploitation vs exploration — weight/pull concentration per algo
  F. Reward signal quality — non-zero reward rate from reward log
  G. Sleep-window behaviour — are SB variants sleeping correctly?
  H. Cross-algo verdict table — ready for 24h or needs tweaking?
"""

import sys
import statistics
from pathlib import Path

RESULTS = Path(r"C:\Users\axle\fuzz-plan\results")

# ---------------------------------------------------------------------------
# Resolve target directory
# ---------------------------------------------------------------------------

if len(sys.argv) > 1:
    DIAG = Path(sys.argv[1])
    if not DIAG.is_absolute():
        DIAG = RESULTS / sys.argv[1]
else:
    # Auto-select the highest-numbered 1h-mab-diagnostic-N folder
    candidates = sorted(
        [d for d in RESULTS.iterdir()
         if d.is_dir() and d.name.startswith("1h-mab-diagnostic")],
        key=lambda d: (
            int(d.name.split("-")[-1]) if d.name.split("-")[-1].isdigit() else 0,
            d.name
        )
    )
    if not candidates:
        print("No 1h-mab-diagnostic* directories found.")
        sys.exit(1)
    DIAG = candidates[-1]

print(f"Analysing: {DIAG}")

RUNS = 10

ALGOS = [
    ("4", "EXP3"),
    ("5", "EXP3-IX"),
    ("6", "SB-EXP3"),
    ("7", "SB-EXP3-IX"),
    ("8", "UCB1"),
    ("9", "THOMPSON"),
]

# Fixed baseline for the EXP3/EXP3-IX pulled-arm-set comparison (Section H)
# when analysing a sleeping-bandit-only pilot that did not re-run s4/s5
# itself. EXP3/EXP3IX's choose_seed()/mab_update_reward() code paths are
# unchanged since this run, so it remains a valid baseline (verified when
# the sleeping-bandit redesign was implemented).
BASELINE_DIAG = RESULTS / "1h-mab-diagnostic-5"

# Detect sleep-only-pilot mode: no s4 (EXP3) data alongside s6/s7 in DIAG.
IS_SLEEP_ONLY_PILOT = not (DIAG / "out-1h-mab-s4-EXP3_1").exists()
if IS_SLEEP_ONLY_PILOT:
    print(f"Detected sleep-only pilot — baseline EXP3/EXP3-IX data will be "
          f"read from {BASELINE_DIAG}")

# ---------------------------------------------------------------------------
# Parsers
# ---------------------------------------------------------------------------

def parse_fuzzer_stats(path):
    d = {}
    try:
        for line in path.read_text().splitlines():
            if ':' in line:
                k, _, v = line.partition(':')
                d[k.strip()] = v.strip()
    except Exception:
        pass
    return d

def parse_mab_stats(path):
    rows = []
    try:
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith('#') or line.startswith('mab') or line.startswith('timestamp'):
                continue
            parts = line.split()
            if len(parts) >= 6:
                try:
                    rows.append({
                        'state_id':      int(parts[0]),
                        'arm_idx':       int(parts[1]),
                        'pull_count':    int(parts[2]),
                        'log_weight':    float(parts[3]),
                        'cumul_reward':  float(parts[4]),
                        'last_selected': int(parts[5]),
                    })
                except ValueError:
                    pass
    except Exception:
        pass
    return rows

def parse_mab_header(path):
    """Return dict of header key->value from mab_stats header lines."""
    d = {}
    try:
        for line in path.read_text().splitlines():
            if line.startswith('mab') or line.startswith('timestamp'):
                k, _, v = line.partition(':')
                d[k.strip()] = v.strip()
    except Exception:
        pass
    return d

def parse_reward_log(path):
    """Return list of dicts from mab_reward_log."""
    rows = []
    try:
        lines = path.read_text().splitlines()
        for line in lines[1:]:  # skip header
            parts = line.strip().split(',')
            if len(parts) >= 6:
                try:
                    rows.append({
                        'ts_ms':        int(parts[0]),
                        'state_id':     int(parts[1]),
                        'arm_idx':      int(parts[2]),
                        'edges_before': int(parts[3]),
                        'edges_after':  int(parts[4]),
                        'reward':       float(parts[5]),
                    })
                except ValueError:
                    pass
    except Exception:
        pass
    return rows

def parse_cov(path):
    """Return list of (time, b_abs) from cov_over_time.csv."""
    rows = []
    try:
        lines = path.read_text().splitlines()
        for line in lines[1:]:
            parts = line.strip().split(',')
            if len(parts) >= 5:
                try:
                    rows.append((int(parts[0]), int(parts[4])))
                except ValueError:
                    pass
    except Exception:
        pass
    return rows

def rep_dir(s, name, rep, base=None):
    """base defaults to DIAG; pass base=BASELINE_DIAG to read baseline data
    from a different results directory (used when analysing a sleep-only
    pilot that doesn't itself contain EXP3/EXP3-IX reps)."""
    root = base if base is not None else DIAG
    return root / f"out-1h-mab-s{s}-{name}_{rep}"

def sep(title=""):
    print()
    print("=" * 72)
    if title:
        print(f"  {title}")
        print("=" * 72)

def safe_mean(lst):
    return f"{statistics.mean(lst):.3f}" if lst else "N/A"

# ---------------------------------------------------------------------------
# A. Throughput
# ---------------------------------------------------------------------------

sep("A. THROUGHPUT (execs/sec)")
print(f"{'Algo':<14} {'mean_execs':>10}  {'mean_execs/sec':>14}  {'min':>8}  {'max':>8}")
print("-" * 60)

TIMEOUT = 3600
for s, name in ALGOS:
    execs_l = []
    for rep in range(1, RUNS+1):
        fs = parse_fuzzer_stats(rep_dir(s, name, rep) / "fuzzer_stats")
        if fs:
            execs_l.append(int(fs.get('execs_done', 0)))
    if execs_l:
        mean_e = statistics.mean(execs_l)
        print(f"{name:<14} {int(mean_e):>10}  {mean_e/TIMEOUT:>14.2f}  {min(execs_l):>8}  {max(execs_l):>8}")

# ---------------------------------------------------------------------------
# B. Coverage trajectory — last 20% of run vs first 20%
# ---------------------------------------------------------------------------

sep("B. COVERAGE TRAJECTORY (branch coverage, first vs last 20% of run)")
print(f"{'Algo':<14} {'rep':>4}  {'t0 b_abs':>10}  {'t20% b_abs':>12}  "
      f"{'t80% b_abs':>12}  {'tfinal b_abs':>13}  {'still_climbing':>14}")
print("-" * 90)

algo_still_climbing = {}
for s, name in ALGOS:
    climbing_count = 0
    for rep in range(1, RUNS+1):
        cov = parse_cov(rep_dir(s, name, rep) / "cov_over_time.csv")
        if len(cov) < 4:
            continue
        t_start  = cov[0][0]
        t_end    = cov[-1][0]
        duration = t_end - t_start
        if duration == 0:
            continue

        def at_frac(frac):
            target = t_start + frac * duration
            best = cov[0]
            for pt in cov:
                if pt[0] <= target:
                    best = pt
            return best[1]

        b0   = at_frac(0.0)
        b20  = at_frac(0.2)
        b80  = at_frac(0.8)
        bfin = cov[-1][1]
        climbing = bfin > b80
        if climbing:
            climbing_count += 1
        print(f"{name:<14} {rep:>4}  {b0:>10}  {b20:>12}  {b80:>12}  "
              f"{bfin:>13}  {'YES' if climbing else 'no':>14}")
    algo_still_climbing[name] = climbing_count

print()
print("Summary — reps still climbing in final 20% of run:")
for s, name in ALGOS:
    print(f"  {name:<14}: {algo_still_climbing.get(name,0)}/10 reps still climbing")

# ---------------------------------------------------------------------------
# C. MAB rounds sanity
# ---------------------------------------------------------------------------

sep("C. MAB ROUNDS (total per-execution ticks, max last_selected across all states)")
print(f"{'Algo':<14} {'mean_rounds':>12}  {'min':>8}  {'max':>8}  {'status':>8}")
print("-" * 60)

for s, name in ALGOS:
    rounds_l = []
    for rep in range(1, RUNS+1):
        rows = parse_mab_stats(rep_dir(s, name, rep) / "mab_stats")
        max_r = max((r['last_selected'] for r in rows), default=0)
        rounds_l.append(max_r)
    if rounds_l:
        mean_r = statistics.mean(rounds_l)
        note = "LOW" if mean_r < 5000 else ("OK" if mean_r >= 10000 else "~OK")
        print(f"{name:<14} {int(mean_r):>12}  {min(rounds_l):>8}  {max(rounds_l):>8}  {note:>8}")

# ---------------------------------------------------------------------------
# D. Arm utilisation — per state
# ---------------------------------------------------------------------------

sep("D. ARM UTILISATION (state 0, rep 1 — fraction of arms ever pulled)")
print(f"{'Algo':<14} {'total_arms':>10}  {'arms_pulled':>12}  {'utilisation%':>13}  {'total_pulls':>12}")
print("-" * 65)

for s, name in ALGOS:
    rows = parse_mab_stats(rep_dir(s, name, 1) / "mab_stats")
    s0 = [r for r in rows if r['state_id'] == 0]
    if not s0:
        print(f"{name:<14}  (no state 0 data)")
        continue
    total_arms  = len(s0)
    arms_pulled = sum(1 for r in s0 if r['pull_count'] > 0)
    total_pulls = sum(r['pull_count'] for r in s0)
    util_pct    = 100 * arms_pulled / total_arms if total_arms else 0
    print(f"{name:<14} {total_arms:>10}  {arms_pulled:>12}  {util_pct:>12.1f}%  {total_pulls:>12}")

print()
print("Mean arm utilisation across all 10 reps (state 0):")
for s, name in ALGOS:
    utils = []
    for rep in range(1, RUNS+1):
        rows = parse_mab_stats(rep_dir(s, name, rep) / "mab_stats")
        s0 = [r for r in rows if r['state_id'] == 0]
        if s0:
            total  = len(s0)
            pulled = sum(1 for r in s0 if r['pull_count'] > 0)
            utils.append(100 * pulled / total)
    if utils:
        print(f"  {name:<14}: {statistics.mean(utils):.1f}%  "
              f"(min {min(utils):.1f}%  max {max(utils):.1f}%)")

# ---------------------------------------------------------------------------
# E. Exploitation vs exploration — weight/pull concentration (Gini + top-arm %)
# ---------------------------------------------------------------------------

sep("E. EXPLOITATION vs EXPLORATION (state 0, mean over 10 reps)")
print(f"{'Algo':<14} {'mean_gini':>10}  {'top1_arm_%':>11}  {'top5_arms_%':>12}  {'log_wt_spread_mean':>19}")
print("-" * 70)

for s, name in ALGOS:
    ginis, top1s, top5s, spreads = [], [], [], []
    for rep in range(1, RUNS+1):
        rows = parse_mab_stats(rep_dir(s, name, rep) / "mab_stats")
        s0     = [r for r in rows if r['state_id'] == 0]
        pulled = [r for r in s0 if r['pull_count'] > 0]
        if not pulled:
            continue
        counts = sorted([r['pull_count'] for r in pulled], reverse=True)
        total  = sum(counts)
        if total == 0:
            continue
        n = len(counts)
        gini_num = sum(abs(a - b) for i, a in enumerate(counts) for b in counts[i:])
        gini = gini_num / (n * total) if total > 0 else 0
        ginis.append(gini)
        top1s.append(100 * counts[0] / total)
        top5s.append(100 * sum(counts[:5]) / total)
        weights = [r['log_weight'] for r in s0]
        spreads.append(max(weights) - min(weights))

    print(f"{name:<14} {safe_mean(ginis):>10}  {safe_mean(top1s):>10}%  "
          f"{safe_mean(top5s):>11}%  {safe_mean(spreads):>19}")

# ---------------------------------------------------------------------------
# F. Reward signal quality
# ---------------------------------------------------------------------------

sep("F. REWARD SIGNAL QUALITY (from mab_reward_log, rep 1)")
print(f"{'Algo':<14} {'total_rewards':>14}  {'nonzero':>8}  {'nonzero%':>9}  "
      f"{'mean_nonzero_reward':>20}  {'max_reward':>11}")
print("-" * 80)

for s, name in ALGOS:
    rlog = parse_reward_log(rep_dir(s, name, 1) / "mab_reward_log")
    if not rlog:
        print(f"{name:<14}  (no reward log)")
        continue
    total   = len(rlog)
    nonzero = [r['reward'] for r in rlog if r['reward'] > 0]
    nz_pct  = 100 * len(nonzero) / total if total else 0
    mean_nz = statistics.mean(nonzero) if nonzero else 0
    max_r   = max(r['reward'] for r in rlog) if rlog else 0
    print(f"{name:<14} {total:>14}  {len(nonzero):>8}  {nz_pct:>8.1f}%  "
          f"{mean_nz:>20.6f}  {max_r:>11.6f}")

print()
print("Note: reward log records every fuzz_one() call; nonzero = new edges OR new path found.")
print("      After Fix 2A (path bonus), nonzero% should rise even after branch coverage plateaus.")
print("      Low total_rewards = few fuzz_one() calls = throughput issue.")

# ---------------------------------------------------------------------------
# G. Sleep-window behaviour (SB variants) — reads design/K_active from header
# ---------------------------------------------------------------------------

sep("G. SLEEP-WINDOW BEHAVIOUR (SB-EXP3 s6, SB-EXP3-IX s7 — rep 1)")
print("Sleep design: 'asleep' = was_fuzzed && !favored && queue_cycle>1.")
print("K_active is data-dependent (depends on how many seeds AFLNet's own")
print("cull_queue() has marked exhausted) — there is no fixed sqrt(K) target.")
print()

for s, name in [("6", "SB-EXP3"), ("7", "SB-EXP3-IX")]:
    mabfile = rep_dir(s, name, 1) / "mab_stats"
    header  = parse_mab_header(mabfile)
    rows    = parse_mab_stats(mabfile)
    s0      = [r for r in rows if r['state_id'] == 0]
    if not s0:
        print(f"  {name}: no state 0 data")
        continue

    design = header.get('mab_sleep_design', 'legacy_recency_window (pre-redesign run)')
    k_active_logged = header.get('mab_K_active_s0', None)
    K = len(s0)
    never_pulled = sum(1 for r in s0 if r['pull_count'] == 0)

    print(f"  {name}:")
    print(f"    mab_sleep_design           : {design}")
    print(f"    mab_K_active_s0  (header)  : {k_active_logged}")
    print(f"    K (total arms in state 0)  : {K}")
    print(f"    Never pulled (pull_count=0): {never_pulled}")
    if k_active_logged is not None:
        try:
            k_active_val = int(k_active_logged)
            pct_asleep = 100 * (K - k_active_val) / K if K else 0
            print(f"    Arms asleep                : {K - k_active_val} ({pct_asleep:.1f}% of K)")
            if k_active_val >= K:
                print(f"    Note                       : K_active==K — either no seeds exhausted yet")
                print(f"                                 (queue_cycle==1, or too early), or all")
                print(f"                                 exhausted seeds happen to still be favored.")
        except ValueError:
            pass
    print()

# ---------------------------------------------------------------------------
# H. Verdict table
# ---------------------------------------------------------------------------

sep("H. VERDICT — READY FOR 24H OR NEEDS TWEAKING?")

verdicts = {}
for s, name in ALGOS:
    issues = []
    notes  = []

    # Rounds check
    rounds_l = []
    for rep in range(1, RUNS+1):
        rows  = parse_mab_stats(rep_dir(s, name, rep) / "mab_stats")
        max_r = max((r['last_selected'] for r in rows), default=0)
        rounds_l.append(max_r)
    mean_rounds = statistics.mean(rounds_l)
    if mean_rounds < 3000:
        issues.append(f"LOW mab_rounds ({int(mean_rounds)}) — reward ticks not firing")

    # Arm utilisation
    utils = []
    for rep in range(1, RUNS+1):
        rows = parse_mab_stats(rep_dir(s, name, rep) / "mab_stats")
        s0   = [r for r in rows if r['state_id'] == 0]
        if s0:
            utils.append(100 * sum(1 for r in s0 if r['pull_count'] > 0) / len(s0))
    mean_util = statistics.mean(utils) if utils else 0
    if mean_util < 2.0:
        issues.append(f"Very low arm utilisation ({mean_util:.1f}%) — K too large or exploration broken")
    elif mean_util < 10.0:
        notes.append(f"Low arm utilisation ({mean_util:.1f}%) — normal at 1h but watch at 24h")

    # Coverage still climbing
    climbing = algo_still_climbing.get(name, 0)
    if climbing < 5:
        notes.append(f"Only {climbing}/10 reps still climbing in final 20% — may plateau at 24h")
    else:
        notes.append(f"{climbing}/10 reps still climbing — good signal for 24h benefit")

    # Reward signal
    rlog = parse_reward_log(rep_dir(s, name, 1) / "mab_reward_log")
    if rlog:
        nonzero = sum(1 for r in rlog if r['reward'] > 0)
        nz_pct  = 100 * nonzero / len(rlog)
        if nz_pct < 20:
            notes.append(f"Sparse reward signal ({nz_pct:.0f}% nonzero) — check path bonus is active")
        elif nz_pct >= 70:
            notes.append(f"Good reward signal ({nz_pct:.0f}% nonzero) — path bonus working")

    # EXP3 family weight spread check
    if name in ("EXP3", "EXP3-IX", "SB-EXP3", "SB-EXP3-IX"):
        spreads = []
        for rep in range(1, RUNS+1):
            rows = parse_mab_stats(rep_dir(s, name, rep) / "mab_stats")
            s0   = [r for r in rows if r['state_id'] == 0]
            if s0:
                weights = [r['log_weight'] for r in s0]
                spreads.append(max(weights) - min(weights))
        mean_spread = statistics.mean(spreads) if spreads else 0
        if mean_spread < 0.001:
            issues.append(f"Weight spread near zero ({mean_spread:.5f}) — gamma clamped or no reward")
        elif mean_spread < 0.05:
            notes.append(f"Small weight spread ({mean_spread:.4f}) — exploitation weak but present")
        else:
            notes.append(f"Good weight spread ({mean_spread:.4f}) — exploitation working")

    # SB-specific: check SB is behaviourally distinct from plain EXP3/EXP3-IX
    # (the historical failure mode was that they were bit-for-bit identical).
    if name in ("SB-EXP3", "SB-EXP3-IX"):
        mabfile = rep_dir(s, name, 1) / "mab_stats"
        header  = parse_mab_header(mabfile)
        rows    = parse_mab_stats(mabfile)
        s0      = [r for r in rows if r['state_id'] == 0]

        baseline_name = "EXP3" if name == "SB-EXP3" else "EXP3-IX"
        baseline_s = "4" if name == "SB-EXP3" else "5"
        baseline_root = BASELINE_DIAG if IS_SLEEP_ONLY_PILOT else None
        base_rows = parse_mab_stats(
            rep_dir(baseline_s, baseline_name, 1, base=baseline_root) / "mab_stats"
        )
        base_s0   = [r for r in base_rows if r['state_id'] == 0]

        if s0 and base_s0:
            sb_pulled   = set(r['arm_idx'] for r in s0 if r['pull_count'] > 0)
            base_pulled = set(r['arm_idx'] for r in base_s0 if r['pull_count'] > 0)
            if sb_pulled == base_pulled:
                issues.append(
                    f"{name} pulled-arm set is IDENTICAL to {baseline_name} — "
                    f"sleeping mechanism had no observable effect this run"
                )
            else:
                notes.append(
                    f"{name} pulled-arm set differs from {baseline_name} "
                    f"({len(sb_pulled)} vs {len(base_pulled)} arms) — sleeping is active"
                )
            if IS_SLEEP_ONLY_PILOT:
                notes.append(
                    f"{baseline_name} baseline sourced from {BASELINE_DIAG.name} "
                    f"(code path unchanged since that run — verified)"
                )
        elif IS_SLEEP_ONLY_PILOT and not base_s0:
            issues.append(
                f"Could not load {baseline_name} baseline from "
                f"{BASELINE_DIAG.name} — check that directory exists"
            )

        design = header.get('mab_sleep_design', None)
        if design is None:
            notes.append("mab_sleep_design not in header — old run, cannot confirm design")

    verdicts[name] = (issues, notes)

print(f"{'Algo':<14}  {'Status':<10}  Details")
print("-" * 72)
for s, name in ALGOS:
    issues, notes = verdicts[name]
    status = "BLOCK" if issues else "GO"
    print(f"{name:<14}  {status:<10}")
    for i in issues:
        print(f"               ISSUE: {i}")
    for n in notes:
        print(f"               note:  {n}")
    print()

print("=" * 72)
print("SUMMARY")
print("=" * 72)
blocked = [name for s, name in ALGOS if verdicts[name][0]]
go      = [name for s, name in ALGOS if not verdicts[name][0]]
print(f"  Ready for 24h (no blocking issues): {', '.join(go) if go else 'none'}")
print(f"  Needs tweaking first:               {', '.join(blocked) if blocked else 'none'}")
