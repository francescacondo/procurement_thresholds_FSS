# =============================================================================
# fn_aggregate.R -- Sample filters and aggregation of lots into value bins
# -----------------------------------------------------------------------------
# Contents: default_filters(), apply_filters(), in_switch_window(),
#           regime_months(), aggregate_bins(), assign_band()
# The filters are parameters so that the robustness checks (module F) can
# re-run every analysis with a different sample.
# =============================================================================

# default_filters(): sample settings of the main analysis.
# Output: named list. Module F changes single entries, e.g.
#         list(drop_bulk = FALSE) for variant F4.
default_filters <- function() {
  list(
    drop_bulk                = TRUE,   # main analyses use bulk == FALSE (spec step 5)
    drop_pnrr                = FALSE,  # F5: drop lots with pnrr == TRUE
    drop_central             = FALSE,  # F6: drop central (national) authorities
    drop_special_proc        = FALSE,  # F8: drop special procedures
    object                   = "all",  # F9: "services" or "supplies" only
    drop_months_after_switch = 0,      # F7: drop the first k months after each regime switch
    group_col                = NULL,   # module E: keep only lots whose column group_col ...
    group_value              = NULL    #   ... equals group_value (compared as text, e.g. "TRUE", "North")
  )
}

# apply_filters(): keep only the lots that satisfy the filter settings.
# Input : dt (lot-level data with columns bulk, pnrr, central, special_proc,
#         object, date), filters (list; missing entries use the defaults)
# Output: the filtered data.table
apply_filters <- function(dt, filters = default_filters()) {
  f <- modifyList(default_filters(), filters)
  keep <- rep(TRUE, nrow(dt))
  if (f$drop_bulk)         keep <- keep & !dt$bulk
  if (f$drop_pnrr)         keep <- keep & !dt$pnrr
  if (f$drop_central)      keep <- keep & !dt$central
  if (f$drop_special_proc) keep <- keep & !dt$special_proc
  if (f$object != "all")   keep <- keep & dt$object == f$object
  if (f$drop_months_after_switch > 0) {
    keep <- keep & !in_switch_window(dt$date, f$drop_months_after_switch)
  }
  if (!is.null(f$group_col)) {
    keep <- keep & as.character(dt[[f$group_col]]) == as.character(f$group_value)
  }
  dt[keep]
}

# in_switch_window(): TRUE for dates in the first k months after a regime switch
#   (switches: 2020-07-17, 2020-09-15, 2021-06-01, 2023-07-01).
# Input : date (IDate vector), k (number of months)
# Output: logical vector of the same length as date
in_switch_window <- function(date, k) {
  out <- rep(FALSE, length(date))
  for (i in seq_along(REGIME_SWITCHES)) {
    s     <- REGIME_SWITCHES[i]
    s_end <- as.IDate(seq(as.Date(s), by = paste(k, "months"), length.out = 2)[2])
    out   <- out | (date >= s & date < s_end)
  }
  out
}

# regime_months(): length of each regime in months (days / 30.4375). If the
#   first k months after each switch are dropped (F7), those days are removed.
# Input : filters (list, see default_filters())
# Output: data.table with columns regime, days, months
regime_months <- function(filters = default_filters()) {
  f <- modifyList(default_filters(), filters)
  days   <- as.IDate(seq(as.Date(DATA_START), as.Date(DATA_END), by = "day"))
  regime <- REGIMES$regime[findInterval(as.integer(days), as.integer(REGIMES$start))]
  keep   <- rep(TRUE, length(days))
  if (f$drop_months_after_switch > 0) {
    keep <- !in_switch_window(days, f$drop_months_after_switch)
  }
  out <- data.table(regime = regime, keep = keep)[, .(days = sum(keep)), by = regime]
  out[, months := days / 30.4375]
  out[, regime := factor(regime, levels = REGIME_LEVELS, ordered = TRUE)]
  out[]
}

# aggregate_bins(): count lots per value bin, separately for each group
#   (e.g. per regime or per month). Empty bins are filled with 0.
# Input : dt          lot-level data (data/lots_all.rds)
#         bin_width   width of the value bins in euro (1000 = 1k bins)
#         filters     sample filters (list, see default_filters())
#         by          grouping column(s), e.g. "regime" or "ym"
#         v_min, v_max  bins cover v_min <= v < v_max
#         anchor      bin edges are anchor + k * bin_width (default 0). Use the
#                     threshold c as anchor for 2k bins, so that c is a bin edge.
# Output: data.table, one row per group and bin, with columns
#         bin (lower bound), n (lots), n_nonround (lots that are not a multiple
#         of 1,000), value_sum (sum of v), n_ref (lots 250k-1M in the group)
aggregate_bins <- function(dt, bin_width = 1000, filters = default_filters(),
                           by = "regime", v_min = 30000, v_max = 250000,
                           anchor = 0) {
  if ((v_min - anchor) %% bin_width != 0 || (v_max - anchor) %% bin_width != 0) {
    stop("v_min and v_max must lie on the bin grid (anchor + k * bin_width).")
  }
  d <- apply_filters(dt, filters)

  # Lots in the reference band 250k-1M per group (used for normalisations)
  ref <- d[v >= REF_BAND[1] & v < REF_BAND[2], .(n_ref = .N), by = by]

  # Bin the lots inside [v_min, v_max)
  w <- d[v >= v_min & v < v_max]
  w[, bin := anchor + floor((v - anchor) / bin_width) * bin_width]
  counts <- w[, .(n = .N, n_nonround = sum(!round_1k), value_sum = round(sum(v), 2)),
              by = c(by, "bin")]

  # Complete grid: every group present in the data x every bin
  bins <- seq(v_min, v_max - bin_width, by = bin_width)
  grid <- unique(d[, by, with = FALSE])[, .(bin = bins), by = by]
  out  <- merge(grid, counts, by = c(by, "bin"), all.x = TRUE)
  for (col in c("n", "n_nonround", "value_sum")) {
    set(out, which(is.na(out[[col]])), col, 0)
  }
  out <- merge(out, ref, by = by, all.x = TRUE)
  out[is.na(n_ref), n_ref := 0L]
  setorderv(out, c(by, "bin"))
  out[]
}

# as_regime(): turn regime labels (e.g. read from a CSV file) back into the
#   ordered factor P0 < P1a < P1b < P2 < P3.
as_regime <- function(x) factor(as.character(x), levels = REGIME_LEVELS, ordered = TRUE)

# month_table(): one row per calendar month 2018-01 ... 2023-12.
# Output: data.table with ym ("2021-06"), ym_num (2018-01 = 1), quarter
#         ("2021Q2"), regime (the regime in force on most days of the month)
#         and regime_mixed (TRUE if a regime switch falls inside the month:
#         2020-07 and 2020-09)
month_table <- function() {
  days <- as.IDate(seq(as.Date(DATA_START), as.Date(DATA_END), by = "day"))
  d <- data.table(ym = format(days, "%Y-%m"),
                  regime = REGIMES$regime[findInterval(as.integer(days), as.integer(REGIMES$start))])
  out <- d[, .(regime = names(which.max(table(regime))),   # majority of days
               regime_mixed = uniqueN(regime) > 1), by = ym]
  out[, ym_num := (as.integer(substr(ym, 1, 4)) - 2018L) * 12L + as.integer(substr(ym, 6, 7))]
  out[, quarter := paste0(substr(ym, 1, 4), "Q", (as.integer(substr(ym, 6, 7)) - 1L) %/% 3L + 1L)]
  out[, regime := as_regime(regime)]
  setcolorder(out, c("ym", "ym_num", "quarter", "regime", "regime_mixed"))
  out[]
}

# period_regimes(): all regimes in force during each month or quarter, from
#   the daily calendar, e.g. "P2", "P0/P1a" (2020-07) or "P0/P1a/P1b" (2020Q3).
# Input : by ("ym" or "quarter")
# Output: data.table with columns <by>, regimes
period_regimes <- function(by = "quarter") {
  days <- as.IDate(seq(as.Date(DATA_START), as.Date(DATA_END), by = "day"))
  d <- data.table(ym = format(days, "%Y-%m"),
                  regime = REGIMES$regime[findInterval(as.integer(days), as.integer(REGIMES$start))])
  d[, quarter := paste0(substr(ym, 1, 4), "Q", (as.integer(substr(ym, 6, 7)) - 1L) %/% 3L + 1L)]
  d[, .(regimes = paste(unique(regime), collapse = "/")), by = by]
}

# assign_band(): value band of tables A2, A3 and D3 (see BANDS in 00_setup.R).
# Input : v (numeric vector of lot values)
# Output: factor with the band labels; NA for values below 45k or >= 1M
assign_band <- function(v, bands = BANDS) {
  idx <- findInterval(v, bands$lower)
  idx[idx == 0 | v >= max(bands$upper)] <- NA
  factor(bands$band[idx], levels = bands$band)
}
