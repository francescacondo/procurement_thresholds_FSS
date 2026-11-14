"""
net_phase0_data.py -- Phase 0 of the network extension (Project D).

Usage (from net_master.do):
    python script "$ROOT/code/net_py/net_phase0_data.py", args("$ROOT")
Optional second argument: comma-separated steps, e.g. "download,build,diag"
(default: all three).

STEP download : fetch CIG monthly files for 2015 and 2024 and the
                "partecipanti" dataset from the ANAC open-data portal into
                data/raw/ (only files that are not already there; never
                overwrites). If the portal rejects a request, stop and list
                the files to download by hand.
STEP build    : re-apply the cleaning rules of full_analysis_commented.do
                (section 1.1-1.4) to the CIG files 2015-2024, check that the
                2018-2023 part reproduces lots_v2.dta exactly, merge awards and
                winners with the same de-duplication rules, and write
                  net_lots_universe.dta      (1 row per cleaned lot, 2015-2024)
                  net_edges.dta              (1 row per award-matched lot with
                                              one matched winner, all periods)
                  net_aggiudicatari_allroles.dta (all roles, for consortia)
                  net_partecipanti.dta       (participants of universe lots)
STEP diag     : Phase 0 diagnostics (tables in results/tables/net_p0_*.csv).
"""
import io
import os
import re
import sys
import time
import zipfile
import urllib.request

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(sys.argv[0])))  # Stata defines no __file__
from net_common import (Paths, die, get_root, log, need, read_dta, write_dta,
                        stata_to_ts)

BASE = "https://dati.anticorruzione.it/opendata/download/dataset"
HIST_YEARS = list(range(2015, 2025))      # publication years in the history universe
NEW_CIG_YEARS = (2015, 2024)              # years not yet in data/raw/

D_P1 = pd.Timestamp("2020-07-17")
D_P2 = pd.Timestamp("2021-06-01")
D_P3 = pd.Timestamp("2023-07-01")


# =============================================================================
# STEP 1: DOWNLOAD
# =============================================================================
def fetch(url, dest):
    """Download url -> dest. Returns None on success, else an error string.
    A response that is not a zip (e.g. the portal's 'Request Rejected' HTML
    page) counts as a block: we do NOT retry or try to get around it."""
    tmp = dest + ".part"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Bocconi-FSS-research (urllib)"})
        with urllib.request.urlopen(req, timeout=600) as r, open(tmp, "wb") as f:
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
    except Exception as e:  # noqa: BLE001
        if os.path.exists(tmp):
            os.remove(tmp)
        return "request failed: " + repr(e)
    with open(tmp, "rb") as f:
        head = f.read(4)
    if head[:2] != b"PK":
        with open(tmp, "rb") as f:
            snippet = f.read(300).decode("latin-1", "replace").replace("\n", " ")
        os.remove(tmp)
        return "not a zip (portal returned: " + snippet[:160] + ")"
    os.replace(tmp, dest)
    return None


def extract(zpath, want_csv, raw_dir):
    """Extract the single csv inside zpath to raw_dir/want_csv (if missing)."""
    out = os.path.join(raw_dir, want_csv)
    if os.path.exists(out):
        return out
    with zipfile.ZipFile(zpath) as z:
        names = [n for n in z.namelist() if n.lower().endswith(".csv")]
        if len(names) != 1:
            die("unexpected content in " + zpath + ": " + str(z.namelist()))
        with z.open(names[0]) as src, open(out + ".part", "wb") as dst:
            while True:
                b = src.read(1 << 22)
                if not b:
                    break
                dst.write(b)
    os.replace(out + ".part", out)
    return out


def step_download(P):
    log("=== STEP download ===")
    jobs = []
    for y in NEW_CIG_YEARS:
        for m in range(1, 13):
            jobs.append((BASE + "/cig-%d/filesystem/cig_csv_%d_%02d.zip" % (y, y, m),
                         "cig_%d_%02d.zip" % (y, m), "cig_csv_%d_%02d.csv" % (y, m)))
    jobs.append((BASE + "/partecipanti/filesystem/partecipanti_csv.zip",
                 "partecipanti_csv.zip", "partecipanti_csv.csv"))
    failed = []
    for url, zname, cname in jobs:
        zpath = P.raw_f(zname)
        if os.path.exists(P.raw_f(cname)) or os.path.exists(zpath):
            log("  exists: " + zname)
        else:
            log("  downloading " + zname)
            err = fetch(url, zpath)
            if err:
                log("  FAILED " + zname + ": " + err)
                failed.append((url, zname, err))
                if "not a zip" in err or "403" in err:
                    break          # blocked: stop immediately, do not hammer the portal
                continue
            time.sleep(2)          # be polite to the portal
        extract(zpath, cname, P.raw)
        log("  ok: " + cname + " (" + format(os.path.getsize(P.raw_f(cname)) // 1024, ",") + " KB)")
    if failed:
        print("\nThe portal blocked or failed these requests. Download them by hand into data/raw/:")
        for url, zname, err in failed:
            print("   " + url + "   ->  data/raw/" + zname)
        done = {z for _, z, _ in failed}
        rest = [(u, z) for u, z, _ in jobs if not os.path.exists(P.raw_f(z)) and z not in done]
        for u, z in rest:
            print("   " + u + "   ->  data/raw/" + z)
        die("download blocked; see the list above")


# =============================================================================
# STEP 2: BUILD (replicates full_analysis_commented.do sections 1.1-1.4, 1.8, 5.1)
# =============================================================================
CIG_COLS = ["cig", "cig_accordo_quadro", "oggetto_principale_contratto", "settore",
            "importo_lotto", "data_pubblicazione", "tipo_scelta_contraente",
            "sezione_regionale", "cod_cpv", "codice_ausa",
            "cf_amministrazione_appaltante", "stato", "flag_pnrr_pnc"]
WINNER_ROLES = ["", "MANDATARIA", "Mandataria", "OPERATORE ECONOMICO MONOSOGGETTIVO",
                "Operatore Economico monosoggettivo"]


def days_from_civil(y, m, d):
    """Vectorised proleptic-Gregorian date -> days since 1960-01-01 (Stata %td).
    Works for any year (pandas Timestamps cannot hold years < 1677)."""
    y = y - (m <= 2)
    era = np.floor_divide(y, 400)
    yoe = y - era * 400
    mp = (m + 9) % 12
    doy = (153 * mp + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468 - (-3653)   # 1970-01-01 is Stata day 3653


def parse_ymd(s):
    """Mimic Stata date(s, "YMD") for 'YYYY-MM-DD' strings -> float day count
    (NaN if empty/invalid, or year < 100 which Stata's date() does not accept)."""
    s = pd.Series(s, dtype=str).str.strip()
    parts = s.str.extract(r"^(\d{1,4})-(\d{1,2})-(\d{1,2})")
    y = pd.to_numeric(parts[0], errors="coerce")
    m = pd.to_numeric(parts[1], errors="coerce")
    d = pd.to_numeric(parts[2], errors="coerce")
    ok = y.notna() & m.between(1, 12) & d.between(1, 31) & (y >= 100)
    out = pd.Series(np.nan, index=s.index)
    yy, mm, dd = y[ok].astype(int).values, m[ok].astype(int).values, d[ok].astype(int).values
    leap = ((yy % 4 == 0) & (yy % 100 != 0)) | (yy % 400 == 0)
    mdays = np.array([31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31])[mm - 1] + ((mm == 2) & leap)
    valid = dd <= mdays
    vals = np.where(valid, days_from_civil(yy, mm, dd), np.nan)
    out.loc[ok] = vals
    return out


def read_cig_month(P, y, m):
    f = P.raw_f("cig_csv_%d_%02d.csv" % (y, m))
    if not os.path.exists(f):
        die("missing CIG file " + f + " (run the download step)")
    df = pd.read_csv(f, sep=";", dtype=str, keep_default_na=False, encoding="utf-8",
                     encoding_errors="replace", usecols=lambda c: c.lower() in CIG_COLS)
    df.columns = [c.lower() for c in df.columns]
    n_raw = len(df)
    # FILTER 1-2 (sec. 1.1): services/supplies, ordinary sectors
    df = df[df.oggetto_principale_contratto.isin(["SERVIZI", "FORNITURE"])]
    df = df[df.settore.isin(["SETTORI ORDINARI", "ORDINARI"])].copy()
    df["source_year"] = y
    df["source_month"] = m
    return df, n_raw


def clean_cig(df):
    """Sec. 1.2-1.4 of full_analysis_commented.do (same rules, same order)."""
    df = df.copy()
    df["importo_lotto"] = pd.to_numeric(df.importo_lotto, errors="coerce")
    df = df[df.importo_lotto.notna() & (df.importo_lotto > 0)]
    df["pub_date"] = parse_ymd(df.data_pubblicazione)
    df = df[df.pub_date.notna()]
    df = df[~df.stato.isin(["Annullato", "ANNULLATO", "Ritirato", "RITIRATO"])]
    tipo = df.tipo_scelta_contraente.str.lower()
    df = df[df.cig_accordo_quadro == ""]
    df = df[~tipo.loc[df.index].str.contains("adesione", regex=False)]
    tipo = df.tipo_scelta_contraente.str.lower()
    df = df[~tipo.str.contains("accordo quadro", regex=False)]
    tipo = df.tipo_scelta_contraente.str.lower()
    df = df[~tipo.str.contains("convenzione", regex=False)].copy()
    pd_ts = stata_to_ts(df.pub_date)
    df["pub_year"] = pd_ts.dt.year
    df["period"] = np.select([pd_ts < D_P1, pd_ts < D_P2, pd_ts < D_P3], [0, 1, 2], 3)
    df["cpv2"] = pd.to_numeric(df.cod_cpv.str[:2], errors="coerce")
    df["cpv3"] = df.cod_cpv.str[:3]
    df["region"] = df.sezione_regionale
    df["authority_id"] = np.where(df.cf_amministrazione_appaltante != "",
                                  df.cf_amministrazione_appaltante, df.codice_ausa)
    low = df.tipo_scelta_contraente.str.lower()
    df["direct"] = (low.str.contains("affidamento diretto", regex=False)
                    | low.str.contains("affidamento in economia", regex=False)).astype("int8")
    df["pnrr"] = df.flag_pnrr_pnc.isin(["1", "SI"]).astype("int8")
    return df


def norm_cf(s):
    """Firm key used in all network measures: strip blanks and upper-case.
    (No other recoding, so the key stays one-to-one with codice_fiscale.)"""
    return s.astype(str).str.strip().str.upper()


def step_build(P):
    log("=== STEP build ===")
    # ---------------------------------------------------------------- CIG files
    parts, raw_rows = [], {}
    for y in HIST_YEARS:
        for m in range(1, 13):
            df, n_raw = read_cig_month(P, y, m)
            raw_rows[(y, m)] = n_raw
            parts.append(df)
        log("  read CIG files for %d" % y)
    allcig = pd.concat(parts, ignore_index=True)
    del parts
    log("  services/supplies + ordinary rows, files 2015-2024: " + format(len(allcig), ","))

    # ------------------------------------- reproduction check vs lots_v2 (2018-23)
    rep = allcig[allcig.source_year.between(2018, 2023)]
    log("  files 2018-2023, services/supplies + ordinary: " + format(len(rep), ",")
        + "  (Stata log: 1,996,457)")
    rep = clean_cig(rep)
    rep = rep[rep.pub_year.between(2018, 2023)]
    v2 = read_dta(need(P.inter_f("lots_v2.dta")),
                  ["cig", "authority_id", "cpv2", "region", "period", "pub_date",
                   "importo_lotto", "direct", "has_award", "award_date", "flag_pnrr_pnc"])
    log("  Python-cleaned 2018-2023 lots: " + format(len(rep), ",")
        + " | lots_v2.dta: " + format(len(v2), ","))
    only_py = set(rep.cig) - set(v2.cig)
    only_v2 = set(v2.cig) - set(rep.cig)
    log("  CIGs only in Python build: %d | only in lots_v2: %d | dup CIGs in Python build: %d"
        % (len(only_py), len(only_v2), rep.cig.duplicated().sum()))
    cmp_ = rep.merge(v2, on="cig", suffixes=("_py", "_v2"))
    for c in ["authority_id", "region", "period", "pub_date", "direct"]:
        a, b = cmp_[c + "_py"], cmp_[c + "_v2"]
        diff = ~((a == b) | (a.isna() & b.isna()))
        log("    field %-13s mismatches: %d" % (c, diff.sum()))
    d_imp = (cmp_.importo_lotto_py - cmp_.importo_lotto_v2).abs() > 1e-6
    d_cpv = ~((cmp_.cpv2_py == cmp_.cpv2_v2) | (cmp_.cpv2_py.isna() & cmp_.cpv2_v2.isna()))
    log("    field importo_lotto  mismatches: %d | cpv2 mismatches: %d" % (d_imp.sum(), d_cpv.sum()))
    if len(only_py) or len(only_v2):
        die("Python cleaning does not reproduce lots_v2.dta; see counts above")
    log("  REPRODUCTION CHECK PASSED: 2018-2023 Python build == lots_v2.dta")
    # date round-trip check: a few values printed side by side
    smp = cmp_.sample(5, random_state=1)
    for _, r in smp.iterrows():
        log("    cig %s  pub_date python=%s (%d)  lots_v2=%s (%d)" % (
            r.cig, stata_to_ts(pd.Series([r.pub_date_py]))[0].date(), r.pub_date_py,
            stata_to_ts(pd.Series([r.pub_date_v2]))[0].date(), r.pub_date_v2))
    del cmp_

    # ---------------------------------------------------------- history universe
    other = clean_cig(allcig[~allcig.source_year.between(2018, 2023)])
    other = other[other.pub_year.between(min(HIST_YEARS), max(HIST_YEARS))]
    rep["in_lots_v2"] = 1
    other["in_lots_v2"] = 0
    # lots in 2018-2023 files whose pub_date falls outside 2018-2023 (dropped by
    # the Stata pipeline) are also kept for history
    extra = clean_cig(allcig[allcig.source_year.between(2018, 2023)])
    extra = extra[~extra.pub_year.between(2018, 2023) & extra.pub_year.between(2015, 2024)]
    extra["in_lots_v2"] = 0
    del allcig
    uni = pd.concat([rep, other, extra], ignore_index=True)
    n0 = len(uni)
    uni = uni.sort_values(["cig", "in_lots_v2", "pub_date"], ascending=[True, False, True])
    uni = uni.drop_duplicates("cig", keep="first")
    log("  history universe: %s lots (%d duplicate CIG rows across files dropped, kept lots_v2 row or earliest pub_date)"
        % (format(len(uni), ","), n0 - len(uni)))
    log("  universe by publication year: " + uni.pub_year.value_counts().sort_index().to_dict().__repr__())

    # ------------------------------------------------------------ aggiudicazioni
    agg = pd.read_csv(need(P.raw_f("aggiudicazioni_csv.csv")), sep=";", dtype=str,
                      keep_default_na=False, encoding="utf-8", encoding_errors="replace",
                      usecols=["cig", "data_aggiudicazione_definitiva", "importo_aggiudicazione",
                               "id_aggiudicazione", "numero_offerte_ammesse",
                               "num_imprese_offerenti"])
    log("  aggiudicazioni rows: " + format(len(agg), ",") + "  (Stata log: 4,862,077)")
    agg["award_date"] = parse_ymd(agg.data_aggiudicazione_definitiva)
    # Stata: gsort cig -award_date -id_aggiudicazione (id is a STRING there);
    # descending order puts missing award_date last
    agg["_miss"] = agg.award_date.isna().astype(int)
    agg["_ad"] = agg.award_date.fillna(-1e12)
    agg = agg.sort_values(["cig", "_miss", "_ad", "id_aggiudicazione"],
                          ascending=[True, True, False, False], kind="mergesort")
    agg = agg.drop_duplicates("cig", keep="first").drop(columns=["_miss", "_ad"])
    log("  aggiudicazioni after dedup: " + format(len(agg), ",") + "  (Stata log: 4,849,388)")
    agg["award_value"] = pd.to_numeric(agg.importo_aggiudicazione, errors="coerce")
    uni = uni.merge(agg[["cig", "award_date", "award_value", "id_aggiudicazione"]],
                    on="cig", how="left", indicator=True)
    uni["has_award"] = (uni._merge == "both").astype("int8")
    uni = uni.drop(columns="_merge")
    del agg

    # award_date check against lots_v2
    chk = uni[uni.in_lots_v2 == 1][["cig", "award_date", "has_award"]].merge(
        v2[["cig", "award_date", "has_award"]], on="cig", suffixes=("_py", "_v2"))
    mis_h = (chk.has_award_py != chk.has_award_v2).sum()
    a, b = chk.award_date_py, chk.award_date_v2
    mis_d = (~((a == b) | (a.isna() & b.isna()))).sum()
    log("  check vs lots_v2: has_award mismatches=%d, award_date mismatches=%d (of %s)"
        % (mis_h, mis_d, format(len(chk), ",")))
    del chk

    # --------------------------------------------------------------- aggiudicatari
    agr = pd.read_csv(need(P.raw_f("aggiudicatari_csv.csv")), sep=";", dtype=str,
                      keep_default_na=False, encoding="utf-8", encoding_errors="replace",
                      usecols=["cig", "ruolo", "codice_fiscale", "tipo_soggetto", "id_aggiudicazione"])
    log("  aggiudicatari rows: " + format(len(agr), ","))
    agr = agr[agr.cig.isin(set(uni.cig))]
    # all roles (consortium network), universe lots only
    allroles = agr.copy()
    allroles["id_aggiudicazione"] = pd.to_numeric(allroles.id_aggiudicazione, errors="coerce")
    allroles["cf_key"] = norm_cf(allroles.codice_fiscale)
    write_dta(allroles, P.inter_f("net_aggiudicatari_allroles.dta"),
              labels={"cf_key": "Firm key: codice_fiscale stripped, upper-case",
                      "ruolo": "Role in the award (all roles kept)"})
    log("  all-roles rows for universe lots: " + format(len(allroles), ",")
        + " | roles: " + allroles.ruolo.value_counts().head(6).to_dict().__repr__())
    del allroles
    # single/lead winner: same rule as full_analysis_commented.do 5.1
    win = agr[agr.ruolo.isin(WINNER_ROLES)].copy()
    # a codice_fiscale of "" or "." is not a firm (8 such lots in 2018-2023,
    # absent from lots_winners.dta as well)
    win = win[~norm_cf(win.codice_fiscale).isin(["", "."])]
    nt = win.assign(_i=pd.to_numeric(win.id_aggiudicazione, errors="coerce"))
    nt = nt[nt._i == nt.groupby("cig")._i.transform("max")].groupby("cig").codice_fiscale.nunique()
    log("  lots with >=2 distinct winners at the highest id_aggiudicazione (ties; Stata picks one "
        "arbitrarily, Python the first in file order): " + format(int((nt >= 2).sum()), ","))
    win["_id"] = pd.to_numeric(win.id_aggiudicazione, errors="coerce")
    win["_miss"] = win._id.isna().astype(int)
    win = win.sort_values(["cig", "_miss", "_id"], ascending=[True, True, False], kind="mergesort")
    win = win.drop_duplicates("cig", keep="first")
    win = win.rename(columns={"codice_fiscale": "codice_fiscale_py", "tipo_soggetto": "winner_tipo"})
    uni = uni.merge(win[["cig", "codice_fiscale_py", "winner_tipo"]], on="cig", how="left")
    del agr, win

    # compare with lots_winners and use its winner where available
    lw = read_dta(need(P.inter_f("lots_winners.dta")), ["cig", "codice_fiscale"])
    uni = uni.merge(lw.rename(columns={"codice_fiscale": "codice_fiscale_lw"}), on="cig", how="left")
    uni["in_lots_winners"] = uni.codice_fiscale_lw.notna().astype("int8")
    in_v2 = uni.in_lots_v2 == 1
    py_edge = in_v2 & (uni.has_award == 1) & uni.codice_fiscale_py.notna()
    log("  Python rule on lots_v2 lots -> award+winner lots: %s (lots_winners.dta: %s)"
        % (format(py_edge.sum(), ","), format(len(lw), ",")))
    both = uni.in_lots_winners == 1
    same = (uni.codice_fiscale_py[both] == uni.codice_fiscale_lw[both]).sum()
    log("  winner codice_fiscale identical to lots_winners for %s of %s lots (%.4f%%)"
        % (format(same, ","), format(both.sum(), ","), 100 * same / max(both.sum(), 1)))
    uni["codice_fiscale"] = np.where(both, uni.codice_fiscale_lw, uni.codice_fiscale_py)
    uni["has_winner"] = (uni.has_award == 1) & uni.codice_fiscale.notna() & (uni.codice_fiscale.astype(str) != "nan")
    # inside lots_v2 the edge set is exactly lots_winners (the estimation sample)
    uni.loc[in_v2, "has_winner"] = both[in_v2]
    uni["has_winner"] = uni.has_winner.astype("int8")
    uni["codice_fiscale"] = uni.codice_fiscale.where(uni.has_winner == 1, "")
    uni["cf_key"] = np.where(uni.has_winner == 1, norm_cf(uni.codice_fiscale), "")
    uni["winner_is_sa"] = (uni.winner_tipo.fillna("") == "STAZIONE APPALTANTE").astype("int8")
    n_cf, n_key = uni.loc[uni.has_winner == 1, "codice_fiscale"].nunique(), uni.loc[uni.has_winner == 1, "cf_key"].nunique()
    log("  distinct winners: codice_fiscale=%s, normalised key=%s" % (format(n_cf, ","), format(n_key, ",")))

    keep = ["cig", "authority_id", "cpv2", "cpv3", "region", "pub_date", "pub_year",
            "source_year", "importo_lotto", "period", "pnrr", "direct", "in_lots_v2",
            "has_award", "award_date", "award_value", "has_winner", "codice_fiscale",
            "cf_key", "winner_is_sa", "in_lots_winners"]
    uni = uni[keep].reset_index(drop=True)
    labels = {"pub_date": "CIG publication date (Stata %td)",
              "award_date": "Award date (Stata %td), same dedup rule as lots_v2",
              "award_value": "importo_aggiudicazione",
              "in_lots_v2": "Lot is in lots_v2.dta (2018-2023 pipeline)",
              "in_lots_winners": "Lot is in lots_winners.dta",
              "has_winner": "Award record + one matched single/lead winner",
              "cf_key": "Firm key: codice_fiscale stripped, upper-case",
              "winner_is_sa": "Winner tipo_soggetto = STAZIONE APPALTANTE",
              "source_year": "Year of the CIG monthly file"}
    write_dta(uni, P.inter_f("net_lots_universe.dta"), labels=labels)
    edges = uni[uni.has_winner == 1].drop(columns=["has_award", "has_winner"])
    write_dta(edges, P.inter_f("net_edges.dta"), labels=labels)
    log("  edges by publication year: " + edges.pub_year.value_counts().sort_index().to_dict().__repr__())

    # --------------------------------------------------------------- partecipanti
    par = pd.read_csv(need(P.raw_f("partecipanti_csv.csv")), sep=";", dtype=str,
                      keep_default_na=False, encoding="utf-8", encoding_errors="replace",
                      usecols=["cig", "ruolo", "codice_fiscale", "tipo_soggetto"])
    log("  partecipanti rows (all CIGs): " + format(len(par), ","))
    par = par[par.cig.isin(set(uni.cig))].copy()
    par["cf_key"] = norm_cf(par.codice_fiscale)
    write_dta(par, P.inter_f("net_partecipanti.dta"),
              labels={"cf_key": "Firm key: codice_fiscale stripped, upper-case"})
    log("  partecipanti rows for universe lots: " + format(len(par), ",")
        + " | roles: " + par.ruolo.value_counts().head(6).to_dict().__repr__())


# =============================================================================
# STEP 3: DIAGNOSTICS
# =============================================================================
SECONDARY_ROLES = r"MANDANTE|AUSILIARIA|CONSORZIATO"   # secondary consortium roles, any coding


def pct(s, q):
    return float(np.nanpercentile(s, q)) if len(s) else np.nan


def step_diag(P):
    log("=== STEP diag ===")
    os.makedirs(P.tables, exist_ok=True)
    pd.set_option("display.width", 200)
    pd.set_option("display.max_columns", 30)
    uni = read_dta(need(P.inter_f("net_lots_universe.dta")),
                   ["cig", "authority_id", "pub_year", "pub_date", "importo_lotto", "period",
                    "pnrr", "in_lots_v2", "has_award", "award_date", "has_winner", "cf_key",
                    "winner_is_sa"])

    # ---- D1: award-matched lots and matched winners by year -------------------
    g = uni.groupby("pub_year")
    d1 = pd.DataFrame({"lots": g.size(), "award_matched": g.has_award.sum(),
                       "with_winner": g.has_winner.sum()})
    d1["share_award"] = d1.award_matched / d1.lots
    d1["share_winner"] = d1.with_winner / d1.lots
    w = uni[uni.has_winner == 1]
    d1["distinct_winners"] = w.groupby("pub_year").cf_key.nunique()
    d1["distinct_authorities"] = w.groupby("pub_year").authority_id.nunique()
    d1["winner_is_sa"] = w.groupby("pub_year").winner_is_sa.sum()
    ay = stata_to_ts(w.award_date).dt.year
    d1["edges_by_award_year"] = ay.value_counts()
    d1 = d1.reset_index().rename(columns={"pub_year": "year"})
    d1.to_csv(os.path.join(P.tables, "net_p0_awards_by_year.csv"), index=False)
    print("\nD1. Award-matched lots and matched winners, by publication year\n"
          "    (edges_by_award_year counts the same edges by year of award_date)")
    print(d1.to_string(index=False, float_format=lambda v: "%.3f" % v))

    # ---- D2: partecipanti coverage in the estimation window ----------------------
    par = read_dta(need(P.inter_f("net_partecipanti.dta")), ["cig", "ruolo", "cf_key"])
    par["unit"] = ~par.ruolo.str.upper().str.contains(SECONDARY_ROLES, regex=True)
    print("\n    partecipanti roles (universe lots):")
    print(par.ruolo.value_counts().to_string())
    per = par.groupby("cig").agg(n_rows=("cf_key", "size"), n_firms=("cf_key", "nunique"),
                                 n_units=("unit", "sum")).reset_index()
    v2 = read_dta(need(P.inter_f("lots_v2.dta")), ["cig", "x", "nbids", "direct"])
    est = uni[(uni.in_lots_v2 == 1) & uni.period.isin([0, 2]) & (uni.pnrr == 0)].merge(v2, on="cig")
    est = est[est.x.abs() <= 40000].merge(per, on="cig", how="left")
    for c in ["n_rows", "n_firms", "n_units"]:
        est[c] = est[c].fillna(0)
    est["side"] = np.where(est.x < 0, "below", "above")
    est["P"] = np.where(est.period == 0, "P0", "P2")
    rows = []
    for (p, s), gg in est.groupby(["P", "side"]):
        has = gg[gg.n_rows > 0]
        rows.append({"period": p, "side": s, "lots": len(gg),
                     "share_with_participants": (gg.n_rows > 0).mean(),
                     "share_with_part_if_awarded": (gg[gg.has_award == 1].n_rows > 0).mean(),
                     "mean_units_if_any": has.n_units.mean(), "p25": pct(has.n_units, 25),
                     "median": pct(has.n_units, 50), "p75": pct(has.n_units, 75),
                     "p90": pct(has.n_units, 90),
                     "share_single_unit_if_any": (has.n_units == 1).mean(),
                     "share_single_direct_if_any": (has[has.direct == 1].n_units == 1).mean(),
                     "corr_units_nbids": has[["n_units", "nbids"]].corr().iloc[0, 1]})
    d2 = pd.DataFrame(rows)
    d2.to_csv(os.path.join(P.tables, "net_p0_partecipanti_coverage.csv"), index=False)
    print("\nD2. partecipanti in the estimation window (main_sample, |x|<=40k)\n"
          "    units = participant records excluding secondary consortium roles (mandante, ausiliaria, consorziato)")
    print(d2.to_string(index=False, float_format=lambda v: "%.3f" % v))
    dist = (est[est.n_rows > 0].assign(units=lambda d: d.n_units.clip(upper=10).astype(int))
            .groupby(["P", "side"]).units.value_counts(normalize=True).unstack(fill_value=0))
    dist.columns = [("10+" if c == 10 else str(c)) for c in dist.columns]
    dist.to_csv(os.path.join(P.tables, "net_p0_partecipanti_distribution.csv"))
    print("\n    Distribution of participating units per lot (lots with >=1 record), row shares:")
    print(dist.to_string(float_format=lambda v: "%.3f" % v))
    b2 = d2[(d2.period == "P2") & (d2.side == "below")].iloc[0]
    if b2.share_single_unit_if_any > 0.9:
        print("    FLAG: below-cutoff P2 lots almost always record a single participant (%.3f)"
              % b2.share_single_unit_if_any)

    # ---- D3: award_date quality --------------------------------------------------
    a = uni[uni.has_award == 1].copy()
    a["days_award"] = a.award_date - a.pub_date
    a["P"] = a.period.map({0: "P0", 1: "P1", 2: "P2", 3: "P3"})
    a["grp"] = np.where(a.in_lots_v2 == 1, a.P, "hist_" + a.pub_year.astype(str))
    a["missing"] = a.award_date.isna()
    a["negative"] = a.days_award < 0
    a["before_2000"] = a.award_date < 14610            # 01jan2000 in Stata days
    a["after_2026"] = a.award_date > 24470             # 31dec2026
    a["over_5y"] = a.days_award > 5 * 365
    d3 = a.groupby("grp")[["missing", "negative", "before_2000", "after_2026", "over_5y"]].mean()
    d3.insert(0, "awarded_lots", a.groupby("grp").size())
    d3 = d3.reset_index()
    d3.to_csv(os.path.join(P.tables, "net_p0_award_date_quality.csv"), index=False)
    print("\nD3. award_date quality among lots with an award record (shares)\n"
          "    P0-P3 = lots in lots_v2; hist_YYYY = added history lots by publication year")
    print(d3.to_string(index=False, float_format=lambda v: "%.4f" % v))
    e = a[(a.in_lots_v2 == 1) & a.period.isin([0, 2]) & (a.pnrr == 0) & (a.has_winner == 1)]
    print("    Estimation lots with winner (P0+P2, non-PNRR, all values): missing award_date=%d, negative days=%d of %s"
          % (e.missing.sum(), e.negative.sum(), format(len(e), ",")))


# =============================================================================
# MAIN
# =============================================================================
def main():
    P = Paths(get_root())
    steps = sys.argv[2].split(",") if len(sys.argv) > 2 and sys.argv[2].strip() else ["download", "build", "diag"]
    log("Phase 0 | ROOT=" + P.root + " | steps=" + ",".join(steps))
    if "download" in steps:
        step_download(P)
    if "build" in steps:
        step_build(P)
    if "diag" in steps:
        step_diag(P)
    log("Phase 0 finished")


if __name__ == "__main__":
    main()
