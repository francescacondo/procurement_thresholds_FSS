"""
net_fig_graphs.py -- node-and-link pictures of the procurement network (illustration only).

  net_graph_schematic.png   the five winner classes on the Phase 2 toy network
  net_graph_ego.png         one real authority: its suppliers in the 24 months
                            before the reform, their other buyers, and the
                            winners of its post-reform lots below 139k coloured
                            by their Phase 2 class
  net_graph_market.png      one real market (CPV2 x region): authority-supplier
                            links in the 24 months before 17 Jul 2020 vs the 24
                            months to 30 Jun 2023, same node positions

Firms are never labelled (some codice_fiscale belong to individuals); authorities
are labelled generically. Nothing here enters the estimates.
"""
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
import networkx as nx
import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(sys.argv[0])))  # Stata defines no __file__
from net_common import Paths, get_root, log, need, read_dta, stata_to_ts
import net_netlib as NL

COL = {1: "#1f3b73", 2: "#7fb3e6", 3: "#9a9a9a", 4: "#f08a24", 5: "#c0143c"}
NAME = {1: "Incumbent", 2: "Prior, not incumbent", 3: "Indirect (two steps)", 4: "Outsider", 5: "New (no award)"}
AUTH_C, SUP_C, FADE = "#2b2b2b", "#5b7fa6", "#d6d6d6"

EGO_AUTH, EGO_CPV2 = "02198590503", 71      # chosen: 14 suppliers pre-reform, 17 P2 lots below 139k, all 5 classes
MKT_CPV2, MKT_REGION = 80, "SEZIONE REGIONALE EMILIA ROMAGNA"   # chosen: similar size before/after (non-PNRR)
D_PRE0, D_PRE1 = 21382, 22113               # 17jul2018 - 17jul2020
D_POST0, D_POST1 = 22462, 23192             # 01jul2021 - 30jun2023 (exclusive end 01jul2023)
D_EGO0, D_EGO1 = 21701, 22432               # 01jun2019 - 01jun2021


def legend_classes(ax, extra=()):
    h = [Line2D([0], [0], marker="o", color="w", markerfacecolor=COL[k], markersize=10, label=NAME[k])
         for k in range(1, 6)]
    ax.legend(handles=list(extra) + h, loc="lower center", ncol=4, frameon=False, fontsize=9,
              bbox_to_anchor=(0.5, -0.08))


def schematic(P):
    """Hand-placed version of the toy network used to test Phase 2."""
    fig, ax = plt.subplots(figsize=(11, 6.5))
    pos = {"A": (0, 0), "B": (2.2, 1.6), "C": (2.6, -1.9),
           "s1": (1.0, 1.0), "s2": (1.0, -0.2), "s3": (1.3, 2.4),
           "w_inc": (-1.6, 1.4), "w_pri": (1.0, -1.2), "w_ind": (3.6, 2.4),
           "w_out": (3.9, -1.9), "w_new": (-1.8, -1.6)}
    hist = [("A", "s1"), ("A", "s2"), ("A", "w_inc"), ("A", "w_pri"), ("B", "s1"), ("B", "s3"),
            ("B", "w_ind"), ("C", "w_out")]
    won = {"w_inc": 1, "w_pri": 2, "w_ind": 3, "w_out": 4, "w_new": 5}
    for u, v in hist:
        ax.plot(*zip(pos[u], pos[v]), color="#8c8c8c", lw=1.6, zorder=1)
    for w, k in won.items():
        ax.annotate("", xy=pos[w], xytext=pos["A"],
                    arrowprops=dict(arrowstyle="-|>", color=COL[k], lw=2.2, ls="--",
                                    shrinkA=18, shrinkB=12, connectionstyle="arc3,rad=0.18"), zorder=2)
    for a, lab in (("A", "Authority A\n(focal lot)"), ("B", "Authority B"), ("C", "Authority C")):
        ax.scatter(*pos[a], marker="s", s=900 if a == "A" else 520, c=AUTH_C, zorder=3)
        ax.text(pos[a][0], pos[a][1] - 0.42, lab, ha="center", va="top", fontsize=10)
    for s in ("s1", "s2", "s3"):
        ax.scatter(*pos[s], s=260, c=SUP_C, zorder=3)
    for w, k in won.items():
        ax.scatter(*pos[w], s=420, c=COL[k], edgecolors="k", linewidths=0.8, zorder=4)
    notes = {"w_inc": "won A's immediately\npreceding award (same CPV3)",
             "w_pri": "supplied A before,\nbut not the last award",
             "w_ind": "never supplied A; B bought\nfrom it AND from A's supplier",
             "w_out": "awards only with authorities\nnot linked to A's suppliers",
             "w_new": "no award at all in the\nmarket in the past 24 months"}
    off = {"w_inc": (-0.1, 0.35), "w_pri": (0, -0.38), "w_ind": (0, 0.36), "w_out": (0, -0.38), "w_new": (0, -0.38)}
    for w, k in won.items():
        x, y = pos[w]
        dx, dy = off[w]
        ax.text(x + dx, y + dy, NAME[k] + ":\n" + notes[w], ha="center", va="bottom" if dy > 0 else "top",
                fontsize=8.5, color=COL[k] if k != 3 else "#555555")
    ax.set_title("How the winner of a lot at authority A is classified (past 24 months, same market)", fontsize=12)
    extra = [Line2D([0], [0], color="#8c8c8c", lw=1.6, label="award in the past 24 months"),
             Line2D([0], [0], color="k", lw=2, ls="--", label="wins the focal lot"),
             Line2D([0], [0], marker="s", color="w", markerfacecolor=AUTH_C, markersize=10, label="authority"),
             Line2D([0], [0], marker="o", color="w", markerfacecolor=SUP_C, markersize=9, label="other supplier")]
    ax.legend(handles=extra, loc="lower center", ncol=4, frameon=False, fontsize=9, bbox_to_anchor=(0.5, -0.06))
    ax.set_xlim(-3, 5)
    ax.set_ylim(-2.9, 3.2)
    ax.axis("off")
    out = os.path.join(P.figures, "net_graph_schematic.png")
    fig.savefig(out, dpi=200, bbox_inches="tight")
    plt.close(fig)
    log("wrote " + out)


def ego(P, e, focal):
    me = e[(e.mk == "%02d" % EGO_CPV2)]
    pre = me[(me.t >= D_EGO0) & (me.t < D_EGO1)]
    supA = set(pre.cf_key[pre.authority_id == EGO_AUTH])
    buyers = set(pre.authority_id[pre.cf_key.isin(supA)]) - {EGO_AUTH}
    lots = focal[(focal.authority_id == EGO_AUTH) & (focal.cpv2 == EGO_CPV2) & (focal.period == 2)
                 & (focal.pnrr == 0) & (focal.x <= 0) & (focal.x >= -40000)].sort_values("t")   # x <= 0: lots at exactly 139,000 are eligible (main code 1.7)
    win = lots.groupby("cf_key").net_class.first()            # class of the firm's first such lot
    G = nx.Graph()
    G.add_node("A", kind="A")
    for s in supA:
        G.add_node(s, kind="sup")
        G.add_edge("A", s)
    for b in buyers:
        G.add_node(b, kind="auth")
        for s in set(pre.cf_key[pre.authority_id == b]) & supA:
            G.add_edge(b, s)
    # where post-reform winners sit in their own window (Phase 2 definitions)
    spec = NL.SPECS[""]
    lw = NL.add_window(lots.drop_duplicates("cf_key"), spec)
    links = []
    for _, r in lw.iterrows():
        w = me[(me.t >= r.s) & (me.t < r.q)]
        k = int(win[r.cf_key])
        G.add_node(r.cf_key, kind="win", cls=k)
        if k in (3, 4):
            bf = list(dict.fromkeys(w.authority_id[(w.cf_key == r.cf_key) & (w.authority_id != EGO_AUTH)]))
            sA = set(w.cf_key[w.authority_id == EGO_AUTH])
            pick = None
            for b in bf:      # indirect: a b that also bought from A's supplier; outsider: any buyer (none is linked)
                if k == 4 or (set(w.cf_key[w.authority_id == b]) & sA):
                    pick = b
                    break
            if k == 4 and pick in buyers:      # keep the picture honest: draw the outsider's buyer apart
                pick = "OUT:" + pick
            if pick is not None:
                G.add_node(pick, kind="auth")
                G.add_edge(pick, r.cf_key)
                links.append((pick, r.cf_key))
                if k == 3:
                    s_link = sorted(set(w.cf_key[w.authority_id == pick]) & sA)[0]
                    G.add_node(s_link, kind="sup")
                    G.add_edge("A", s_link)
                    G.add_edge(pick, s_link)
    # layout: A in the centre, its pre-reform suppliers on ring 1, their other buyers on
    # ring 2; post-reform winners on an outer ring, one sector per class (degrees):
    #   prior/incumbent winners sit on ring 1 (they are, or became, A's suppliers)
    #   indirect  -60..+20 (with the linking authority b placed between ring 1 and it)
    #   outsider   35..70 (with one of its buyers next to it)   new  110..250 (no links)
    SECT = {3: (-60, 20), 4: (35, 70), 5: (110, 250)}
    pos = {"A": np.array([0.0, 0.0])}
    sup = sorted(n for n, d in G.nodes(data=True) if d["kind"] == "sup")
    wins = [n for n, d in G.nodes(data=True) if d["kind"] == "win"]
    for i_, n in enumerate(sup):
        a = 2 * np.pi * i_ / max(len(sup), 1)
        pos[n] = 1.0 * np.array([np.cos(a), np.sin(a)])
    link_auth = {b: w for b, w in links}
    for k, (a0, a1) in SECT.items():
        ws = [n for n in wins if G.nodes[n]["cls"] == k and n not in sup]
        for i_, n in enumerate(ws):
            a = np.deg2rad(a0 + (a1 - a0) * (i_ + 0.5) / max(len(ws), 1))
            pos[n] = 3.2 * np.array([np.cos(a), np.sin(a)])
    rng = np.random.default_rng(4)
    for n in wins:
        if n not in pos:                                           # prior/incumbent winner not yet on ring 1
            a = rng.uniform(0, 2 * np.pi); pos[n] = 1.0 * np.array([np.cos(a), np.sin(a)])
    oth = [n for n, d in G.nodes(data=True) if d["kind"] == "auth"]
    for n in oth:
        if n in link_auth:                                         # linking authority: just inside its winner
            pos[n] = 0.72 * pos[link_auth[n]]
            continue
        nb = [m for m in G.neighbors(n) if m in pos]
        ang = np.mean([np.arctan2(pos[m][1], pos[m][0]) for m in nb]) if nb else 0.0
        pos[n] = 1.9 * np.array([np.cos(ang), np.sin(ang)])
    fig, ax = plt.subplots(figsize=(10, 10))
    for u, v in G.edges():
        ax.plot(*zip(pos[u], pos[v]), color="#9c9c9c", lw=1.0, zorder=1)
    for n in wins:
        ax.annotate("", xy=pos[n], xytext=pos["A"], arrowprops=dict(arrowstyle="-|>", color=COL[G.nodes[n]["cls"]],
                    lw=1.6, ls="--", shrinkA=14, shrinkB=7, alpha=0.9), zorder=2)
    ax.scatter(*pos["A"], marker="s", s=700, c=AUTH_C, zorder=4)
    ax.text(0, -0.25, "Authority A", ha="center", va="top", fontsize=10, zorder=5,
            bbox=dict(facecolor="white", edgecolor="none", alpha=0.7))
    ax.scatter([pos[n][0] for n in oth], [pos[n][1] for n in oth], marker="s", s=140, c="#777777", zorder=3)
    plain = [n for n in sup if n not in wins]
    ax.scatter([pos[n][0] for n in plain], [pos[n][1] for n in plain], s=120, c=SUP_C, zorder=3)
    for n in wins:
        ax.scatter(*pos[n], s=230, c=COL[G.nodes[n]["cls"]], edgecolors="k", linewidths=0.7, zorder=5)
    cnt = pd.Series([G.nodes[n]["cls"] for n in wins]).value_counts().sort_index()
    ax.set_title("One authority's supplier network (CPV2 %d, awards Jun 2019 - May 2021)\n"
                 "and the winners of its %d post-reform lots below 139k (%d firms), by class"
                 % (EGO_CPV2, len(lots), len(wins)), fontsize=11)
    extra = [Line2D([0], [0], marker="s", color="w", markerfacecolor="#777777", markersize=9, label="other authority"),
             Line2D([0], [0], marker="o", color="w", markerfacecolor=SUP_C, markersize=9, label="A's supplier (pre-reform)"),
             Line2D([0], [0], color="k", lw=1.6, ls="--", label="wins a post-reform lot at A")]
    legend_classes(ax, extra)
    ax.text(0.5, -0.13, "Firms by class: " + ", ".join("%s %d" % (NAME[k], v) for k, v in cnt.items())
            + ". Links of indirect/outsider winners come from each lot's own 24-month window.",
            transform=ax.transAxes, ha="center", fontsize=8.5)
    ax.set_aspect("equal")
    ax.axis("off")
    out = os.path.join(P.figures, "net_graph_ego.png")
    fig.savefig(out, dpi=200, bbox_inches="tight")
    plt.close(fig)
    log("wrote " + out + " | lots=%d firms=%d by class %s" % (len(lots), len(wins), cnt.to_dict()))


def market(P, e):
    me = e[(e.mk == "%02d" % MKT_CPV2) & (e.region == MKT_REGION) & (e.pnrr == 0)]
    pre = me[(me.t >= D_PRE0) & (me.t < D_PRE1)]
    post = me[(me.t >= D_POST0) & (me.t < D_POST1)]
    G = nx.Graph()
    for d in (pre, post):
        for a, f in zip(d.authority_id, d.cf_key):
            G.add_node("A:" + a, bip=0)
            G.add_node("F:" + f, bip=1)
            G.add_edge("A:" + a, "F:" + f)
    # layout: the largest connected component with Kamada-Kawai in [-1, 1]^2; the many
    # small components (often one authority with one or two suppliers) packed in a
    # grid to the right, so they neither crowd nor squeeze the main component
    comps = sorted(nx.connected_components(G), key=len, reverse=True)
    pos = {k_: v * 1.0 for k_, v in nx.kamada_kawai_layout(G.subgraph(comps[0])).items()}
    small = comps[1:]
    ncol = max(1, int(np.ceil(np.sqrt(len(small) / 2.0))))
    for i_, c in enumerate(small):
        r, q = divmod(i_, ncol)
        cx, cy = 1.35 + 0.32 * q, 0.95 - 0.21 * r
        sub = nx.spring_layout(G.subgraph(c), seed=1, scale=0.07) if len(c) > 1 else {next(iter(c)): np.zeros(2)}
        for n_, v in sub.items():
            pos[n_] = np.array([cx, cy]) + v
    n_giant = len(comps[0])
    fpre, fpost = set("F:" + pre.cf_key), set("F:" + post.cf_key)
    fig, axes = plt.subplots(1, 2, figsize=(16, 8.2))
    for ax, d, title in ((axes[0], pre, "Before: awards 17 Jul 2018 - 16 Jul 2020"),
                         (axes[1], post, "After: awards 1 Jul 2021 - 30 Jun 2023")):
        el = set(zip("A:" + d.authority_id, "F:" + d.cf_key))
        for u, v in el:
            ax.plot(*zip(pos[u], pos[v]), color="#a0a0a0", lw=0.5, alpha=0.8, zorder=1)
        act = {n for e2 in el for n in e2}
        ina = [n for n in G if n not in act]
        ax.scatter([pos[n][0] for n in ina], [pos[n][1] for n in ina], s=8, c=FADE, zorder=2,
                   marker="o")
        auths = [n for n in act if n.startswith("A:")]
        deg = {n: G.subgraph(act).degree(n) for n in act}
        ax.scatter([pos[n][0] for n in auths], [pos[n][1] for n in auths], marker="s",
                   s=[14 + 6 * min(deg[n], 15) for n in auths], c=AUTH_C, zorder=4)
        firms = [n for n in act if n.startswith("F:")]
        if d is pre:
            c = ["#5b7fa6" if n in fpost else "#9a9a9a" for n in firms]
        else:
            c = ["#5b7fa6" if n in fpre else COL[5] for n in firms]
        ax.scatter([pos[n][0] for n in firms], [pos[n][1] for n in firms],
                   s=[12 + 6 * min(deg[n], 15) for n in firms], c=c, edgecolors="white", linewidths=0.3, zorder=3)
        ax.set_title(title + "\n%d authorities, %d suppliers, %d distinct authority-supplier links"
                     % (len(auths), len(firms), len(el)), fontsize=11)
        ax.axis("off")
    both = len(fpre & fpost)
    fig.suptitle("Supplier network of one market: CPV2 %d (education and training services), %s, non-PNRR lots"
                 % (MKT_CPV2, MKT_REGION.replace("SEZIONE REGIONALE ", "").title()), fontsize=13)
    h = [Line2D([0], [0], marker="s", color="w", markerfacecolor=AUTH_C, markersize=9, label="authority (size = no. of suppliers)"),
         Line2D([0], [0], marker="o", color="w", markerfacecolor="#5b7fa6", markersize=9, label="supplier active in both windows (%d)" % both),
         Line2D([0], [0], marker="o", color="w", markerfacecolor="#9a9a9a", markersize=9, label="supplier only before (%d)" % len(fpre - fpost)),
         Line2D([0], [0], marker="o", color="w", markerfacecolor=COL[5], markersize=9, label="supplier only after (%d)" % len(fpost - fpre)),
         Line2D([0], [0], marker="o", color="w", markerfacecolor=FADE, markersize=7, label="node not active in this window")]
    fig.legend(handles=h, loc="lower center", ncol=3, frameon=False, fontsize=9, bbox_to_anchor=(0.5, 0.0))
    fig.text(0.5, -0.035, "All lot values and procedures, non-PNRR; same node positions in both panels; "
             "node size capped at 15 links. Left block: largest connected component; right grid: the other, small components. "
             "Illustration only (one market, one region).", ha="center", fontsize=8)
    out = os.path.join(P.figures, "net_graph_market.png")
    fig.savefig(out, dpi=200, bbox_inches="tight")
    plt.close(fig)
    log("wrote " + out + " | pre: %d awards, post: %d awards, suppliers in both: %d | components: %d (largest %d nodes)"
        % (len(pre), len(post), both, len(comps), n_giant))


def component_layout(G):
    """Largest connected component with Kamada-Kawai; small components in a grid
    to the right (same layout rule as net_graph_market.png)."""
    comps = sorted(nx.connected_components(G), key=len, reverse=True)
    pos = dict(nx.kamada_kawai_layout(G.subgraph(comps[0])))
    ncol = max(1, int(np.ceil(np.sqrt(len(comps[1:]) / 2.0))))
    for i_, c in enumerate(comps[1:]):
        r, q = divmod(i_, ncol)
        sub = nx.spring_layout(G.subgraph(c), seed=1, scale=0.07) if len(c) > 1 else {next(iter(c)): np.zeros(2)}
        for n_, v in sub.items():
            pos[n_] = np.array([1.35 + 0.32 * q, 0.95 - 0.21 * r]) + v
    return pos


def market_anim(P, e, sub_frames=3, fps=8):
    """Month-by-month animation of the same market: frame m shows the authority-
    supplier links of the 24-month window [m-24, m), m = 2020m7 ... 2023m7.
    Node positions never move; nodes and links fade in/out between months."""
    from matplotlib.animation import FuncAnimation, PillowWriter
    from matplotlib.collections import LineCollection
    me = e[(e.mk == "%02d" % MKT_CPV2) & (e.region == MKT_REGION) & (e.pnrr == 0)].copy()
    ts = stata_to_ts(me.t)
    me["tm"] = (ts.dt.year - 1960) * 12 + ts.dt.month - 1
    m0, m1 = 726, 762                                        # windows ending 2020m7 ... 2023m7
    me = me[(me.tm >= m0 - 24) & (me.tm < m1)]
    me["A"], me["F"] = "A:" + me.authority_id, "F:" + me.cf_key
    G = nx.Graph()
    G.add_edges_from(zip(me.A, me.F))
    pos = component_layout(G)
    nodes, edges = list(G.nodes()), list(G.edges())
    nid = {n: i for i, n in enumerate(nodes)}
    months = list(range(m0, m1 + 1))
    actN = np.zeros((len(months), len(nodes)))
    actE = np.zeros((len(months), len(edges)))
    eid = {frozenset(x): i for i, x in enumerate(edges)}
    for k, m in enumerate(months):
        w = me[(me.tm >= m - 24) & (me.tm < m)]
        for a, f in set(zip(w.A, w.F)):
            actN[k, nid[a]] = actN[k, nid[f]] = 1
            actE[k, eid[frozenset((a, f))]] = 1
    is_auth = np.array([n.startswith("A:") for n in nodes])
    base = actN[0] > 0                                       # suppliers active in the first window
    rgb = np.array([matplotlib.colors.to_rgb(AUTH_C if is_auth[i] else (SUP_C if base[i] else COL[5]))
                    for i in range(len(nodes))])
    deg = np.array([min(G.degree(n), 15) for n in nodes])
    size = np.where(is_auth, 14 + 6 * deg, 12 + 6 * deg)
    xy = np.array([pos[n] for n in nodes])
    seg = np.array([[pos[u], pos[v]] for u, v in edges])
    # frame schedule: hold first and last window, cross-fade in between
    sched = [(0, 0.0)] * 6
    for k in range(len(months) - 1):
        sched += [(k, s / sub_frames) for s in range(sub_frames)]
    sched += [(len(months) - 1, 0.0)] * 10

    fig = plt.figure(figsize=(9, 8.6))
    ax = fig.add_axes([0.02, 0.12, 0.96, 0.74])
    tl = fig.add_axes([0.08, 0.05, 0.84, 0.035])
    ax.axis("off")
    ax.scatter(xy[:, 0], xy[:, 1], s=6, c=FADE, zorder=1)
    lc = LineCollection(seg, colors=[(0.6, 0.6, 0.6, 0)] * len(seg), linewidths=0.5, zorder=2)
    ax.add_collection(lc)
    sc = ax.scatter(xy[:, 0], xy[:, 1], s=size, marker="o", c=np.c_[rgb, np.zeros(len(nodes))], zorder=3,
                    linewidths=0)
    au = np.where(is_auth)[0]
    sa = ax.scatter(xy[au, 0], xy[au, 1], s=size[au], marker="s", c=np.c_[rgb[au], np.zeros(len(au))], zorder=4)
    sc.set_sizes(np.where(is_auth, 0, size))
    title = fig.suptitle("", fontsize=12)
    tl.set_xlim(m0 - 24, m1)
    tl.set_ylim(0, 1)
    tl.set_yticks([])
    yrs = [(y - 1960) * 12 for y in range(2019, 2024)]
    tl.set_xticks(yrs)
    tl.set_xticklabels([str(y) for y in range(2019, 2024)], fontsize=8)
    tl.axvline((2021 - 1960) * 12 + 5, color=COL[5], lw=2)
    tl.text((2021 - 1960) * 12 + 5, 1.15, "reform 1 Jun 2021", color=COL[5], fontsize=8, ha="center")
    win = tl.axvspan(m0 - 24, m0, color="#5b7fa6", alpha=0.35)
    h = [Line2D([0], [0], marker="s", color="w", markerfacecolor=AUTH_C, markersize=8, label="authority"),
         Line2D([0], [0], marker="o", color="w", markerfacecolor=SUP_C, markersize=8, label="supplier already active in first window"),
         Line2D([0], [0], marker="o", color="w", markerfacecolor=COL[5], markersize=8, label="supplier that appears later")]
    ax.legend(handles=h, loc="lower left", frameon=False, fontsize=8)

    def lab(m):
        return "%s %d" % (["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][m % 12], 1960 + m // 12)

    def draw(i):
        k, w_ = sched[i]
        a = actN[k] if w_ == 0 else (1 - w_) * actN[k] + w_ * actN[k + 1]
        ae = actE[k] if w_ == 0 else (1 - w_) * actE[k] + w_ * actE[k + 1]
        sc.set_facecolors(np.c_[rgb, a])
        sa.set_facecolors(np.c_[rgb[au], a[au]])
        lc.set_colors(np.c_[np.full((len(seg), 3), 0.6), 0.8 * ae])
        m = months[k]
        win.set_x(m - 24); win.set_width(24)
        k_ = actN[k] > 0
        title.set_text("CPV2 %d (education and training), Emilia-Romagna, non-PNRR\nawards in the 24 months %s - %s\n"
                       "%d authorities, %d suppliers (%d appeared after the first window)"
                       % (MKT_CPV2, lab(m - 24), lab(m - 1), (k_ & is_auth).sum(), (k_ & ~is_auth).sum(),
                          (k_ & ~is_auth & ~base).sum()))
        return sc, sa, lc

    ani = FuncAnimation(fig, draw, frames=len(sched), blit=False)
    out = os.path.join(P.figures, "net_graph_market_monthly.gif")
    ani.save(out, writer=PillowWriter(fps=fps), dpi=85)
    draw(len(sched) // 2)
    fig.savefig(os.path.join(P.figures, "net_graph_market_monthly_midframe.png"), dpi=70)
    plt.close(fig)
    log("wrote " + out + " | %d frames, %d months, %d nodes, %d links" % (len(sched), len(months), len(nodes), len(edges)))


def main():
    P = Paths(get_root())
    log("Network graphs | ROOT=" + P.root)
    schematic(P)
    snapdir = os.path.join(P.inter, "net_snapshots")
    e = read_dta(need(P.inter_f("net_edges.dta")), ["cig", "authority_id", "cf_key", "cpv2", "region", "pub_year", "pnrr"])
    et = read_dta(need(os.path.join(snapdir, "edges_timed.dta")), ["cig", "t"])
    e = e.merge(et, on="cig", validate="1:1")
    e = e[(e.cf_key != "") & (e.pub_year <= 2023)].copy()
    e["mk"] = NL.market_key(e, "cpv2")
    f = read_dta(need(P.inter_f("net_lots_universe.dta")),
                 ["cig", "authority_id", "cf_key", "cpv2", "cpv3", "period", "pnrr", "importo_lotto", "in_lots_winners"])
    f = f[f.in_lots_winners == 1]
    ft = read_dta(need(P.inter_f("net_phase1_focal.dta")), ["cig", "net_t", "net_tm"])
    m = read_dta(need(P.inter_f("net_lot_measures.dta")), ["cig", "net_class"])
    f = f.merge(ft, on="cig").merge(m, on="cig").rename(columns={"net_t": "t", "net_tm": "tm"})
    f["tm"] = f.tm.astype("int64")
    f["x"] = f.importo_lotto - 139000
    ego(P, e, f)
    market(P, e)
    market_anim(P, e)
    log("Network graphs finished")


if __name__ == "__main__":
    main()
