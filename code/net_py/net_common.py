"""
net_common.py -- shared helpers for the network extension (Project D).

Every phase script imports this module. It handles:
  * reading $ROOT from sys.argv (passed by net_master.do via args("$ROOT"))
  * building all paths from ROOT (no hard-coded absolute paths)
  * reading only the needed columns of a .dta, keeping identifiers as strings
  * explicit Stata-date <-> pandas conversion (Stata %td = days since 1 Jan 1960)
  * writing .dta files (version 118, no index, variable labels)
"""
import os
import sys
import time

import numpy as np
import pandas as pd
import pyreadstat

STATA_EPOCH = pd.Timestamp("1960-01-01")

# Identifier columns: always strings, never floats
ID_COLS = ("cig", "authority_id", "codice_fiscale", "cpv3", "cod_cpv")


def die(msg):
    """Stop the pipeline with a clear message (shows up in the Stata log)."""
    print("\n*** NET PIPELINE ERROR: " + msg + "\n", flush=True)
    # RuntimeError (not SystemExit): inside Stata, SystemExit returns rc 0 and the
    # do-file would carry on; an exception makes `python script` fail with r(7102)
    raise RuntimeError("NET PIPELINE ERROR: " + msg)


def get_root():
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        die("ROOT not passed. Call as: python script <file>, args(\"$ROOT\")")
    root = os.path.abspath(sys.argv[1].strip().strip('"'))
    if not os.path.isdir(os.path.join(root, "data", "intermediate")):
        die("ROOT=" + root + " does not contain data/intermediate/")
    return root


class Paths:
    def __init__(self, root):
        self.root = root
        self.raw = os.path.join(root, "data", "raw")
        self.inter = os.path.join(root, "data", "intermediate")
        self.net = os.path.join(root, "data", "intermediate", "net")
        self.tables = os.path.join(root, "results", "tables")
        self.figures = os.path.join(root, "results", "figures")
        self.code = os.path.join(root, "code")
        os.makedirs(self.net, exist_ok=True)

    def raw_f(self, name):
        return os.path.join(self.raw, name)

    def inter_f(self, name):
        return os.path.join(self.inter, name)

    def net_f(self, name):
        return os.path.join(self.net, name)


def need(path):
    """Exit with a clear message if an input file is missing."""
    if not os.path.exists(path):
        die("required input file is missing: " + path)
    return path


def log(msg):
    print("[" + time.strftime("%H:%M:%S") + "] " + str(msg), flush=True)


def stata_to_ts(s):
    """Stata %td integer (days since 1960-01-01) -> pandas Timestamp (NaT if missing)."""
    s = pd.to_numeric(s, errors="coerce")
    # pandas Timestamps only cover 1677-2262; implausible raw dates (e.g. year
    # 0204 in aggiudicazioni) become NaT here -- use day counts to flag them
    s = s.where(s.between(-104000, 110000))
    return STATA_EPOCH + pd.to_timedelta(s, unit="D")


def ts_to_stata(s):
    """pandas Timestamp -> Stata %td integer stored as float (NaN if missing)."""
    return (pd.to_datetime(s) - STATA_EPOCH).dt.days.astype("float64")


def read_dta(path, columns):
    """Read only `columns` from a .dta file. Dates are NOT auto-converted
    (they come back as Stata day counts); identifiers come back as strings."""
    need(path)
    df, meta = pyreadstat.read_dta(path, usecols=list(columns),
                                   disable_datetime_conversion=True)
    for c in df.columns:
        if c in ID_COLS:
            df[c] = df[c].astype(str).replace({"nan": "", "None": ""})
    log("read " + os.path.basename(path) + ": " + format(len(df), ",") + " rows, cols=" + ",".join(df.columns))
    return df


def write_dta(df, path, labels=None, date_cols=()):
    """Write a .dta (version 118). Identifier columns are forced to str.
    date_cols: columns holding Stata day counts -> stored as %td."""
    df = df.copy()
    for c in df.columns:
        if c in ID_COLS or df[c].dtype == object:
            df[c] = df[c].fillna("").astype(str)
    labels = {k: v[:80] for k, v in (labels or {}).items() if k in df.columns}
    # to_stata only formats datetime64 columns as %td; we keep day counts as
    # numbers and set the display format in Stata (net_master/net_estimation).
    # a few malformed codice_fiscale values are hundreds of characters long; as
    # fixed-width str they inflate every row, so wide columns are stored as strL
    # (never used as Stata merge keys -- those are cig / authority_id)
    wide = [c for c in df.columns if df[c].dtype == object and df[c].str.len().max() > 64]
    df.to_stata(path, version=118, write_index=False, variable_labels=labels,
                convert_strl=wide)
    log("wrote " + os.path.basename(path) + ": " + format(len(df), ",") + " rows x " + str(df.shape[1]) + " cols")


def months_since_1960(ts):
    """Stata %tm month index (months since Jan 1960) from Timestamps."""
    ts = pd.to_datetime(ts)
    return (ts.dt.year - 1960) * 12 + (ts.dt.month - 1)
