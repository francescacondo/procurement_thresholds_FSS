"""
net_phase3_centrality.py -- Phase 3 of the network extension (Project D).

Historical centrality of the focal winner f, within CPV2, in the main window
(24 months, day-level: [first day of m-24, t_i)); never uses awards dated on or
after the focal award.
  net_deg_hist       distinct authorities supplied by f in the window
  net_ldeg_hist      log(1 + net_deg_hist)
  net_regions_hist   distinct regions served by f in the window (region of an
                     authority = its most frequent sezione_regionale)
  net_core           net_deg_hist strictly above the 90th percentile of the
                     degree distribution of ACTIVE suppliers (degree >= 1) in
                     the same CPV2 and window (strict, so ties at low degrees
                     cannot make most suppliers "core")
  net_other_auth     distinct authorities other than a supplied by f
  net_deg_excess     NOT BUILT: under the Bipartite Configuration Model the
                     expected degree of every node equals its observed degree
                     (that is the model's constraint), so observed - expected
                     is 0 by construction. Demonstrated numerically below with
                     the bicm package.
  net_deg_excess_alloc  PROPOSED replacement (not in the task; for the group to
                     accept or drop): observed degree minus the number of
                     distinct authorities f would have if its s_f awards in the
                     window were allocated at random in proportion to each
                     authority's share w_a of awards in the market window:
                     E = sum_a [1 - (1 - w_a)^s_f]. Negative = f's contracts are
                     concentrated on fewer buyers than chance (captive supplier).
Adds these variables to data/intermediate/net_lot_measures.dta.
"""
import os
import sys
import time

import numpy as np
import pandas as pd
import scipy.sparse as sp

sys.path.insert(0, os.path.dirname(os.path.abspath(sys.argv[0])))  # Stata defines no __file__
from net_common import Paths, die, get_root, log, need, read_dta, write_dta
import net_netlib as NL

P3_VARS = ["net_deg_hist", "net_ldeg_hist", "net_regions_hist", "net_core",
           "net_other_auth", "net_deg_excess_alloc", "net_core_threshold"]


def load(P, snapdir):
    e = read_dta(need(P.inter_f("net_edges.dta")),
                 ["cig", "authority_id", "cf_key", "cpv2", "cpv3", "pub_year", "region"])
    et = read_dta(need(os.path.join(snapdir, "edges_timed.dta")),
                  ["cig", "t", "tm", "row_cpv2", "col_cpv2", "row_cpv3", "col_cpv3"])
    e = e.merge(et, on="cig", validate="1:1")
    e = e[e.cf_key != ""].copy()
    e["tm"] = e.tm.astype("int64")
    for mk in ("cpv2", "cpv3"):
        e["mk_" + mk] = NL.market_key(e, mk)
    f = read_dta(need(P.inter_f("net_lots_universe.dta")),
                 ["cig", "authority_id", "cf_key", "cpv2", "cpv3", "period", "pnrr",
                  "importo_lotto", "in_lots_winners"])
    f = f[f.in_lots_winners == 1].drop(columns="in_lots_winners")
    ft = read_dta(need(P.inter_f("net_phase1_focal.dta")),
                  ["cig", "net_t", "net_tm", "net_row_cpv2", "net_col_cpv2", "net_row_cpv3", "net_col_cpv3"])
    f = f.merge(ft, on="cig", validate="1:1").rename(columns={
        "net_t": "t", "net_tm": "tm", "net_row_cpv2": "row_cpv2", "net_col_cpv2": "col_cpv2",
        "net_row_cpv3": "row_cpv3", "net_col_cpv3": "col_cpv3"})
    f["tm"] = f.tm.astype("int64")
    for mk in ("cpv2", "cpv3"):
        f["mk_" + mk] = NL.market_key(f, mk)
    return e, f.reset_index(drop=True)


def bicm_demo(snapdir, idx_auth, idx_sup):
    """Fit the BiCM on one real market snapshot and compare expected with observed
    supplier degrees. Under the BiCM they coincide up to solver tolerance."""
    try:
        from bicm import BipartiteGraph
    except ImportError:
        log("bicm not importable: BiCM demonstration skipped (net_deg_excess not built either way)")
        return
    tm, mkt = 713, "79"                                   # 2019m6, CPV 79 (business services)
    A = NL.binary(sp.load_npz(os.path.join(snapdir, "w24_cpv2", "m%d.npz" % tm)))
    r = idx_auth.index[idx_auth.market == mkt].values
    c = idx_sup.index[idx_sup.market == mkt].values
    M = A[r][:, c]
    M = M[M.getnnz(axis=1) > 0][:, M.getnnz(axis=0) > 0]
    log("BiCM demonstration: market CPV2=%s, snapshot 2019m6, %d authorities x %d suppliers, %d links"
        % (mkt, M.shape[0], M.shape[1], M.nnz))
    import warnings
    warnings.filterwarnings("ignore", module="numba")
    warnings.filterwarnings("ignore", module="bicm")
    g = BipartiteGraph(biadjacency=M.toarray())
    g.solve_tool(method="newton", print_error=False)
    pmat = np.asarray(g.get_bicm_matrix())          # p_af, same layout as M
    kobs = np.asarray(M.sum(axis=0)).ravel()
    kexp = pmat.sum(axis=0)
    log("  supplier degrees: observed mean %.4f | BiCM expected mean %.4f | max |observed - expected| = %.2e"
        % (kobs.mean(), kexp.mean(), np.abs(kobs - kexp).max()))
    log("  => observed minus BiCM-expected degree is 0 up to solver tolerance; net_deg_excess is not built")


def main():
    P = Paths(get_root())
    snapdir = os.path.join(P.inter, "net_snapshots")
    log("Phase 3 | ROOT=" + P.root)
    e, f = load(P, snapdir)
    idx_auth = read_dta(os.path.join(snapdir, "idx_cpv2_auth.dta"), ["market", "authority_id", "row"]).set_index("row").sort_index()
    idx_sup = read_dta(os.path.join(snapdir, "idx_cpv2_sup.dta"), ["market", "cf_key", "col"]).set_index("col").sort_index()
    shape = {"cpv2": (len(idx_auth), len(idx_sup)),
             "cpv3": (len(read_dta(os.path.join(snapdir, "idx_cpv3_auth.dta"), ["row"])),
                      len(read_dta(os.path.join(snapdir, "idx_cpv3_sup.dta"), ["col"])))}

    # region of each authority = most frequent sezione_regionale over its lots
    u = read_dta(need(P.inter_f("net_lots_universe.dta")), ["authority_id", "region"])
    u = u[u.region != ""]
    modal = u.groupby(["authority_id", "region"]).size().rename("n").reset_index()
    modal = modal.sort_values(["authority_id", "n", "region"], ascending=[True, False, True]).drop_duplicates("authority_id")
    n_multi = (u.groupby("authority_id").region.nunique() > 1).sum()
    log("authorities with >1 region across lots: %d (modal region used)" % n_multi)
    regs = sorted(modal.region.unique())
    rcode = dict(zip(regs, range(len(regs))))
    row_reg = idx_auth.authority_id.map(dict(zip(modal.authority_id, modal.region.map(rcode))))
    has_reg = row_reg.notna().values
    Mreg = sp.csr_matrix((np.ones(has_reg.sum()), (np.where(has_reg)[0], row_reg[has_reg].astype(int).values)),
                         shape=(len(idx_auth), len(regs)))
    col_mkt = pd.Categorical(idx_sup.market).codes
    row_mkt = pd.Categorical(idx_auth.market, categories=pd.Categorical(idx_sup.market).categories).codes
    n_mkt = col_mkt.max() + 1

    def extra(B, sub, A):
        r = sub.row_cpv2.astype(np.int64).values
        c = sub.col_cpv2.astype(np.int64).values
        BT = B.T.tocsr()
        # regions served by f
        regions = (BT[c] @ Mreg).getnnz(axis=1)
        # core: strictly above the 90th percentile of active-supplier degree, same market and window
        deg_all = np.diff(B.tocsc().indptr)
        act = np.where(deg_all > 0)[0]
        q90 = pd.Series(deg_all[act]).groupby(col_mkt[act]).quantile(0.9)
        thr = q90.reindex(col_mkt[c]).values
        # allocation benchmark: expected distinct buyers if f's s_f awards were spread
        # across authorities in proportion to their award shares in the market window
        rowsum = np.asarray(A.sum(axis=1)).ravel().astype(float)
        tot = np.bincount(row_mkt, weights=rowsum, minlength=n_mkt)
        s_f = np.asarray(A.T.tocsr()[c].sum(axis=1)).ravel()
        exp_k = np.zeros(len(sub))
        mk_c = col_mkt[c]
        for mcode in np.unique(mk_c[s_f > 0]):
            rows_m = np.where((row_mkt == mcode) & (rowsum > 0))[0]
            w = rowsum[rows_m] / tot[mcode]
            sel = np.where((mk_c == mcode) & (s_f > 0))[0]
            for sv in np.unique(s_f[sel]):
                exp_k[sel[s_f[sel] == sv]] = np.sum(1.0 - (1.0 - w) ** sv)
        return pd.DataFrame({"regions": regions, "core_thr": thr, "s_f": s_f, "exp_k": exp_k},
                            index=sub.index)

    t0 = time.time()
    spec = NL.SPECS[""]
    _, aux, chk0 = NL.classify(f, e, spec, NL.DiskSnapshots(snapdir), shape, extra=extra)
    aux = aux.loc[f.index]
    log("window measures computed in %.0fs | consistency checks %s" % (time.time() - t0, chk0))
    out = pd.DataFrame({"cig": f.cig})
    out["net_deg_hist"] = aux.deg.values.astype("int32")
    out["net_ldeg_hist"] = np.log1p(out.net_deg_hist)
    out["net_regions_hist"] = aux.regions.values.astype("int16")
    out["net_core_threshold"] = aux.core_thr.values
    out["net_core"] = ((out.net_deg_hist > out.net_core_threshold.fillna(np.inf))).astype("int8")
    out["net_other_auth"] = (out.net_deg_hist - aux.direct.values.astype(int)).astype("int32")
    out["net_deg_excess_alloc"] = np.where(aux.s_f.values > 0, out.net_deg_hist - aux.exp_k.values, np.nan)

    # ---------------------------------------------------------- checks
    meas = read_dta(need(P.inter_f("net_lot_measures.dta")), ["cig", "net_newobs", "net_prior_other", "net_incumbent"])
    chk = out.merge(meas, on="cig", validate="1:1")
    bad1 = int(((chk.net_deg_hist == 0) != (chk.net_newobs == 1)).sum())
    bad2 = int(((chk.net_other_auth == chk.net_deg_hist - 1) != ((chk.net_prior_other + chk.net_incumbent) == 1)).sum())
    log("CHECK newobs == (deg_hist == 0): %d mismatches | other_auth == deg-1 iff direct tie: %d mismatches" % (bad1, bad2))
    # brute force on random lots: plain pandas, no matrices
    smp = NL.add_window(f, spec).sample(300, random_state=3)
    he = NL.history_edges(e, spec)
    he = he.assign(reg=he.authority_id.map(dict(zip(modal.authority_id, modal.region))))
    by_mkt = {k: g for k, g in he.groupby("mk_cpv2")}
    nb = 0
    for i, r in smp.iterrows():
        g = by_mkt[r.mk_cpv2]
        w = g[(g.t >= r.s) & (g.t < r.q)]
        wf = w[w.cf_key == r.cf_key]
        deg = wf.authority_id.nunique()
        nreg = wf.reg.dropna().nunique()
        oth = wf.authority_id[wf.authority_id != r.authority_id].nunique()
        wa = w.groupby("authority_id").size() / len(w) if len(w) else pd.Series(dtype=float)
        ek = float(np.sum(1 - (1 - wa.values) ** len(wf))) if len(wf) else np.nan
        o = out.loc[i]
        ok = (deg == o.net_deg_hist and nreg == o.net_regions_hist and oth == o.net_other_auth
              and (np.isnan(ek) and np.isnan(o.net_deg_excess_alloc)
                   or abs((deg - ek) - o.net_deg_excess_alloc) < 1e-6))
        nb += int(not ok)
    log("BRUTE FORCE: %d of %d random lots identical (deg, regions, other_auth, deg_excess_alloc)" % (300 - nb, 300))
    if bad1 or bad2 or nb or any(v != 0 for v in chk0.values()):
        die("Phase 3 checks failed")

    bicm_demo(snapdir, idx_auth, idx_sup)

    # ---------------------------------------------------------- write
    meas_all = pd.read_stata(P.inter_f("net_lot_measures.dta"), convert_dates=False,
                             preserve_dtypes=True)
    labels_old = pd.io.stata.StataReader(P.inter_f("net_lot_measures.dta")).variable_labels()
    meas_all = meas_all.drop(columns=[c for c in P3_VARS if c in meas_all.columns])
    meas_all["cig"] = meas_all.cig.astype(str)
    new = meas_all.merge(out, on="cig", how="left", validate="1:1")
    assert new[P3_VARS[:5]].notna().all().all()
    labels = {k: v for k, v in labels_old.items() if k in new.columns}
    labels.update({
        "net_deg_hist": "Distinct authorities supplied by winner, CPV2, 24m window",
        "net_ldeg_hist": "log(1 + net_deg_hist)",
        "net_regions_hist": "Distinct regions served by winner, CPV2, 24m window",
        "net_core": "Winner degree > p90 of active suppliers, CPV2 x window",
        "net_core_threshold": "p90 of active-supplier degree, CPV2 x window",
        "net_other_auth": "Distinct authorities other than a supplied by winner",
        "net_deg_excess_alloc": "PROPOSED: degree minus expected under random allocation"})
    write_dta(new, P.inter_f("net_lot_measures.dta"), labels=labels)

    # ---------------------------------------------------------- diagnostics
    d = out.merge(f[["cig", "period", "pnrr", "importo_lotto"]], on="cig")
    d["x"] = d.importo_lotto - 139000
    est = d[d.period.isin([0, 2]) & (d.pnrr == 0) & (d.x.abs() <= 40000)].copy()
    est["cell"] = np.where(est.period == 0, "P0", "P2") + np.where(est.x < 0, " below", " above")
    cols = ["net_deg_hist", "net_ldeg_hist", "net_regions_hist", "net_core", "net_other_auth", "net_deg_excess_alloc"]
    t = est.groupby("cell")[cols].mean()
    t.insert(0, "lots", est.groupby("cell").size())
    pd.set_option("display.width", 220)
    print("\n  Means in the estimation window (main_sample, |x| <= 40k):")
    print(t.to_string(float_format=lambda v: "%.4f" % v))
    print("\n  net_deg_hist distribution (estimation window): " +
          est.net_deg_hist.describe(percentiles=[.25, .5, .75, .9, .99]).round(2).to_dict().__repr__())
    print("  share core among lots with deg>=1: %.4f | median core threshold: %.1f"
          % (est.net_core[est.net_deg_hist > 0].mean(), est.net_core_threshold.median()))
    t.to_csv(os.path.join(P.tables, "net_p3_means_by_cell.csv"))
    log("Phase 3 finished")


if __name__ == "__main__":
    main()
