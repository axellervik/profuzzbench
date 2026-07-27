#!/usr/bin/env python3
"""
plot_seed_tree.py — Seed lineage tree visualizer for mabflnet runs.

Reads a single AFLNet/mabflnet output directory and produces:
  - An interactive HTML graph (via pyvis)
  - A static PNG (via matplotlib + networkx)

Node visual encoding:
  size        ∝ pull_count (how many times MAB selected this seed)
  colour      = state_id palette  OR  reward heatmap  OR  depth gradient
  gold border = initial corpus seed (tree root)
  red halo    = seed that triggered new coverage (+cov in filename)

Edge encoding:
  solid grey  = normal parent → child mutation
  dashed blue = splice secondary parent

Usage:
  python plot_seed_tree.py \\
      --outdir /path/to/out-s4-EXP3 \\
      --algo "EXP3 (-s 4)" \\
      --html tree_exp3.html \\
      --png  tree_exp3.png

Dependencies:
  pip install networkx pyvis pandas matplotlib
  # For best PNG layout (optional):
  sudo apt-get install libgraphviz-dev
  pip install pygraphviz
"""

import argparse
import math
import os
import re
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")  # headless
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import networkx as nx
import pandas as pd


# ---------------------------------------------------------------------------
# 1. Parse queue filenames
# ---------------------------------------------------------------------------

_RE_ID       = re.compile(r"id[:/](\d+)")
_RE_SRC      = re.compile(r"src[:/](\d+)(?:\+(\d+))?")
_RE_OP       = re.compile(r"op[:/]([^,]+)")
_RE_ORIG     = re.compile(r"orig[:/](\S+)")


def parse_queue_dir(queue_dir: Path) -> dict:
    """
    Return a dict keyed by queue_id (int).
    Each value is a dict with keys:
        queue_id, src, splice_src, op, has_new_cov, filename
    """
    nodes = {}
    for fname in sorted(queue_dir.iterdir()):
        name = fname.name
        if name.startswith("."):
            continue

        m_id = _RE_ID.search(name)
        if not m_id:
            continue
        qid = int(m_id.group(1))

        m_src = _RE_SRC.search(name)
        src        = int(m_src.group(1))        if m_src and m_src.group(1) else None
        splice_src = int(m_src.group(2))        if m_src and m_src.group(2) else None

        m_op  = _RE_OP.search(name)
        m_orig = _RE_ORIG.search(name)
        op = m_op.group(1) if m_op else (f"orig:{m_orig.group(1)}" if m_orig else "?")

        has_new_cov = "+cov" in name

        nodes[qid] = dict(
            queue_id    = qid,
            src         = src,
            splice_src  = splice_src,
            op          = op,
            has_new_cov = has_new_cov,
            filename    = name,
        )
    return nodes


# ---------------------------------------------------------------------------
# 2. Load mab_seed_map  (optional)
# ---------------------------------------------------------------------------

def load_seed_map(outdir: Path) -> dict:
    """
    Returns dict: queue_id → {state_id, arm_idx, generating_state_id, is_initial}
    Empty dict if file absent.
    """
    path = outdir / "mab_seed_map"
    if not path.exists():
        return {}
    try:
        df = pd.read_csv(path)
        # columns: state_id, arm_idx, queue_id, generating_state_id, is_initial
        result = {}
        for _, row in df.iterrows():
            qid = int(row["queue_id"])
            # A seed can appear in multiple states; keep first occurrence
            # (state 0 is always first — the initial state entry)
            if qid not in result:
                result[qid] = dict(
                    state_id           = int(row["state_id"]),
                    arm_idx            = int(row["arm_idx"]),
                    generating_state_id= int(row["generating_state_id"]),
                    is_initial         = bool(int(row["is_initial"])),
                )
        return result
    except Exception as e:
        print(f"[warn] Could not load mab_seed_map: {e}", file=sys.stderr)
        return {}


# ---------------------------------------------------------------------------
# 3. Load mab_stats  (optional)
# ---------------------------------------------------------------------------

def load_mab_stats(outdir: Path) -> dict:
    """
    Returns dict: (state_id, arm_idx) → {pull_count, log_weight, cumul_reward}
    Empty dict if file absent.
    """
    path = outdir / "mab_stats"
    if not path.exists():
        return {}
    result = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or line.startswith("mab_") or line.startswith("timestamp"):
                    continue
                parts = line.split()
                if len(parts) < 6:
                    continue
                try:
                    state_id    = int(parts[0])
                    arm_idx     = int(parts[1])
                    pull_count  = int(parts[2])
                    log_weight  = float(parts[3])
                    cumul_reward= float(parts[4])
                    last_sel    = int(parts[5])
                    result[(state_id, arm_idx)] = dict(
                        pull_count   = pull_count,
                        log_weight   = log_weight,
                        cumul_reward = cumul_reward,
                        last_selected= last_sel,
                    )
                except ValueError:
                    continue
    except Exception as e:
        print(f"[warn] Could not load mab_stats: {e}", file=sys.stderr)
    return result


# ---------------------------------------------------------------------------
# 4. Aggregate mab_reward_log  (optional, cross-check)
# ---------------------------------------------------------------------------

def load_reward_log(outdir: Path) -> dict:
    """
    Returns dict: (state_id, arm_idx) → {total_reward, pull_count}
    Empty dict if file absent.
    """
    path = outdir / "mab_reward_log"
    if not path.exists():
        return {}
    try:
        df = pd.read_csv(path)
        agg = (df.groupby(["state_id", "arm_idx"])
                 .agg(total_reward=("reward", "sum"),
                      pull_count=("reward", "count"))
                 .reset_index())
        result = {}
        for _, row in agg.iterrows():
            key = (int(row["state_id"]), int(row["arm_idx"]))
            result[key] = dict(
                total_reward = float(row["total_reward"]),
                pull_count   = int(row["pull_count"]),
            )
        return result
    except Exception as e:
        print(f"[warn] Could not load mab_reward_log: {e}", file=sys.stderr)
        return {}


# ---------------------------------------------------------------------------
# 5. Build networkx DiGraph
# ---------------------------------------------------------------------------

def build_graph(nodes: dict, seed_map: dict, mab_stats: dict,
                reward_log: dict) -> nx.DiGraph:
    G = nx.DiGraph()

    # BFS depth from roots
    # First pass: record all edges so we can do BFS
    children = {qid: [] for qid in nodes}
    for qid, n in nodes.items():
        if n["src"] is not None and n["src"] in nodes:
            children[n["src"]].append(qid)

    # BFS
    depth = {}
    roots = [qid for qid, n in nodes.items() if n["src"] is None]
    queue = list(roots)
    for r in roots:
        depth[r] = 0
    while queue:
        cur = queue.pop(0)
        for child in children[cur]:
            if child not in depth:
                depth[child] = depth[cur] + 1
                queue.append(child)
    # Any disconnected nodes (shouldn't happen but be safe)
    for qid in nodes:
        if qid not in depth:
            depth[qid] = 0

    for qid, n in nodes.items():
        sm  = seed_map.get(qid, {})
        state_id   = sm.get("state_id", -1)
        arm_idx    = sm.get("arm_idx", -1)
        is_initial = sm.get("is_initial", n["src"] is None)  # fallback: root = initial

        # MAB stats: prefer mab_stats, fall back to reward_log
        stats_key = (state_id, arm_idx)
        ms = mab_stats.get(stats_key, {})
        rl = reward_log.get(stats_key, {})

        pull_count   = ms.get("pull_count",   rl.get("pull_count",   0))
        cumul_reward = ms.get("cumul_reward",  rl.get("total_reward", 0.0))
        log_weight   = ms.get("log_weight",    0.0)

        G.add_node(qid,
            queue_id    = qid,
            src         = n["src"],
            splice_src  = n["splice_src"],
            op          = n["op"],
            has_new_cov = n["has_new_cov"],
            state_id    = state_id,
            arm_idx     = arm_idx,
            is_initial  = is_initial,
            pull_count  = pull_count,
            cumul_reward= cumul_reward,
            log_weight  = log_weight,
            depth       = depth.get(qid, 0),
        )

    # Edges
    for qid, n in nodes.items():
        if n["src"] is not None and n["src"] in nodes:
            G.add_edge(n["src"], qid, splice=False)
        if n["splice_src"] is not None and n["splice_src"] in nodes:
            G.add_edge(n["splice_src"], qid, splice=True)

    return G


# ---------------------------------------------------------------------------
# 6. Compute visual attributes
# ---------------------------------------------------------------------------

# Fixed palette for up to 20 distinct state_ids
_STATE_COLOURS = [
    "#4e79a7", "#f28e2b", "#e15759", "#76b7b2", "#59a14f",
    "#edc948", "#b07aa1", "#ff9da7", "#9c755f", "#bab0ac",
    "#aecde8", "#ffbe7d", "#fabfd2", "#b3e2cd", "#d8b365",
    "#a6cee3", "#fb9a99", "#e31a1c", "#fdbf6f", "#ff7f00",
]

def _state_colour(state_id: int, state_ids: list) -> str:
    if state_id < 0 or state_id not in state_ids:
        return "#cccccc"
    idx = state_ids.index(state_id) % len(_STATE_COLOURS)
    return _STATE_COLOURS[idx]


def _reward_colour(cumul_reward: float, max_reward: float) -> str:
    """Blue (low) → Red (high) heatmap."""
    if max_reward <= 0:
        return "#aaaaaa"
    t = min(cumul_reward / max_reward, 1.0)
    r = int(55  + t * 200)
    g = int(130 - t * 100)
    b = int(200 - t * 180)
    return f"#{r:02x}{g:02x}{b:02x}"


def _depth_colour(d: int, max_depth: int) -> str:
    """Light (shallow) → Dark (deep) blue."""
    if max_depth <= 0:
        return "#aaaaaa"
    t = min(d / max_depth, 1.0)
    v = int(220 - t * 170)
    return f"#{v:02x}{v:02x}ff"


def compute_visual(G: nx.DiGraph, colour_by: str):
    """
    Attach 'size', 'colour', 'border_colour', 'border_width' to every node.
    colour_by: 'state' | 'reward' | 'depth'
    """
    all_state_ids = sorted(set(
        d["state_id"] for _, d in G.nodes(data=True) if d["state_id"] >= 0
    ))
    max_pull   = max((d["pull_count"]   for _, d in G.nodes(data=True)), default=1) or 1
    max_reward = max((d["cumul_reward"] for _, d in G.nodes(data=True)), default=1) or 1
    max_depth  = max((d["depth"]        for _, d in G.nodes(data=True)), default=1) or 1

    for nid, data in G.nodes(data=True):
        pc = data["pull_count"]
        # Size: minimum 8, scales with sqrt of pull_count
        data["size"]   = 8 + 3 * math.sqrt(pc) if pc > 0 else 8

        if colour_by == "reward":
            data["colour"] = _reward_colour(data["cumul_reward"], max_reward)
        elif colour_by == "depth":
            data["colour"] = _depth_colour(data["depth"], max_depth)
        else:  # "state" (default)
            data["colour"] = _state_colour(data["state_id"], all_state_ids)

        # Border: gold = initial seed, red = new coverage, else dark grey
        if data["is_initial"]:
            data["border_colour"] = "#ffd700"
            data["border_width"]  = 3
        elif data["has_new_cov"]:
            data["border_colour"] = "#e15759"
            data["border_width"]  = 2
        else:
            data["border_colour"] = "#555555"
            data["border_width"]  = 1

    return all_state_ids, max_pull, max_reward, max_depth


# ---------------------------------------------------------------------------
# 7. Render HTML (pyvis)
# ---------------------------------------------------------------------------

def render_html(G: nx.DiGraph, html_path: str, algo: str,
                all_state_ids: list, colour_by: str):
    try:
        from pyvis.network import Network
    except ImportError:
        print("[warn] pyvis not installed — skipping HTML output. "
              "Install with: pip install pyvis", file=sys.stderr)
        return

    net = Network(directed=True, height="900px", width="100%",
                  bgcolor="#1a1a2e", font_color="white",
                  heading=f"Seed Lineage Tree — {algo}")
    net.barnes_hut(gravity=-8000, central_gravity=0.3,
                   spring_length=120, spring_strength=0.05)

    for nid, data in G.nodes(data=True):
        label = (f"id:{data['queue_id']}\n"
                 f"op:{data['op']}\n"
                 f"state:{data['state_id']}\n"
                 f"pulls:{data['pull_count']}\n"
                 f"reward:{data['cumul_reward']:.4f}\n"
                 f"depth:{data['depth']}")
        net.add_node(
            nid,
            label     = f"id:{data['queue_id']}",
            title     = label,
            size      = data["size"],
            color     = {
                "background": data["colour"],
                "border":     data["border_colour"],
                "highlight":  {"background": "#ffffff", "border": data["border_colour"]},
            },
            borderWidth = data["border_width"],
        )

    for u, v, edata in G.edges(data=True):
        if edata.get("splice"):
            net.add_edge(u, v, color="#4e79a7", dashes=True, width=1)
        else:
            net.add_edge(u, v, color="#888888", width=1)

    net.show_buttons(filter_=["physics"])
    net.save_graph(html_path)
    print(f"[html] Written: {html_path}")


# ---------------------------------------------------------------------------
# 8. Render PNG (matplotlib + networkx)
# ---------------------------------------------------------------------------

def render_png(G: nx.DiGraph, png_path: str, algo: str,
               all_state_ids: list, colour_by: str,
               max_pull: int, max_reward: float):
    if G.number_of_nodes() == 0:
        print("[warn] No nodes to render.", file=sys.stderr)
        return

    # Layout: prefer graphviz dot (top-down tree), fall back to spring
    try:
        import pygraphviz  # noqa: F401
        pos = nx.nx_agraph.graphviz_layout(G, prog="dot")
    except Exception:
        print("[warn] pygraphviz not available — using spring layout for PNG.",
              file=sys.stderr)
        pos = nx.spring_layout(G, seed=42, k=2.5 / math.sqrt(G.number_of_nodes() + 1))

    fig, ax = plt.subplots(figsize=(20, 14))
    ax.set_facecolor("#f8f8f8")
    fig.patch.set_facecolor("#f8f8f8")

    node_list  = list(G.nodes())
    node_data  = [G.nodes[n] for n in node_list]
    node_sizes = [d["size"] ** 2 * 8 for d in node_data]  # matplotlib uses area
    node_colours = [d["colour"] for d in node_data]
    node_edge_colours = [d["border_colour"] for d in node_data]
    node_lw   = [d["border_width"] for d in node_data]

    # Draw normal edges
    normal_edges  = [(u, v) for u, v, d in G.edges(data=True) if not d.get("splice")]
    splice_edges  = [(u, v) for u, v, d in G.edges(data=True) if d.get("splice")]

    nx.draw_networkx_edges(G, pos, edgelist=normal_edges, ax=ax,
                           edge_color="#aaaaaa", arrows=True,
                           arrowsize=10, width=0.6,
                           connectionstyle="arc3,rad=0.05")
    if splice_edges:
        nx.draw_networkx_edges(G, pos, edgelist=splice_edges, ax=ax,
                               edge_color="#4e79a7", style="dashed", arrows=True,
                               arrowsize=10, width=1.0,
                               connectionstyle="arc3,rad=0.15")

    nx.draw_networkx_nodes(G, pos, nodelist=node_list, ax=ax,
                           node_size=node_sizes,
                           node_color=node_colours,
                           edgecolors=node_edge_colours,
                           linewidths=node_lw)

    # Labels only for nodes that have pull_count > 0 (avoid clutter)
    label_nodes = {n: str(n) for n in node_list
                   if G.nodes[n]["pull_count"] > 0 or G.nodes[n]["is_initial"]}
    if label_nodes:
        nx.draw_networkx_labels(G, pos, labels=label_nodes, ax=ax,
                                font_size=5, font_color="#222222")

    # Legend
    legend_handles = []

    if colour_by == "state":
        for sid in all_state_ids[:12]:  # cap legend at 12 entries
            c = _state_colour(sid, all_state_ids)
            legend_handles.append(mpatches.Patch(color=c, label=f"State {sid}"))
    elif colour_by == "reward":
        legend_handles = [
            mpatches.Patch(color=_reward_colour(0, 1),   label="Low reward"),
            mpatches.Patch(color=_reward_colour(0.5, 1), label="Med reward"),
            mpatches.Patch(color=_reward_colour(1, 1),   label="High reward"),
        ]
    else:  # depth
        legend_handles = [
            mpatches.Patch(color=_depth_colour(0, 10), label="Shallow"),
            mpatches.Patch(color=_depth_colour(5, 10), label="Mid depth"),
            mpatches.Patch(color=_depth_colour(10, 10), label="Deep"),
        ]

    legend_handles += [
        mpatches.Patch(facecolor="white", edgecolor="#ffd700",
                       linewidth=2, label="Initial seed"),
        mpatches.Patch(facecolor="white", edgecolor="#e15759",
                       linewidth=1.5, label="New coverage"),
        mpatches.Patch(color="#aaaaaa", label="Mutation edge"),
        mpatches.Patch(color="#4e79a7", label="Splice edge"),
    ]

    if max_pull > 0:
        for pc in [1, max(max_pull // 2, 1), max_pull]:
            sz = 8 + 3 * math.sqrt(pc)
            legend_handles.append(
                plt.scatter([], [], s=sz**2 * 8 / 100, color="#888888",
                            label=f"pulls={pc}")
            )

    ax.legend(handles=legend_handles, loc="upper left",
              fontsize=7, framealpha=0.85,
              title=f"colour_by={colour_by}")

    ax.set_title(f"Seed Lineage Tree — {algo}\n"
                 f"{G.number_of_nodes()} seeds, {G.number_of_edges()} edges",
                 fontsize=13)
    ax.axis("off")
    plt.tight_layout()
    plt.savefig(png_path, dpi=150, bbox_inches="tight")
    plt.close()
    print(f"[png]  Written: {png_path}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Visualize mabflnet seed lineage tree.")
    parser.add_argument("--outdir",     required=True,
                        help="Path to the fuzzer output directory (extracted tarball).")
    parser.add_argument("--algo",       default="",
                        help="Algorithm label for plot titles (e.g. 'EXP3 (-s 4)').")
    parser.add_argument("--html",       default=None,
                        help="Output path for interactive HTML graph.")
    parser.add_argument("--png",        default=None,
                        help="Output path for static PNG graph.")
    parser.add_argument("--colour-by",  default="state",
                        choices=["state", "reward", "depth"],
                        help="Node colour encoding (default: state).")
    parser.add_argument("--max-nodes",  type=int, default=0,
                        help="Prune to top-N seeds by pull_count (0 = no limit).")
    parser.add_argument("--no-html",    action="store_true",
                        help="Skip HTML output.")
    parser.add_argument("--no-png",     action="store_true",
                        help="Skip PNG output.")
    args = parser.parse_args()

    outdir = Path(args.outdir)
    if not outdir.exists():
        sys.exit(f"[error] Output directory not found: {outdir}")

    queue_dir = outdir / "queue"
    if not queue_dir.exists():
        sys.exit(f"[error] queue/ subdirectory not found in {outdir}")

    # Determine output paths
    html_path = args.html or str(outdir / "seed_tree.html")
    png_path  = args.png  or str(outdir / "seed_tree.png")
    algo      = args.algo or outdir.name

    print(f"[info] Reading queue from: {queue_dir}")

    # --- Steps 1–4: load data ---
    nodes      = parse_queue_dir(queue_dir)
    seed_map   = load_seed_map(outdir)
    mab_stats  = load_mab_stats(outdir)
    reward_log = load_reward_log(outdir)

    print(f"[info] Seeds parsed:    {len(nodes)}")
    print(f"[info] Seed map rows:   {len(seed_map)}")
    print(f"[info] MAB stats arms:  {len(mab_stats)}")
    print(f"[info] Reward log rows: {len(reward_log)}")

    if not nodes:
        sys.exit("[error] No queue entries found — nothing to visualise.")

    # --- Step 5: build graph ---
    G = build_graph(nodes, seed_map, mab_stats, reward_log)

    # --- Optional: prune to top-N by pull_count ---
    if args.max_nodes > 0 and G.number_of_nodes() > args.max_nodes:
        # Always keep initial seeds; fill remaining budget by pull_count desc
        initials = [n for n, d in G.nodes(data=True) if d["is_initial"]]
        budget   = args.max_nodes - len(initials)
        others   = sorted(
            [n for n, d in G.nodes(data=True) if not d["is_initial"]],
            key=lambda n: G.nodes[n]["pull_count"], reverse=True
        )
        keep = set(initials) | set(others[:max(budget, 0)])
        remove = [n for n in G.nodes() if n not in keep]
        G.remove_nodes_from(remove)
        print(f"[info] Pruned to {G.number_of_nodes()} nodes "
              f"(--max-nodes {args.max_nodes})")

    # --- Step 6: visual attributes ---
    all_state_ids, max_pull, max_reward, max_depth = compute_visual(
        G, args.colour_by)

    print(f"[info] States seen:     {all_state_ids}")
    print(f"[info] Max pull count:  {max_pull}")
    print(f"[info] Max depth:       {max_depth}")

    # --- Steps 7–8: render ---
    if not args.no_html:
        render_html(G, html_path, algo, all_state_ids, args.colour_by)

    if not args.no_png:
        render_png(G, png_path, algo, all_state_ids, args.colour_by,
                   max_pull, max_reward)


if __name__ == "__main__":
    main()
