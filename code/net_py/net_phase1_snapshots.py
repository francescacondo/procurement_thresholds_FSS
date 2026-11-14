"""
net_phase1_snapshots.py -- Phase 1 of the network extension (Project D).

Builds time-respecting authority x supplier networks (scipy.sparse), one per
version and focal month, plus the timing table for the focal lots.

Inputs : data/intermediate/net_edges.dta, net_lots_universe.dta (Phase 0)
Outputs: data/intermediate/net_snapshots/
            idx_<market>_auth.dta / idx_<market>_sup.dta  (index mappings)
            <version>/m<tm>.npz                           (one matrix per month)
            base_<market>.npz                             (fixed pre-reform network)
            manifest.csv
         data/intermediate/net_phase1_focal.dta           (1 row per focal cig)

DEFINITIONS (see docs/net_build_note.md, Phase 1)
  edge        one award-matched lot with one matched winner (net_edges.dta).
              History = lots PUBLISHED 2015-2023, all values/periods/PNRR
              (group decision: 2024 publications only in version w24_cpv2_y24).
  event date  award_date if present, in [2000-01-01, 2026-12-31] and not more
              than 365 days before pub_date; otherwise pub_date (flag *_timing_fallback = 1). Same rule for
              focal lots and history edges.
  window      focal month m (month of the focal lot's event date): awards with
              event date in [first day of m-W, first day of m), W = 24 or 12.
              Every history award is therefore STRICTLY before the focal award;
              same-day awards are excluded (and so are earlier awards in the
              same calendar month -- quantified in the diagnostics).
  market      networks are built within CPV2 (main) or CPV3. Rows of every
              matrix are (market, authority) pairs and columns (market,
              supplier) pairs, so the matrix is block-diagonal by market and
              products like A A' A never leave the market.
  baseline    fixed network of awards dated [17 Jul 2018, 17 Jul 2020), used
              for focal months from Aug 2020 on; earlier focal months use their
              rolling 24-month window (otherwise P0 lots would see the future).
  entries     number of awards of the pair in the window (binary = entry > 0).
"""
import os
import sys

import numpy as np
import pandas as pd
import scipy.sparse as sp

sys.path.insert(0, os.path.dirname(os.path.abspath(sys.argv[0])))  # Stata defines no __file__
from net_common import Paths, die, get_root, log, need, read_dta, write_dta, stata_to_ts

DAY_2000, DAY_2026 = 14610, 24471          # 01jan2000, 31dec2026 (Stata days)
BASE_START = 21382                         # 17jul2018
BASE_END = 22113                           # 17jul2020 (exclusive)
BASE_FIRST_MONTH = 727                     # 2020m8 (Stata %tm)

VERSIONS = {
    # name           market  W   history
    "w24_cpv2":     ("cpv2", 24, "main"),
    "w12_cpv2":     ("cpv2", 12, "main"),
    "w24_cpv3":     ("cpv3", 24, "main"),
    "w24_cpv2_y24": ("cpv2", 24, "with2024"),   # robustness (2024-published lots can carry 2023 award dates,
                                                # so this differs from w24_cpv2 before 2024 too)
}


def tm_of(days):
    ts = stata_to_ts(days)
    return ((ts.dt.year - 1960) * 12 + ts.dt.month - 1).astype("Int64")


def tm_label(tm):
    return "%dm%d" % (1960 + tm // 12, tm % 12 + 1)


def event_date(df):
    # implausible: outside 2000-2026, or more than a year BEFORE publication
    # (0.24% of edges; small negative gaps are common and kept)
    ok = df.award_date.between(DAY_2000, DAY_2026) & (df.award_date >= df.pub_date - 365)
    t = np.where(ok, df.award_date, df.pub_date)
    return pd.Series(t, index=df.index, dtype="float64"), (~ok).astype("int8")


def market_key(df, market):
    if market == "cpv2":
        return df.cpv2.where(df.cpv2.notna()).map(lambda v: "" if pd.isna(v) else "%02d" % int(v))
    k = df.cpv3.astype(str)
    return k.where(k.str.fullmatch(r"\d{3}"), "")


def main():
    P = Paths(get_root())
    out = os.path.join(P.inter, "net_snapshots")
    os.makedirs(out, exist_ok=True)
    log("Phase 1 | ROOT=" + P.root)

    # ------------------------------------------------------------------ edges
    e = read_dta(need(P.inter_f("net_edges.dta")),
                 ["cig", "authority_id", "cf_key", "cpv2", "cpv3", "pub_date", "pub_year",
                  "award_date", "period"])
    e = e[e.cf_key != ""].copy()
    e["t"], e["timing_fallback"] = event_date(e)
    e["tm"] = tm_of(e.t)
    log("edges: %s | event date = pub_date fallback: %d | published 2024: %s"
        % (format(len(e), ","), e.timing_fallback.sum(), format((e.pub_year == 2024).sum(), ",")))
    ey = stata_to_ts(e.t).dt.year
    print("  edges by event year (main history = published 2015-2023):")
    print("   " + ey[e.pub_year <= 2023].value_counts().sort_index().to_dict().__repr__())

    # ------------------------------------------------------------ focal lots
    f = read_dta(need(P.inter_f("net_lots_universe.dta")),
                 ["cig", "authority_id", "cf_key", "cpv2", "cpv3", "pub_date", "award_date",
                  "period", "pnrr", "in_lots_winners"])
    f = f[f.in_lots_winners == 1].drop(columns="in_lots_winners").copy()
    f["t"], f["net_timing_fallback"] = event_date(f)
    f["tm"] = tm_of(f.t)
    log("focal lots (lots_winners): %s | net_timing_fallback=1: %d"
        % (format(len(f), ","), f.net_timing_fallback.sum()))

    # -------------------------------------------------------- index mappings
    for mk in ("cpv2", "cpv3"):
        e["mk_" + mk] = market_key(e, mk)
        f["mk_" + mk] = market_key(f, mk)
        rows = pd.concat([e[["mk_" + mk, "authority_id"]], f[["mk_" + mk, "authority_id"]]])
        rows = rows[rows["mk_" + mk] != ""].drop_duplicates().sort_values(["mk_" + mk, "authority_id"])
        rows["row"] = np.arange(len(rows), dtype=np.int64)
        cols = pd.concat([e[["mk_" + mk, "cf_key"]], f[["mk_" + mk, "cf_key"]]])
        cols = cols[cols["mk_" + mk] != ""].drop_duplicates().sort_values(["mk_" + mk, "cf_key"])
        cols["col"] = np.arange(len(cols), dtype=np.int64)
        for d, nm in ((rows, "auth"), (cols, "sup")):
            write_dta(d.rename(columns={"mk_" + mk: "market"}),
                      os.path.join(out, "idx_%s_%s.dta" % (mk, nm)))
        e = e.merge(rows.rename(columns={"row": "row_" + mk}), on=["mk_" + mk, "authority_id"], how="left")
        e = e.merge(cols.rename(columns={"col": "col_" + mk}), on=["mk_" + mk, "cf_key"], how="left")
        f = f.merge(rows.rename(columns={"row": "row_" + mk}), on=["mk_" + mk, "authority_id"], how="left")
        f = f.merge(cols.rename(columns={"col": "col_" + mk}), on=["mk_" + mk, "cf_key"], how="left")
        log("%s: %s (market, authority) rows, %s (market, supplier) cols | edges without market: %d | focal without market: %d"
            % (mk, format(len(rows), ","), format(len(cols), ","),
               (e["mk_" + mk] == "").sum(), (f["mk_" + mk] == "").sum()))
    shape = {mk: (int(max(e["row_" + mk].max(), f["row_" + mk].max())) + 1,
                  int(max(e["col_" + mk].max(), f["col_" + mk].max())) + 1) for mk in ("cpv2", "cpv3")}

    def build(sub, mk):
        sub = sub[sub["row_" + mk].notna()]
        A = sp.coo_matrix((np.ones(len(sub), dtype=np.int32),
                           (sub["row_" + mk].astype(np.int64), sub["col_" + mk].astype(np.int64))),
                          shape=shape[mk]).tocsr()
        A.sum_duplicates()
        return A

    # --------------------------------------------------------- snapshots
    months = np.sort(f.tm.dropna().unique().astype(int))
    log("focal months: %s .. %s (%d months)" % (tm_label(months[0]), tm_label(months[-1]), len(months)))
    manifest = []
    for v, (mk, W, hist) in VERSIONS.items():
        os.makedirs(os.path.join(out, v), exist_ok=True)
        ev = e if hist == "with2024" else e[e.pub_year <= 2023]
        ev = ev.sort_values("tm")
        tmv = ev.tm.astype(int).values
        n_saved = 0
        for m in months:
            lo, hi = np.searchsorted(tmv, m - W, "left"), np.searchsorted(tmv, m, "left")
            A = build(ev.iloc[lo:hi], mk)
            sp.save_npz(os.path.join(out, v, "m%d.npz" % m), A)
            n_saved += 1
            manifest.append({"version": v, "market": mk, "W": W, "month": tm_label(m), "tm": m,
                             "edges": hi - lo, "nnz": A.nnz,
                             "active_rows": int((A.getnnz(axis=1) > 0).sum()),
                             "active_cols": int((A.getnnz(axis=0) > 0).sum())})
        log("version %-13s market=%s W=%d history=%s: %d monthly matrices" % (v, mk, W, hist, n_saved))
    for mk in ("cpv2", "cpv3"):
        eb = e[(e.pub_year <= 2023) & (e.t >= BASE_START) & (e.t < BASE_END)]
        A = build(eb, mk)
        sp.save_npz(os.path.join(out, "base_%s.npz" % mk), A)
        manifest.append({"version": "base_" + mk, "market": mk, "W": 24, "month": "fixed",
                         "tm": -1, "edges": len(eb), "nnz": A.nnz,
                         "active_rows": int((A.getnnz(axis=1) > 0).sum()),
                         "active_cols": int((A.getnnz(axis=0) > 0).sum())})
        log("baseline %s: awards dated [17jul2018, 17jul2020): %s edges, nnz=%s"
            % (mk, format(len(eb), ","), format(A.nnz, ",")))
    man = pd.DataFrame(manifest)
    man.to_csv(os.path.join(out, "manifest.csv"), index=False)
    s = man[man.tm >= 0].groupby("version")[["edges", "nnz", "active_rows", "active_cols"]].agg(["min", "median", "max"])
    pd.set_option("display.width", 220)
    print("\n  Snapshot sizes across focal months (min / median / max):")
    print(s.to_string())

    # ------------------------------------------------- verification (brute force)
    # For a random sample of focal lots, the snapshot entry A[a, f] must equal
    # the number of awards of the same (authority, supplier, market) pair whose
    # event date lies in [first day of m-W, first day of m), counted directly
    # from the edge list; and every such award must be strictly before the
    # focal event date.
    rng = np.random.default_rng(20261110)
    smp = f[f.row_cpv2.notna() & f.tm.notna()].sample(3000, random_state=7)
    main_e = e[e.pub_year <= 2023]
    grp = main_e.groupby(["authority_id", "cf_key", "mk_cpv2"])
    bad = 0
    cache = {}
    for _, r in smp.iterrows():
        m = int(r.tm)
        if m not in cache:
            cache[m] = sp.load_npz(os.path.join(out, "w24_cpv2", "m%d.npz" % m))
        snap = cache[m][int(r.row_cpv2), int(r.col_cpv2)]
        key = (r.authority_id, r.cf_key, r.mk_cpv2)
        if key in grp.groups:
            g = main_e.loc[grp.groups[key]]
            inw = g[(g.tm >= m - 24) & (g.tm < m)]
            brute = len(inw)
            if len(inw) and inw.t.max() >= r.t:
                bad += 1
        else:
            brute = 0
        bad += int(snap != brute)
        if len(cache) > 40:
            cache.clear()
    log("VERIFY: snapshot entry == brute-force window count for %d of %d sampled focal lots%s"
        % (len(smp) - bad, len(smp), "" if bad == 0 else "  <-- MISMATCH"))
    if bad:
        die("snapshot verification failed for %d sampled lots" % bad)

    # ------------------------------------------------------- diagnostics
    fd = f.copy()
    fd["window_post2023"] = (fd.tm >= 2024 * 12 - 1960 * 12 + 1).astype("int8")   # window reaches past 31dec2023
    # awards excluded because they fall earlier in the focal month (same authority x CPV2)
    me = main_e[main_e.mk_cpv2 != ""]
    first_am = me.groupby(["authority_id", "mk_cpv2", "tm"]).t.min().rename("t_first_am")
    first_afm = me.groupby(["authority_id", "cf_key", "mk_cpv2", "tm"]).t.min().rename("t_first_afm")
    fd = fd.merge(first_am, left_on=["authority_id", "mk_cpv2", "tm"], right_index=True, how="left")
    fd = fd.merge(first_afm, left_on=["authority_id", "cf_key", "mk_cpv2", "tm"], right_index=True, how="left")
    fd["samemonth_auth"] = (fd.t_first_am < fd.t).astype("int8")
    fd["samemonth_pair"] = (fd.t_first_afm < fd.t).astype("int8")
    est = fd[fd.period.isin([0, 2]) & (fd.pnrr == 0)]
    print("\n  Focal lots in P0+P2, non-PNRR (all values), by period:")
    tab = est.groupby("period").agg(lots=("cig", "size"), timing_fallback=("net_timing_fallback", "sum"),
                                    window_post2023=("window_post2023", "mean"),
                                    earlier_award_same_auth_month=("samemonth_auth", "mean"),
                                    earlier_award_same_pair_month=("samemonth_pair", "mean"))
    print(tab.to_string(float_format=lambda v: "%.4f" % v))
    print("  earlier_award_same_*_month = share of focal lots for which the authority (or the same\n"
          "  authority-winner pair) has an award in the same CPV2 earlier in the SAME calendar month;\n"
          "  those awards are outside the monthly-snapshot window by construction.")

    out_f = fd[["cig", "t", "tm", "net_timing_fallback", "window_post2023",
                "samemonth_auth", "samemonth_pair",
                "row_cpv2", "col_cpv2", "row_cpv3", "col_cpv3"]].rename(columns={
        "t": "net_t", "tm": "net_tm", "window_post2023": "net_window_post2023",
        "samemonth_auth": "net_samemonth_auth", "samemonth_pair": "net_samemonth_pair",
        "row_cpv2": "net_row_cpv2", "col_cpv2": "net_col_cpv2",
        "row_cpv3": "net_row_cpv3", "col_cpv3": "net_col_cpv3"})
    out_f["net_tm"] = out_f.net_tm.astype("float64")
    write_dta(out_f, P.inter_f("net_phase1_focal.dta"), labels={
        "net_t": "Focal event date (award_date, or pub_date if fallback), Stata days",
        "net_tm": "Focal month (Stata %tm)",
        "net_timing_fallback": "Focal lot has no plausible award_date: pub_date used",
        "net_window_post2023": "History window extends past 31dec2023",
        "net_samemonth_auth": "Authority has an earlier same-month award in CPV2",
        "net_samemonth_pair": "Same authority-winner pair has an earlier same-month award",
        "net_row_cpv2": "Row index (cpv2, authority) in snapshots",
        "net_col_cpv2": "Col index (cpv2, supplier) in snapshots",
        "net_row_cpv3": "Row index (cpv3, authority) in snapshots",
        "net_col_cpv3": "Col index (cpv3, supplier) in snapshots"})
    # edge event dates for later phases
    write_dta(e[["cig", "t", "tm", "timing_fallback", "row_cpv2", "col_cpv2", "row_cpv3", "col_cpv3"]]
              .assign(tm=lambda d: d.tm.astype("float64")),
              os.path.join(out, "edges_timed.dta"))
    log("Phase 1 finished")


if __name__ == "__main__":
    main()
