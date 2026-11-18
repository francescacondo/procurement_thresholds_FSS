# =============================================================================
# make_extract.R -- Rebuild the data extract from the raw ANAC files (optional)
# -----------------------------------------------------------------------------
# Purpose : Builds the sample of the group's Stata pipeline
#           (repo_gruppe/code/full_analysis_commented.do, sections 1.1-1.3)
#           from the 72 monthly CIG files 2018-2023, with exactly their rules:
#             services/supplies, ordinary sectors, importo_lotto > 0, date
#             (YMD, then DMY), years 2018-2023, stato filter, framework
#             call-offs dropped (cig_accordo_quadro filled; "adesione",
#             "accordo quadro", "convenzione" in the procedure label);
#             periods P0/P1a/P1b/P2/P3. Cancelled and PNRR lots stay.
#           Karl's bulk flag (>= 50 lots with the same value per authority and
#           month) is added as a column but NOT applied here.
#           It then writes the two data inputs of run.R:
#             data/lots_group.rds   one row per lot (1,454,116 lots), only the
#                                   columns used by the control values and the
#                                   results (GROUP_EXTRACT_COLS in fn_group.R)
#             data/sample_flow.csv  lots after each sample rule
#           The checks that need the raw files run here, not in run.R:
#             - header check: every monthly file contains the columns of the
#               Stata keep list (otherwise Stata would have skipped the file)
#             - diagnostics of the raw text: dates that need the DMY fallback,
#               values that are not plain numbers, literal "NA", duplicate
#               CIGs, periods of section 1.3 vs regimes of 00_setup.R (must
#               be 0, else the script stops)
#           If an extract exists already, the script reports whether the new
#           one is identical to it, and then replaces it.
# Inputs  : <folder>/cig_csv_2018_01.csv ... cig_csv_2023_12.csv (read only;
#           ANAC open data portal, https://dati.anticorruzione.it/opendata)
# Outputs : data/lots_group.rds, data/sample_flow.csv (replaced);
#           output/logs/group_header_check.csv, output/logs/group_diagnostics.csv
# Runtime : about 1 minute
# Usage   : in a terminal, in the folder for_group:
#               Rscript code/make_extract.R /path/to/folder/with/the/cig/files
#           Not part of run.R; only needed to rebuild the extract.
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1) {
  stop("Usage (in the folder for_group):\n",
       "  Rscript code/make_extract.R /path/to/folder/with/the/cig/files", call. = FALSE)
}
if (!file.exists(file.path("code", "00_setup.R"))) {
  stop("Please start make_extract.R inside the folder for_group.", call. = FALSE)
}
RAW_DIR <- normalizePath(args[1], mustWork = TRUE)   # raw data: READ ONLY
source(file.path("code", "00_setup.R"))
t_start <- Sys.time()
cat("\n===== make_extract.R =====", format(t_start, "%Y-%m-%d %H:%M:%S"), "\n")
group_dirs()

# ---- Constants of the import (sections 1.1 and 1.2) ------------------------------------

# Raw columns read for the group sample (section 1.1 keeps more; these are the
# ones used by the sample rules and by the derived variables)
GROUP_IMPORT_COLS <- c("cig", "cig_accordo_quadro", "numero_gara", "n_lotti_componenti",
                       "importo_lotto", "oggetto_principale_contratto", "stato", "settore",
                       "data_pubblicazione", "tipo_scelta_contraente", "codice_ausa",
                       "cf_amministrazione_appaltante",
                       "denominazione_amministrazione_appaltante", "sezione_regionale",
                       "cod_cpv", "FLAG_PNRR_PNC", "COD_ESITO", "COD_MOTIVO_CANCELLAZIONE")
# Columns of the "minimal" keep list of section 1.1 (lower case). Stata skips a
# monthly file if one of them is missing; group_header_check() checks them.
GROUP_STATA_MIN_COLS <- c("cig", "cig_accordo_quadro", "oggetto_principale_contratto",
                          "settore", "importo_lotto", "data_pubblicazione",
                          "cod_tipo_scelta_contraente", "tipo_scelta_contraente",
                          "sezione_regionale", "cod_cpv", "codice_ausa",
                          "cf_amministrazione_appaltante", "anno_pubblicazione",
                          "mese_pubblicazione", "stato", "luogo_istat", "provincia",
                          "flag_urgenza", "flag_pnrr_pnc", "cod_esito", "esito",
                          "data_comunicazione_esito")

# Section 1.1 / 1.2 filters
GROUP_OBJECTS    <- c("SERVIZI", "FORNITURE")
GROUP_SECTORS    <- c("SETTORI ORDINARI", "ORDINARI")
GROUP_STATO_DROP <- c("Annullato", "ANNULLATO", "Ritirato", "RITIRATO")
GROUP_FRAMEWORK_WORDS <- c("adesione", "accordo quadro", "convenzione")   # in lower(tipo_scelta_contraente)
GROUP_YEARS      <- c(2018L, 2023L)
GROUP_ESITO_CANCELLED <- c("2", "2.0", "6", "6.0", "7", "7.0")             # "ANNULLATA ..." (section 1.13)

# ---- Functions of the import ------------------------------------------------------------

# group_header_check(): the header of every monthly file contains all columns
#   of GROUP_IMPORT_COLS and of the Stata minimal keep list (otherwise Stata
#   would have skipped the file, section 1.1).
# Output: data.table, one row per file, with the missing columns
group_header_check <- function(files) {
  rbindlist(lapply(files, function(f) {
    h <- names(fread(file.path(RAW_DIR, f), sep = ";", nrows = 0, colClasses = "character"))
    data.table(source_file = f, n_cols = length(h),
               missing_import = paste(setdiff(GROUP_IMPORT_COLS, h), collapse = " "),
               missing_stata_min = paste(setdiff(GROUP_STATA_MIN_COLS, tolower(h)), collapse = " "))
  }))
}

# group_read_file(): read one monthly file, all columns as text. Only empty
#   fields become NA (a literal "NA" stays text, as in Stata's import delimited).
group_read_file <- function(file) {
  dt <- fread(file.path(RAW_DIR, file), sep = ";", quote = "\"",
              select = GROUP_IMPORT_COLS, colClasses = "character",
              na.strings = "", encoding = "UTF-8", showProgress = FALSE)
  dt[, source_file := file]
  dt[]
}

# group_parse_date(): Stata's date(s, "YMD"), and date(s, "DMY") where the
#   first gives no date (section 1.2). Returns an IDate vector; NA = no date.
group_parse_date <- function(x) {
  d <- as.IDate(x, format = "%Y-%m-%d")
  miss <- is.na(d) & !is.na(x)
  if (any(miss)) {
    for (fmt in c("%d/%m/%Y", "%d-%m-%Y", "%d.%m.%Y", "%d %m %Y")) {
      still <- miss & is.na(d)
      if (!any(still)) break
      d[still] <- as.IDate(x[still], format = fmt)
    }
  }
  d
}

# group_import(): read the 72 files 2018-01 ... 2023-12 and apply the two
#   filters of section 1.1 to each file (services/supplies, ordinary sectors).
# Output: list(data = lots, flow = rows per step and file)
group_import <- function(files) {
  res <- vector("list", length(files))
  for (i in seq_along(files)) {
    dt <- group_read_file(files[i])
    n_all <- nrow(dt)
    dt <- dt[oggetto_principale_contratto %in% GROUP_OBJECTS]      # FILTER 1
    n_obj <- nrow(dt)
    dt <- dt[settore %in% GROUP_SECTORS]                            # FILTER 2
    res[[i]] <- list(data = dt, stats = data.table(source_file = files[i], n_records = n_all,
                                                   n_after_object = n_obj, n_after_sector = nrow(dt)))
    if (i %% 12 == 0) msg(sprintf("  read %d/%d files", i, length(files)))
  }
  list(data = rbindlist(lapply(res, `[[`, "data")),
       stats = rbindlist(lapply(res, `[[`, "stats")))
}

# group_clean(): the steps of section 1.2 in the order of the do-file, and the
#   periods of section 1.3 (period 0-3, p1a, p1b).
# Output: list(data = group sample, flow = data.table step / description / n / dropped)
group_clean <- function(lots, stats) {
  flow <- list()
  add <- function(step, description, n, dropped = NA_integer_) {
    flow[[length(flow) + 1]] <<- data.table(step = step, description = description,
                                            n_lots = n, n_dropped = dropped)
  }
  add("1.1a", "All records of the 72 monthly files", sum(stats$n_records))
  add("1.1b", "FILTER 1: oggetto_principale_contratto SERVIZI or FORNITURE",
      sum(stats$n_after_object), sum(stats$n_records) - sum(stats$n_after_object))
  add("1.1c", "FILTER 2: settore SETTORI ORDINARI or ORDINARI",
      nrow(lots), sum(stats$n_after_object) - nrow(lots))

  # Lot value: destring(force); drop missing or <= 0
  lots[, v := suppressWarnings(as.numeric(importo_lotto))]
  n0 <- nrow(lots)
  lots <- lots[!is.na(v) & v > 0]
  add("1.2a", "Drop importo_lotto missing or <= 0", nrow(lots), n0 - nrow(lots))

  # Publication date: YMD, then DMY; drop if no date
  lots[, date := group_parse_date(data_pubblicazione)]
  n0 <- nrow(lots)
  lots <- lots[!is.na(date)]
  add("1.2b", "Drop missing publication date (YMD, then DMY)", nrow(lots), n0 - nrow(lots))

  n0 <- nrow(lots)
  lots <- lots[year(date) >= GROUP_YEARS[1] & year(date) <= GROUP_YEARS[2]]
  add("1.2c", "Keep publication years 2018-2023", nrow(lots), n0 - nrow(lots))

  n0 <- nrow(lots)
  lots <- lots[!stato %in% GROUP_STATO_DROP]
  add("1.2d", "Drop stato Annullato/Ritirato (cancelled lots otherwise stay)", nrow(lots), n0 - nrow(lots))

  # Framework-agreement call-offs, four drops in the order of the do-file
  n0 <- nrow(lots)
  lots <- lots[is.na(cig_accordo_quadro) | cig_accordo_quadro == ""]
  add("1.2e", "Drop cig_accordo_quadro filled", nrow(lots), n0 - nrow(lots))
  tl <- tolower(lots$tipo_scelta_contraente)
  for (w in GROUP_FRAMEWORK_WORDS) {
    n0 <- nrow(lots)
    hit <- !is.na(tl) & grepl(w, tl, fixed = TRUE)
    lots <- lots[!hit]
    tl <- tl[!hit]
    add(paste0("1.2", letters[5 + match(w, GROUP_FRAMEWORK_WORDS)]),
        sprintf("Drop tipo_scelta_contraente containing \"%s\"", w), nrow(lots), n0 - nrow(lots))
  }

  # Section 1.3: periods
  lots[, period := fifelse(date < as.IDate("2020-07-17"), 0L,
                   fifelse(date < as.IDate("2021-06-01"), 1L,
                   fifelse(date < as.IDate("2023-07-01"), 2L, 3L)))]
  lots[, p1a := as.integer(period == 1L & date <  as.IDate("2020-09-15"))]
  lots[, p1b := as.integer(period == 1L & date >= as.IDate("2020-09-15"))]
  list(data = lots, flow = rbindlist(flow))
}

# group_derive(): variables of Karl's main pipeline (02_clean.R, spec section 7)
#   that the reused functions need, plus the bulk flag (Karl's step 5:
#   >= BULK_MIN_LOTS lots with the same value per authority and month). The
#   flag is only a switch; nothing is dropped here. Only the columns in
#   GROUP_EXTRACT_COLS go into the extract.
group_derive <- function(lots) {
  lots[, ym      := format(date, "%Y-%m")]
  lots[, ym_num  := (year(date) - 2018L) * 12L + month(date)]
  lots[, quarter := paste0(year(date), "Q", quarter(date))]
  idx <- findInterval(as.integer(lots$date), as.integer(REGIMES$start))
  lots[, regime := factor(REGIMES$regime[idx], levels = REGIME_LEVELS, ordered = TRUE)]
  lots[, c := REGIMES$c[idx]]
  lots[, x := v - c]
  lots[, direct := tipo_scelta_contraente %in% "AFFIDAMENTO DIRETTO"]
  lots[, round_1k  := v %% 1000  == 0]
  lots[, round_5k  := v %% 5000  == 0]
  lots[, round_10k := v %% 10000 == 0]
  lots[, central := sezione_regionale %in% "SEZIONE REGIONALE CENTRALE"]
  lots[, object := fifelse(oggetto_principale_contratto == "SERVIZI", "services", "supplies")]
  lots[, cpv2 := substr(cod_cpv, 1, 2)]
  lots[, special_proc := tipo_scelta_contraente %in% SPECIAL_PROC_LABELS]
  lots[, pnrr := FLAG_PNRR_PNC %in% "1"]
  lots[, cancelled_motivo := !is.na(COD_MOTIVO_CANCELLAZIONE)]       # Karl's step 6 rule
  lots[, cancelled_esito  := COD_ESITO %in% GROUP_ESITO_CANCELLED]   # group, section 1.13 (a)
  lots[, authority_id := fifelse(is.na(cf_amministrazione_appaltante) | cf_amministrazione_appaltante == "",
                                 codice_ausa, cf_amministrazione_appaltante)]
  # Bulk flag, defined exactly as in 02_clean.R (authority = cf_amministrazione_appaltante)
  lots[, n_same_value := .N, by = .(cf_amministrazione_appaltante, ym, v)]
  lots[, bulk := n_same_value >= BULK_MIN_LOTS]
  lots[, n_same_value := NULL]
  setorder(lots, date, cig)
  lots[]
}

# same_columns(): TRUE if two data.tables have the same column names and
#   exactly the same values in every column (attributes of the tables such as
#   the data.table pointer are not compared).
same_columns <- function(a, b) {
  identical(names(a), names(b)) && nrow(a) == nrow(b) && all(mapply(identical, a, b))
}

# ---- 1. Import (section 1.1) --------------------------------------------------------------
files <- sprintf("cig_csv_%d_%02d.csv", rep(2018:2023, each = 12), rep(1:12, times = 6))
missing_files <- files[!file.exists(file.path(RAW_DIR, files))]
if (length(missing_files) > 0) stop("Missing raw files in ", RAW_DIR, ": ", paste(missing_files, collapse = ", "))

headers <- group_header_check(files)
group_save_table(headers, "group_header_check", GROUP_LOG_DIR)
if (any(headers$missing_import != "" | headers$missing_stata_min != "")) {
  stop("Some monthly files lack columns (see output/logs/group_header_check.csv).")
}
msg("All 72 files contain the columns of the Stata keep list (no file is skipped).")

msg("Reading ", length(files), " monthly files from ", RAW_DIR)
imp <- group_import(files)

# ---- 2. Cleaning and periods (sections 1.2-1.3) ----------------------------------------------
cl <- group_clean(imp$data, imp$stats)
lots <- cl$data
cl$data <- NULL
rm(imp)
print(cl$flow)

# ---- 3. Derived variables and bulk flag ------------------------------------------------------
lots <- group_derive(lots)

# Diagnostics (all should be 0 or as expected; written to output/logs/group_diagnostics.csv)
diag <- data.table(
  name = c("date_needed_dmy_fallback", "value_text_not_plain_number", "literal_NA_text",
           "duplicate_cig", "period_vs_regime_mismatch", "stato_values",
           "bulk_lots", "bulk_cells", "cancelled_motivo", "cancelled_esito_2_6_7"),
  value = c(
    lots[is.na(as.IDate(data_pubblicazione, format = "%Y-%m-%d")), .N],
    lots[!grepl("^[0-9]+(\\.[0-9]+)?$", importo_lotto), .N],
    lots[cig_accordo_quadro %in% "NA" | tipo_scelta_contraente %in% "NA" |
           cf_amministrazione_appaltante %in% "NA" | stato %in% "NA", .N],
    lots[duplicated(cig), .N],
    lots[(period == 0L) != (regime == "P0") | (p1a == 1L) != (regime == "P1a") |
           (p1b == 1L) != (regime == "P1b") | (period == 2L) != (regime == "P2") |
           (period == 3L) != (regime == "P3"), .N],
    lots[, paste(paste0(fifelse(is.na(stato), "<empty>", stato), ": ", .N)), by = stato]$V1 |>
      paste(collapse = "; "),
    lots[bulk == TRUE, .N],
    uniqueN(lots[bulk == TRUE, .(cf_amministrazione_appaltante, ym, v)]),
    lots[cancelled_motivo == TRUE, .N],
    lots[cancelled_esito == TRUE, .N]))
group_save_table(diag, "group_diagnostics", GROUP_LOG_DIR)
print(diag)
if (diag[name == "period_vs_regime_mismatch", as.numeric(value)] != 0) {
  stop("The periods of section 1.3 differ from the regimes of 00_setup.R.")
}

# ---- 4. Extract: only the columns used by run.R ------------------------------------------------
ext <- lots[, ..GROUP_EXTRACT_COLS]
rm(lots)
if (nrow(ext) != cl$flow[.N, n_lots]) stop("The extract and the sample flow differ in the number of lots.")

# Compare with the files that are replaced (if they exist)
if (file.exists(GROUP_LOTS_RDS)) {
  msg("New extract identical to the existing data/lots_group.rds: ",
      same_columns(readRDS(GROUP_LOTS_RDS), ext))
}
if (file.exists(GROUP_FLOW_CSV)) {
  msg("New sample flow identical to the existing data/sample_flow.csv: ",
      same_columns(group_read_flow(), cl$flow))
}

tmp <- paste0(GROUP_LOTS_RDS, ".tmp")
saveRDS(ext, tmp, compress = "xz")          # xz: smaller file than the default gzip
if (!file.rename(tmp, GROUP_LOTS_RDS)) stop("Could not replace ", GROUP_LOTS_RDS)
fwrite(cl$flow, GROUP_FLOW_CSV)
msg("Saved data/lots_group.rds (", fmt_n(nrow(ext)), " lots, ", ncol(ext), " columns, ",
    sprintf("%.1f MB", file.size(GROUP_LOTS_RDS) / 1e6), ") and data/sample_flow.csv (",
    nrow(cl$flow), " steps)")
msg(sprintf("make_extract.R finished in %.1f seconds.",
            as.numeric(difftime(Sys.time(), t_start, units = "secs"))))
