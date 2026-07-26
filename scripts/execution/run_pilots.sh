#!/bin/bash
# Run a 5-minute validation pilot for each seed selection algorithm (-s 1 through -s 7),
# then extract results, print a summary table, and render each ipsm.dot to PNG.
#
# Usage:
#   source ~/fuzz/profuzzbench/fuzz-env.sh
#   bash run_pilots.sh
#
# Prerequisites:
#   - openssl-mabflnet Docker image built
#   - graphviz installed on the host (apt-get install graphviz)

set -e

TIMEOUT=300   # 5 minutes per algorithm
SKIPCOUNT=1
IMAGE=openssl-mabflnet
COMMON_OPTS="-P TLS -D 10000 -q 3 -E -K -R -W 100"
PILOTS_DIR="${RESULTS}/pilots"

ALGOS=(
  "1:RANDOM"
  "2:ROUND-ROBIN"
  "3:FAVOR"
  "4:EXP3"
  "5:EXP3-IX"
  "6:SB-EXP3"
  "7:SB-EXP3-IX"
)

mkdir -p "$PILOTS_DIR"

echo "=== Validation pilots ==="
echo "Image:   $IMAGE"
echo "Timeout: ${TIMEOUT}s per algorithm"
echo "Results: $PILOTS_DIR"
echo ""

# ── Phase 1: run all pilots ──────────────────────────────────────────────────

for entry in "${ALGOS[@]}"; do
  S="${entry%%:*}"
  NAME="${entry##*:}"
  OUTDIR="out-pilot-s${S}-${NAME}"

  echo "--- s${S} (${NAME}) ---"
  profuzzbench_exec_common.sh $IMAGE 1 "$PILOTS_DIR" \
    mabflnet "$OUTDIR" \
    "${COMMON_OPTS} -s ${S}" \
    $TIMEOUT $SKIPCOUNT 1
  echo ""
done

echo "=== All pilots finished, post-processing... ==="
echo ""

# ── Phase 2: extract tarballs ────────────────────────────────────────────────

for entry in "${ALGOS[@]}"; do
  S="${entry%%:*}"
  NAME="${entry##*:}"
  OUTDIR="out-pilot-s${S}-${NAME}"
  TARBALL="$PILOTS_DIR/${OUTDIR}_1.tar.gz"

  if [ -f "$TARBALL" ]; then
    tar -xzf "$TARBALL" -C "$PILOTS_DIR"
  else
    echo "WARNING: $TARBALL not found, skipping s${S}"
  fi
done

# ── Phase 3: summary table ───────────────────────────────────────────────────

echo "=== Summary ==="
printf "%-6s %-14s %10s %8s %8s %8s\n" \
  "s" "Algorithm" "Execs" "States" "Paths" "Crashes"
printf "%-6s %-14s %10s %8s %8s %8s\n" \
  "------" "--------------" "----------" "--------" "--------" "--------"

for entry in "${ALGOS[@]}"; do
  S="${entry%%:*}"
  NAME="${entry##*:}"
  OUTDIR="out-pilot-s${S}-${NAME}"
  STATSFILE="$PILOTS_DIR/${OUTDIR}/fuzzer_stats"
  DOTFILE="$PILOTS_DIR/${OUTDIR}/ipsm.dot"

  if [ ! -f "$STATSFILE" ]; then
    printf "%-6s %-14s %10s %8s %8s %8s\n" \
      "s${S}" "$NAME" "N/A" "N/A" "N/A" "N/A"
    continue
  fi

  EXECS=$(grep   "^execs_done"     "$STATSFILE" | awk -F': ' '{print $2}' | tr -d ' ')
  PATHS=$(grep   "^paths_total"    "$STATSFILE" | awk -F': ' '{print $2}' | tr -d ' ')
  CRASHES=$(grep "^unique_crashes" "$STATSFILE" | awk -F': ' '{print $2}' | tr -d ' ')

  # Count nodes in ipsm.dot (lines containing "->" or standalone node declarations)
  if [ -f "$DOTFILE" ]; then
    STATES=$(grep -c '^\s*[0-9]' "$DOTFILE" 2>/dev/null || echo "?")
  else
    STATES="?"
  fi

  printf "%-6s %-14s %10s %8s %8s %8s\n" \
    "s${S}" "$NAME" "$EXECS" "$STATES" "$PATHS" "$CRASHES"
done

echo ""

# ── Phase 4: render ipsm.dot to PNG ─────────────────────────────────────────

if ! command -v dot &>/dev/null; then
  echo "WARNING: 'dot' (graphviz) not found on host. Skipping IPSM rendering."
  echo "         Install with: sudo apt-get install graphviz"
else
  echo "=== Rendering IPSM graphs ==="
  for entry in "${ALGOS[@]}"; do
    S="${entry%%:*}"
    NAME="${entry##*:}"
    OUTDIR="out-pilot-s${S}-${NAME}"
    DOTFILE="$PILOTS_DIR/${OUTDIR}/ipsm.dot"
    PNGFILE="$PILOTS_DIR/${OUTDIR}/ipsm.png"

    if [ -f "$DOTFILE" ]; then
      dot -Tpng "$DOTFILE" -o "$PNGFILE"
      echo "  s${S} (${NAME}): $PNGFILE"
    else
      echo "  s${S} (${NAME}): ipsm.dot not found, skipping"
    fi
  done
fi

echo ""
echo "=== Done. Results in: $PILOTS_DIR ==="
