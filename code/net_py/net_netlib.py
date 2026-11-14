"""
net_netlib.py -- window logic shared by Phases 2 and 3.

A "spec" (network version) fixes: market (cpv2/cpv3), window length W, which
edges form the history, whether same-month earlier awards are added
(day-level window), and whether the fixed pre-reform baseline is used.

Window of focal lot i (event date t_i, month m_i):
  rolling, day-level (main) : [first day of m_i - W, t_i)
  rolling, monthly (_mo)    : [first day of m_i - W, first day of m_i)
  baseline (_base)          : focal months >= 2020m8: [17jul2018, 17jul2020)
                              earlier focal months: rolling day-level, W = 24
All bounds are exclusive at the top, so history is STRICTLY before t_i.

The matrix side uses the Phase 1 snapshots A_m (awards in [m-W, m)) and adds,
day by day, the awards of month m dated before the focal day.
"""
import os

import numpy as np
import pandas as pd
import scipy.sparse as sp

from net_common import stata_to_ts

BASE_START = 21382      # 17jul2018 (Stata days)
BASE_END = 22113        # 17jul2020, exclusive
BASE_FIRST_TM = 727     # 2020m8

SPECS = {
    # suffix:  market  W   history     day-level  baseline  snapshot version
    "":      ("cpv2", 24, "main",     True,  False, "w24_cpv2"),
    "_w12":  ("cpv2", 12, "main",     True,  False, "w12_cpv2"),
    "_base": ("cpv2", 24, "main",     True,  True,  "w24_cpv2"),
    "_cpv3": ("cpv3", 24, "main",     True,  False, "w24_cpv3"),
    "_mo":   ("cpv2", 24, "main",     False, False, "w24_cpv2"),
    "_y24":  ("cpv2", 24, "with2024", True,  False, "w24_cpv2_y24"),
}


DAY_2000, DAY_2026 = 14610, 24471          # 01jan2000, 31dec2026


def event_date(df):
    """Same rule as Phase 1: award_date if in 2000-2026 and not more than 365 days
    before pub_date, else pub_date (fallback flag = 1)."""
    ok = df.award_date.between(DAY_2000, DAY_2026) & (df.award_date >= df.pub_date - 365)
    t = np.where(ok, df.award_date, df.pub_date)
    return pd.Series(t, index=df.index, dtype="float64"), (~ok).astype("int8")


def tm_of(days):
    ts = stata_to_ts(days)
    return ((ts.dt.year - 1960) * 12 + ts.dt.month - 1).astype("int64")


def market_key(df, market):
    if market == "cpv2":
        return df.cpv2.map(lambda v: "" if pd.isna(v) else "%02d" % int(v))
    k = df.cpv3.astype(str)
    return k.where(k.str.fullmatch(r"\d{3}"), "")


def first_day_of_tm(tm):
    """Stata %tm -> Stata day of the first day of that month."""
    tm = np.asarray(tm, dtype=np.int64)
    y, mo = 1960 + tm // 12, tm % 12 + 1
    ts = pd.to_datetime(pd.DataFrame({"year": y, "month": mo, "day": 1}))
    return (ts - pd.Timestamp("1960-01-01")).dt.days.values.astype("float64")


def add_window(focal, spec):
    """Adds s (window start, inclusive), q (window end, exclusive), is_base."""
    mk, W, hist, daylevel, base, snap = spec
    f = focal.copy()
    f["s"] = first_day_of_tm(f.tm.values - W)
    f["q"] = f.t.values if daylevel else first_day_of_tm(f.tm.values)
    f["is_base"] = False
    if base:
        late = f.tm >= BASE_FIRST_TM
        f.loc[late, "s"] = BASE_START
        f.loc[late, "q"] = BASE_END
        f["is_base"] = late
    return f


def history_edges(edges, spec):
    return edges if spec[2] == "with2024" else edges[edges.pub_year <= 2023]


def counts(rows, cols, shape):
    A = sp.coo_matrix((np.ones(len(rows), dtype=np.int32),
                       (np.asarray(rows, dtype=np.int64), np.asarray(cols, dtype=np.int64))),
                      shape=shape).tocsr()
    A.sum_duplicates()
    return A


class DiskSnapshots:
    """Phase 1 snapshots read from data/intermediate/net_snapshots/."""

    def __init__(self, snapdir):
        self.dir = snapdir
        self._cache = {}

    def month(self, spec, m):
        v = spec[5]
        key = (v, m)
        if key not in self._cache:
            if len(self._cache) > 4:
                self._cache.clear()
            self._cache[key] = sp.load_npz(os.path.join(self.dir, v, "m%d.npz" % m))
        return self._cache[key]

    def base(self, spec):
        return sp.load_npz(os.path.join(self.dir, "base_%s.npz" % spec[0]))


class BuiltSnapshots:
    """Same windows built on the fly from an edge list (used for the toy test)."""

    def __init__(self, edges, shape):
        self.e, self.shape = edges, shape

    def month(self, spec, m):
        mk, W = spec[0], spec[1]
        e = history_edges(self.e, spec)
        e = e[(e.tm >= m - W) & (e.tm < m)]
        return counts(e["row_" + mk], e["col_" + mk], self.shape[mk])

    def base(self, spec):
        mk = spec[0]
        e = history_edges(self.e, spec)
        e = e[(e.t >= BASE_START) & (e.t < BASE_END)]
        return counts(e["row_" + mk], e["col_" + mk], self.shape[mk])


def binary(A):
    B = A.tocsr(copy=True)
    B.data[:] = 1
    B.eliminate_zeros()
    return B


def matrix_pass(focal, edges, spec, snaps, shape, extra=None):
    """For every focal lot (already passed through add_window), compute from the
    window network B (binary, market block-diagonal):
        direct : B[a, f] > 0                 (f supplied a in the window)
        deg    : distinct authorities supplied by f in the window (column nnz)
        path   : (B B' B)[a, f] > 0, computed only where direct == 0 and deg > 0
    `extra(B, sub, A)` (A = award counts) may return a DataFrame of further per-lot measures (Phase 3).
    Returns a DataFrame indexed like `focal`."""
    mk, W, hist, daylevel, base, snap = spec
    rcol, ccol = "row_" + mk, "col_" + mk
    he = history_edges(edges, spec)
    he = he[he[rcol].notna()]
    out = []

    def measure(B, sub, A):
        r = sub[rcol].astype(np.int64).values
        c = sub[ccol].astype(np.int64).values
        direct = np.asarray(B[r, c]).ravel() > 0
        Bc = B.tocsc()
        deg = np.diff(Bc.indptr)[c]
        path = np.zeros(len(sub), dtype=bool)
        need = (~direct) & (deg > 0)
        if need.any():
            X = B[r[need], :] @ B.T                 # co-supply counts: a_i with every b
            Y = Bc[:, c[need]].T.tocsr()             # Y[i, b] = B[b, f_i]
            path[need] = np.asarray(X.multiply(Y).sum(axis=1)).ravel() > 0
        res = pd.DataFrame({"direct": direct, "deg": deg, "path": path}, index=sub.index)
        if extra is not None:
            res = res.join(extra(B, sub, A))
        return res

    if base:
        late = focal[focal.is_base]
        if len(late):
            Ab = snaps.base(spec)
            out.append(measure(binary(Ab), late, Ab))
        focal = focal[~focal.is_base]
    he = he.sort_values("t")
    for m, fm in focal.groupby("tm", sort=True):
        m = int(m)
        A_m = snaps.month(spec, m)
        if not daylevel:
            out.append(measure(binary(A_m), fm, A_m))
            continue
        D = he[he.tm == m]
        dt = D.t.values
        for d, fd in fm.groupby("q", sort=True):
            k = np.searchsorted(dt, d, "left")       # month-m awards strictly before day d
            A = A_m if k == 0 else A_m + counts(D[rcol].values[:k], D[ccol].values[:k], A_m.shape)
            out.append(measure(binary(A), fd, A))
    return pd.concat(out)


def sequence_pass(focal, edges, spec):
    """Award-sequence measures (no matrices), using the same window [s, q):
        incumbent     : f is among the winners of a's latest award in the same
                        CPV3 dated in [s, q)  (ties on that date: any winner counts)
        tie_cpv3      : f supplied a in the same CPV3 in [s, q)
        direct_seq    : f supplied a in the same market in [s, q)  (cross-check)
    Uses merge_asof with strict inequality (allow_exact_matches=False)."""
    mk = spec[0]
    he = history_edges(edges, spec)
    he = he[(he["mk_" + mk] != "") & (he.cpv3 != "")]
    left = focal[["authority_id", "cpv3", "mk_" + mk, "cf_key", "s", "q"]].copy()
    left["_i"] = np.arange(len(left))
    left = left.sort_values("q")

    last = (he.groupby(["authority_id", "cpv3", "t"]).cf_key.agg(lambda x: frozenset(x))
            .rename("winners").reset_index().sort_values("t"))
    r1 = pd.merge_asof(left, last, left_on="q", right_on="t", by=["authority_id", "cpv3"],
                       allow_exact_matches=False, direction="backward")
    inc = (r1.t >= r1.s) & np.array([cf in w if isinstance(w, frozenset) else False
                                     for cf, w in zip(r1.cf_key, r1.winners)])

    pair3 = he[["authority_id", "cpv3", "cf_key", "t"]].drop_duplicates().sort_values("t")
    r2 = pd.merge_asof(left, pair3, left_on="q", right_on="t", by=["authority_id", "cpv3", "cf_key"],
                       allow_exact_matches=False, direction="backward")
    pairm = he[["authority_id", "mk_" + mk, "cf_key", "t"]].drop_duplicates().sort_values("t")
    r3 = pd.merge_asof(left, pairm, left_on="q", right_on="t", by=["authority_id", "mk_" + mk, "cf_key"],
                       allow_exact_matches=False, direction="backward")
    res = pd.DataFrame({"_i": r1._i.values, "incumbent": inc.values,
                        "tie_cpv3": (r2.t >= r2.s).values, "direct_seq": (r3.t >= r3.s).values})
    res = res.sort_values("_i")
    res.index = focal.index
    return res.drop(columns="_i")


def classify(focal, edges, spec, snaps, shape, extra=None):
    """Five mutually exclusive indicators + return gap for one network version."""
    f = add_window(focal, spec)
    mres = matrix_pass(f, edges, spec, snaps, shape, extra=extra).loc[f.index]
    sres = sequence_pass(f, edges, spec)
    r = mres.join(sres)
    out = pd.DataFrame(index=f.index)
    out["incumbent"] = r.incumbent
    out["prior_other"] = r.direct & ~r.incumbent
    out["indirect"] = ~r.direct & r.path
    out["outsider"] = ~r.direct & ~r.path & (r.deg > 0)
    out["newobs"] = ~r.direct & (r.deg == 0)
    out["return_gap"] = r.tie_cpv3 & ~r.incumbent
    checks = {
        "incumbent_without_direct_tie": int((r.incumbent & ~r.direct).sum()),
        "matrix_vs_sequence_direct_mismatch": int((r.direct != r.direct_seq).sum()),
        "rows_not_summing_to_1": int((out[["incumbent", "prior_other", "indirect", "outsider",
                                            "newobs"]].sum(axis=1) != 1).sum()),
    }
    extra_cols = [c for c in r.columns if c not in ("direct", "deg", "path", "incumbent",
                                                   "tie_cpv3", "direct_seq")]
    return out.astype("int8"), r[["deg", "direct"] + extra_cols], checks
