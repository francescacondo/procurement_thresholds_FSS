"""
net_phase2_classify.py -- Phase 2 of the network extension (Project D).

For each focal lot (lots_winners.dta) with winner f at authority a, within the
market (CPV2 main), five mutually exclusive and exhaustive indicators:
  net_incumbent   f won a's immediately preceding award in the same CPV3
                  (latest award of a in that CPV3 in the window; if several
                  awards share that date, any of their winners counts)
  net_prior_other f supplied a in the window, but is not the immediate incumbent
  net_indirect    f never supplied a in the window, but (A A' A)_af > 0: some
                  authority b bought from f and from one of a's suppliers
  net_outsider    f has >= 1 award with other authorities in the window, no path
  net_newobs      f has no award in the window (in this market)
and
  net_return_gap  f supplied a in the same CPV3 in the window, but did not win
                  the immediately preceding award ("skip a turn")
Versions (suffix): "" main = CPV2, 24m, day-level window [first day of m-24, t_i)
  _w12 12m | _base fixed pre-reform baseline | _cpv3 CPV3 markets
  _mo  monthly window [m-24, m) | _y24 history including 2024 publications

Before running at scale the code is run on a toy network with known answers,
and afterwards 500 random real lots are re-classified by brute force.
Output: data/intermediate/net_lot_measures.dta (1 row per cig of lots_winners).
"""
import os
import sys
import time

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(sys.argv[0])))  # Stata defines no __file__
from net_common import Paths, die, get_root, log, need, read_dta, write_dta, stata_to_ts
import net_netlib as NL

CLASSES = ["incumbent", "prior_other", "indirect", "outsider", "newobs"]
LABELS = {
    "incumbent": "Winner won a's immediately preceding award, same CPV3",
    "prior_other": "Winner supplied a in window, not immediate incumbent",
    "indirect": "Never supplied a; linked via (AA'A)_af > 0",
    "outsider": "Awards with other authorities, no path to a",
    "newobs": "Winner has no award in the window (market)",
    "return_gap": "Supplied a in same CPV3 before, not the immediate incumbent",
}
VERSION_TXT = {"": "CPV2, 24m, day-level", "_w12": "12m window", "_base": "fixed pre-reform baseline",
               "_cpv3": "CPV3 markets", "_mo": "monthly window (no same-month awards)",
               "_y24": "history incl. 2024 publications"}


def day(s):
    return float((pd.Timestamp(s) - pd.Timestamp("1960-01-01")).days)


def index_frames(edges, focal):
    """Row/col indices for a toy problem (same layout as Phase 1)."""
    shape = {}
    for mk in ("cpv2", "cpv3"):
        k = "mk_" + mk
        rows = pd.concat([edges[[k, "authority_id"]], focal[[k, "authority_id"]]]).drop_duplicates()
        rows = rows.sort_values([k, "authority_id"]).assign(**{"row_" + mk: lambda d: np.arange(len(d))})
        cols = pd.concat([edges[[k, "cf_key"]], focal[[k, "cf_key"]]]).drop_duplicates()
        cols = cols.sort_values([k, "cf_key"]).assign(**{"col_" + mk: lambda d: np.arange(len(d))})
        edges = edges.merge(rows, on=[k, "authority_id"]).merge(cols, on=[k, "cf_key"])
        focal = focal.merge(rows, on=[k, "authority_id"]).merge(cols, on=[k, "cf_key"])
        shape[mk] = (len(rows), len(cols))
    return edges, focal, shape


def prep(df):
    df = df.copy()
    df["t"] = df.date.map(day)
    df["tm"] = NL.tm_of(df.t)
    df["cpv2"] = df.cpv3.str[:2].astype(float)
    df["mk_cpv2"] = NL.market_key(df, "cpv2")
    df["mk_cpv3"] = NL.market_key(df, "cpv3")
    df["pub_year"] = 2019
    return df


def toy_test():
    """Toy network with answers derived by hand."""
    E = pd.DataFrame([
        ("e1", "a1", "f1", "331", "2019-01-10"), ("e2", "a1", "f2", "331", "2019-03-05"),
        ("e3", "a2", "f2", "332", "2019-02-01"), ("e4", "a2", "f3", "331", "2019-02-15"),
        ("e5", "a3", "f4", "331", "2019-02-20"), ("e6", "a1", "f5", "331", "2017-01-01"),
        ("e7", "a1", "f6", "332", "2019-06-03"), ("e8", "a1", "f7", "331", "2019-06-10"),
        ("e9", "a4", "f3", "451", "2019-01-01"), ("e10", "a4", "f8", "451", "2019-01-01"),
    ], columns=["cig", "authority_id", "cf_key", "cpv3", "date"])
    F = pd.DataFrame([
        ("F1", "a1", "f2", "331", "2019-06-10"), ("F2", "a1", "f1", "331", "2019-06-10"),
        ("F3", "a1", "f3", "331", "2019-06-10"), ("F4", "a1", "f4", "331", "2019-06-10"),
        ("F5", "a1", "f5", "331", "2019-06-10"), ("F6", "a1", "f7", "331", "2019-06-10"),
        ("F7", "a1", "f6", "332", "2019-06-10"), ("F8", "a1", "f7", "331", "2019-06-12"),
        ("F9", "a4", "f2", "451", "2019-06-10"), ("F10", "a4", "f3", "451", "2019-06-10"),
        ("F11", "a2", "f1", "331", "2019-06-10"),
    ], columns=["cig", "authority_id", "cf_key", "cpv3", "date"])
    expected = {
        "":    ["incumbent", "prior_other", "indirect", "outsider", "newobs", "newobs",
                "incumbent", "incumbent", "newobs", "incumbent", "indirect"],
        "_mo": ["incumbent", "prior_other", "indirect", "outsider", "newobs", "newobs",
                "newobs", "newobs", "newobs", "incumbent", "indirect"],
        "_w12": ["incumbent", "prior_other", "indirect", "outsider", "newobs", "newobs",
                 "incumbent", "incumbent", "newobs", "incumbent", "indirect"],
    }
    exp_rg = {"": [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0], "_mo": [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0],
              "_w12": [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]}
    E, F = prep(E), prep(F)
    E, F, shape = index_frames(E, F)
    F = F.set_index("cig").loc[["F%d" % i for i in range(1, 12)]].reset_index()
    snaps = NL.BuiltSnapshots(E, shape)
    ok = True
    for suf, exp in expected.items():
        out, _, chk = NL.classify(F, E, NL.SPECS[suf], snaps, shape)
        got = out[CLASSES].idxmax(axis=1).tolist()
        rg = out.return_gap.tolist()
        for i, (g, x) in enumerate(zip(got, exp)):
            flag = "" if g == x else "   <-- WRONG"
            ok &= g == x
            print("    toy %-4s %-4s got=%-11s expected=%-11s%s" % (suf or "main", F.cig[i], g, x, flag))
        ok &= rg == exp_rg[suf]
        ok &= all(v == 0 for v in chk.values())
        print("    toy %-4s return_gap=%s (expected %s) checks=%s" % (suf or "main", rg, exp_rg[suf], chk))
    if not ok:
        die("toy example failed")
    log("TOY TEST PASSED: all 33 classifications and return gaps match the hand-derived answers")


def brute(focal, edges, spec, n=500, seed=11):
    """Re-classify n random focal lots with plain Python sets (no matrices, no asof)."""
    f = NL.add_window(focal, spec).sample(n, random_state=seed)
    mk = spec[0]
    he = NL.history_edges(edges, spec)
    he = he[he["mk_" + mk] != ""]
    by_mkt = {k: g for k, g in he.groupby("mk_" + mk)}
    res = []
    for _, r in f.iterrows():
        g = by_mkt.get(r["mk_" + mk])
        w = g[(g.t >= r.s) & (g.t < r.q)] if g is not None else he.iloc[:0]
        supp_a = set(w.cf_key[w.authority_id == r.authority_id])
        buyers_f = set(w.authority_id[w.cf_key == r.cf_key])
        a3 = w[(w.authority_id == r.authority_id) & (w.cpv3 == r.cpv3)]
        inc = False
        if len(a3):
            inc = r.cf_key in set(a3.cf_key[a3.t == a3.t.max()])
        tie3 = r.cf_key in set(a3.cf_key)
        if r.cf_key in supp_a:
            c = "incumbent" if inc else "prior_other"
        elif not buyers_f:
            c = "newobs"
        else:
            path = any(len(supp_a & set(w.cf_key[w.authority_id == b])) > 0 for b in buyers_f)
            c = "indirect" if path else "outsider"
        res.append((r.name, c, int(tie3 and not inc)))
    return pd.DataFrame(res, columns=["idx", "cls", "rg"]).set_index("idx")


def main():
    P = Paths(get_root())
    snapdir = os.path.join(P.inter, "net_snapshots")
    log("Phase 2 | ROOT=" + P.root)
    log("toy example:")
    toy_test()

    # ----------------------------------------------------------------- data
    e = read_dta(need(P.inter_f("net_edges.dta")),
                 ["cig", "authority_id", "cf_key", "cpv2", "cpv3", "pub_year"])
    et = read_dta(need(os.path.join(snapdir, "edges_timed.dta")),
                  ["cig", "t", "tm", "row_cpv2", "col_cpv2", "row_cpv3", "col_cpv3"])
    e = e.merge(et, on="cig", validate="1:1")
    e = e[e.cf_key != ""]
    e["tm"] = e.tm.astype("int64")
    for mk in ("cpv2", "cpv3"):
        e["mk_" + mk] = NL.market_key(e, mk)
    f = read_dta(need(P.inter_f("net_lots_universe.dta")),
                 ["cig", "authority_id", "cf_key", "cpv2", "cpv3", "period", "pnrr",
                  "importo_lotto", "in_lots_winners"])
    f = f[f.in_lots_winners == 1].drop(columns="in_lots_winners")
    ft = read_dta(need(P.inter_f("net_phase1_focal.dta")),
                  ["cig", "net_t", "net_tm", "net_timing_fallback", "net_window_post2023",
                   "net_samemonth_auth", "net_samemonth_pair",
                   "net_row_cpv2", "net_col_cpv2", "net_row_cpv3", "net_col_cpv3"])
    f = f.merge(ft, on="cig", validate="1:1").rename(columns={
        "net_t": "t", "net_tm": "tm", "net_row_cpv2": "row_cpv2", "net_col_cpv2": "col_cpv2",
        "net_row_cpv3": "row_cpv3", "net_col_cpv3": "col_cpv3"})
    f["tm"] = f.tm.astype("int64")
    for mk in ("cpv2", "cpv3"):
        f["mk_" + mk] = NL.market_key(f, mk)
    f = f.reset_index(drop=True)
    shape = {}
    for mk in ("cpv2", "cpv3"):
        na = len(read_dta(os.path.join(snapdir, "idx_%s_auth.dta" % mk), ["row"]))
        ns = len(read_dta(os.path.join(snapdir, "idx_%s_sup.dta" % mk), ["col"]))
        shape[mk] = (na, ns)
    log("focal lots: %s | history edges: %s (published 2015-2023: %s)"
        % (format(len(f), ","), format(len(e), ","), format((e.pub_year <= 2023).sum(), ",")))
    snaps = NL.DiskSnapshots(snapdir)

    # ------------------------------------------------------------- versions
    out = f[["cig", "net_timing_fallback", "net_window_post2023",
             "net_samemonth_auth", "net_samemonth_pair"]].copy()
    labels = {"net_timing_fallback": "Focal lot has no plausible award_date: pub_date used",
              "net_window_post2023": "History window extends past 31dec2023",
              "net_samemonth_auth": "Authority has an earlier same-month award in CPV2",
              "net_samemonth_pair": "Same authority-winner pair: earlier same-month award"}
    for suf in NL.SPECS:
        t0 = time.time()
        spec = NL.SPECS[suf]
        cls, aux, chk = NL.classify(f, e, spec, snaps, shape)
        log("version %-5s (%s): %.0fs | checks %s" % (suf or "main", VERSION_TXT[suf], time.time() - t0, chk))
        if any(v != 0 for v in chk.values()):
            die("consistency check failed for version " + (suf or "main"))
        for c in CLASSES + ["return_gap"]:
            out["net_%s%s" % (c, suf)] = cls[c].values
            labels["net_%s%s" % (c, suf)] = (LABELS[c] if not suf else LABELS[c][:60] + " [" + suf[1:] + "]")
        if suf == "":
            out["net_class"] = (cls[CLASSES].values.argmax(axis=1) + 1).astype("int8")
            labels["net_class"] = "1 incumbent 2 prior_other 3 indirect 4 outsider 5 newobs"
            # brute-force re-classification of random real lots
            b = brute(f, e, spec)
            got = cls.loc[b.index, CLASSES].idxmax(axis=1)
            nbad = int((got != b.cls).sum() + (cls.loc[b.index, "return_gap"] != b.rg).sum())
            log("BRUTE FORCE: %d of %d random real lots classified identically (incl. return gap)"
                % (len(b) - int((got != b.cls).sum()), len(b)))
            if nbad:
                die("brute-force check failed for %d lots" % nbad)
        s = cls[CLASSES].sum(axis=1)
        log("  every lot classified exactly once: min=%d max=%d" % (s.min(), s.max()))

    write_dta(out, P.inter_f("net_lot_measures.dta"), labels=labels)

    # --------------------------------------------------------- diagnostics
    d = out.merge(f[["cig", "period", "pnrr", "importo_lotto"]], on="cig")
    d["x"] = d.importo_lotto - 139000
    est = d[d.period.isin([0, 2]) & (d.pnrr == 0) & (d.x.abs() <= 40000)].copy()
    est["cell"] = np.where(est.period == 0, "P0", "P2") + np.where(est.x < 0, " below", " above")
    pd.set_option("display.width", 220)
    print("\n  Shares in the estimation window (main_sample, |x| <= 40k), main version:")
    t = est.groupby("cell")[["net_" + c for c in CLASSES + ["return_gap"]]].mean()
    t.insert(0, "lots", est.groupby("cell").size())
    print(t.to_string(float_format=lambda v: "%.4f" % v))
    print("\n  Raw diff-in-diff of cell means, (P2 below - P2 above) - (P0 below - P0 above), no slope / FE:")
    for c in CLASSES + ["return_gap"]:
        v = t["net_" + c]
        print("    %-12s %+.4f" % (c, (v["P2 below"] - v["P2 above"]) - (v["P0 below"] - v["P0 above"])))
    print("\n  Shares by version (estimation window, all cells pooled):")
    rows = []
    for suf in NL.SPECS:
        rows.append([suf or "main"] + [est["net_%s%s" % (c, suf)].mean() for c in CLASSES + ["return_gap"]])
    print(pd.DataFrame(rows, columns=["version"] + CLASSES + ["return_gap"]).to_string(
        index=False, float_format=lambda v: "%.4f" % v))
    t.to_csv(os.path.join(P.tables, "net_p2_shares_by_cell.csv"))
    log("Phase 2 finished")


if __name__ == "__main__":
    main()
