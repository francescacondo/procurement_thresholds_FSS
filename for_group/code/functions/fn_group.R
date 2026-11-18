# =============================================================================
# fn_group.R -- Group sample (Stata pipeline of the group) and results on it
# -----------------------------------------------------------------------------
# Contents (phase 1, sample and replication):
#   group_dirs(), group_save_table(), group_read_flow(), group_ctrl(),
#   group_bunch_bins(), group_bunch_fit(), group_b3_grid(), group_b4_bands()
# The import of the raw files (sections 1.1-1.3: group_header_check(),
# group_import(), group_clean(), group_derive(), ...) is in code/make_extract.R.
# The group's rules are those of repo_gruppe/code/full_analysis_commented.do,
# sections 1.1-1.3 (sample), 3.2-3.5 (bunching at 139k, bootstrap,
# sensitivity grid B3, band ratios B4).
# The file is loaded by 00_setup.R together with all other function files, so
# it only defines objects; every name starts with group_ / GROUP_. All inputs
# are read from data/, all outputs go to output/ (GROUP_OUT_DIR).
# =============================================================================

# ---- Constants -------------------------------------------------------------------
GROUP_REPO_TAB <- file.path(DATA_DIR, "group_tables")     # copies of repo_gruppe/results/tables/ (read only)
GROUP_OUT_DIR  <- OUT_DIR
GROUP_TAB_DIR  <- TAB_DIR
GROUP_FIG_DIR  <- FIG_DIR
GROUP_LOG_DIR  <- LOG_DIR
GROUP_LOTS_RDS <- file.path(DATA_DIR, "lots_group.rds")   # extract of the group sample, all lots
GROUP_FLOW_CSV <- file.path(DATA_DIR, "sample_flow.csv")  # lots after each sample rule
# Columns of the extract (written by make_extract.R): the ones used by the
# control values and the four results
GROUP_EXTRACT_COLS <- c("v", "date", "ym", "regime", "round_1k", "bulk", "central",
                        "cancelled_esito", "cf_amministrazione_appaltante",
                        "denominazione_amministrazione_appaltante")

# Section 3.2-3.5: bunching at 139k (main specification of the group)
GROUP_CUTOFF <- 139000
GROUP_BUNCH  <- list(window = c(100000, 200000),   # right-closed bins (k - 1000, k] inside (100k, 200k]
                     excl_below = 5000, excl_above = 5000, poly_degree = 7, dummies_5k = TRUE)
GROUP_SEED   <- 20261104                            # seed of the group's bootstrap (section 3.3)
GROUP_CTRL_REGIME <- "P1b"                          # control period of the main run (CTRL = P1B)
# Specification grid of section 3.5 (a), table B3 (8 rows)
GROUP_B3_SPECS <- data.table(
  spec  = 1:8,
  label = c("main: poly 7, excl 5k/5k, 10k+5k dummies", "poly 5", "poly 9",
            "excl. below 3k", "excl. below 10k", "excl. above 10k", "excl. above 20k",
            "no 5k dummies"),
  poly_degree = c(7, 5, 9, 7, 7, 7, 7, 7),
  excl_below  = c(5000, 5000, 5000, 3000, 10000, 5000, 5000, 5000),
  excl_above  = c(5000, 5000, 5000, 5000, 5000, 10000, 20000, 5000),
  dummies_5k  = c(TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, FALSE)
)
# Section 3.5 (c), table B4: 10k bands (band, band + 10k] for 40k < v <= 300k,
# each period scaled by its own count in (220k, 300k]
GROUP_B4 <- list(v_range = c(40000, 300000), ref_from_band = 220)

# Control values of phase 1 (Karl's request; group results in repo_gruppe)
GROUP_EXPECTED_N_LOTS  <- 1454116    # results/report.md: population of the group
GROUP_EXPECTED_N139_P2 <- 2298       # descriptives_p1b.csv: p2_n_at139

# ---- Small helpers -------------------------------------------------------------------

# group_dirs(): create the output folders of the group analysis (called by the
#   scripts, not when this file is loaded).
group_dirs <- function() {
  for (d in c(GROUP_TAB_DIR, GROUP_FIG_DIR, GROUP_LOG_DIR)) {
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
  }
  invisible(TRUE)
}

# group_save_table(): write a CSV to output/tables/<name>.csv
#   (or to the logs folder with dir = GROUP_LOG_DIR).
group_save_table <- function(dt, name, dir = GROUP_TAB_DIR) {
  path <- file.path(dir, paste0(name, ".csv"))
  fwrite(dt, path)
  msg("Saved ", basename(dirname(path)), "/", basename(path), " (", nrow(dt), " rows)")
  invisible(path)
}

# group_read_flow(): read data/sample_flow.csv (written by make_extract.R).
#   Base read.csv instead of fread, because fread keeps the doubled quotes ("")
#   inside quoted descriptions instead of turning them back into one quote.
group_read_flow <- function(path = GROUP_FLOW_CSV) {
  as.data.table(utils::read.csv(path, colClasses = c("character", "character", "integer", "integer"),
                                encoding = "UTF-8"))
}

# group_ctrl(): one control value. Default: pass = computed equals expected
#   after rounding both to `decimals` decimals (0 = exact count). With
#   half_unit = TRUE: pass = |computed - expected| <= 0.5 * 10^-decimals, i.e.
#   equal to `decimals` decimals without the flip of rounding at a boundary.
#   Used for the B3 values, which Stata stores as float (postfile default
#   type; 7 significant digits), e.g. 14307.015 for 14307.0151.
# Output: one-row data.table
group_ctrl <- function(id, description, expected, computed, decimals = 0, half_unit = FALSE) {
  pass <- if (half_unit) {
    abs(computed - expected) <= 0.5 * 10^-decimals
  } else {
    isTRUE(all.equal(round(computed, decimals), round(expected, decimals), tolerance = 0))
  }
  data.table(id = id, description = description, expected = expected,
             computed = computed, decimals = decimals,
             rule = if (half_unit) "abs diff <= half unit" else "equal after rounding",
             abs_diff = computed - expected, pass = pass)
}

# ---- Bunching with the group's specification (sections 3.2-3.5) -------------------------------

# group_bunch_bins(): lots per right-closed 1k bin (k - 1000, k] inside the
#   window (window[1], window[2]], as `collapse (sum)` in Stata (only bins with
#   lots). Bin position = midpoint k - 500 (the do-file's bin_bunch / bin).
#   z = (midpoint - c) / 1000. Excluded from the fit: midpoints in
#   (c - excl_below, c + excl_above), i.e. the bins (134k, 144k] in the main
#   specification. Dummies: r10k = bin ends at a multiple of 10k, r5k = bin
#   ends at a multiple of 5k that is not a multiple of 10k (the do-file's
#   round10k / round5k; same column space as the 5k/10k dummies of module B).
# Input : dt (lot data), regimes, c, window, excl_below, excl_above,
#         dummies_5k, strict (TRUE: lots at exactly c count to the first bin
#         above, (c, c + 1000], result 4), filters (list for apply_filters())
# Output: data.table bin, n, z, r10k, (r5k), excluded, region (below/above/outside)
group_bunch_bins <- function(dt, regimes, c = GROUP_CUTOFF, window = GROUP_BUNCH$window,
                             excl_below = GROUP_BUNCH$excl_below,
                             excl_above = GROUP_BUNCH$excl_above,
                             dummies_5k = GROUP_BUNCH$dummies_5k, strict = FALSE,
                             filters = list(drop_bulk = FALSE)) {
  thr <- c
  d <- apply_filters(dt[regime %in% regimes], filters)[v > window[1] & v <= window[2]]
  d[, bin := ceiling(v / 1000) * 1000 - 500]
  if (strict) d[v == thr, bin := thr + 500]
  bins <- d[, .(n = .N), by = bin][order(bin)]
  bins[, z := (bin - thr) / 1000]
  bins[, r10k := as.integer((bin + 500) %% 10000 == 0)]
  if (dummies_5k) bins[, r5k := as.integer((bin + 500) %% 5000 == 0 & r10k == 0L)]
  bins[, excluded := bin > thr - excl_below & bin < thr + excl_above]
  bins[, region := fifelse(excluded & bin < thr, "below", fifelse(excluded & bin > thr, "above", "outside"))]
  bins[]
}

# group_bunch_fit(): counterfactual and excess mass for one set of bins, with
#   fit_counterfactual() and bunching_stats() of module B (polynomial of
#   degree poly_degree plus the dummies, fitted outside the excluded range).
#   b = excess / mean counterfactual count of the bins below c (Kleven 2016,
#   as in the do-file); the check makes sure that all excl_below / 1000 bins
#   below c exist, so that this mean equals bunching_stats()'s normalisation.
# Output: list(stats = c(B, b, M), n_hat)
group_bunch_fit <- function(bins, poly_degree, excl_below, counts = bins$n) {
  z_L <- -excl_below / 1000
  if (sum(bins$region == "below") != abs(z_L)) stop("A bin below the cutoff has no lots.")
  n_hat <- fit_counterfactual(bins, counts, poly_degree)
  list(stats = bunching_stats(bins, counts, n_hat, z_L), n_hat = n_hat)
}

# group_b3_grid(): table B3 of the group (section 3.5 a): b, excess and
#   missing mass for 8 specifications and the periods P2, P1b and P0, and
#   b_diff = b(P2) - b(P1b).
# Input : dt, filters, strict (passed to group_bunch_bins)
# Output: data.table in the layout of B3_bunching_sensitivity_p1b.csv
group_b3_grid <- function(dt, filters = list(drop_bulk = FALSE), strict = FALSE,
                          periods = c("P0", "P1b", "P2")) {
  long <- rbindlist(lapply(periods, function(g) {
    rbindlist(lapply(seq_len(nrow(GROUP_B3_SPECS)), function(k) {
      s <- GROUP_B3_SPECS[k]
      bins <- group_bunch_bins(dt, g, excl_below = s$excl_below, excl_above = s$excl_above,
                               dummies_5k = s$dummies_5k, strict = strict, filters = filters)
      f <- group_bunch_fit(bins, s$poly_degree, s$excl_below)
      data.table(spec = s$spec, label = s$label, grp = g, b = f$stats[["b"]],
                 excess = f$stats[["B"]], missing = f$stats[["M"]])
    }))
  }))
  wide <- dcast(long, spec + label ~ grp, value.var = c("b", "excess", "missing"), sep = "")
  wide[, b_diff := bP2 - get(paste0("b", GROUP_CTRL_REGIME))]
  setorder(wide, spec)
  wide[]
}

# group_b4_bands(): table B4 of the group (section 3.5 c). Lots per 10k band
#   (band, band + 10k] for 40k < v <= 300k in the control period C and in P2,
#   each scaled by its own count in (220k, 300k]; ratio = relP2 / relC;
#   extra_lots = (relP2 - relC) * refP2.
# Output: data.table in the layout of B4_band_ratios_p1b.csv
group_b4_bands <- function(dt, ctrl = GROUP_CTRL_REGIME, filters = list(drop_bulk = FALSE)) {
  d <- apply_filters(dt[regime %in% c(ctrl, "P2")], filters)[
    v > GROUP_B4$v_range[1] & v <= GROUP_B4$v_range[2]]
  d[, grp := fifelse(regime == "P2", "P2", "C")]
  d[, bin := ceiling(v / 1000) * 1000 - 500]
  d[, band10 := (ceiling((bin + 500) / 10000) - 1) * 10]
  n <- d[, .(n = .N), by = .(grp, band10)]
  n[, ref := sum(n * (band10 >= GROUP_B4$ref_from_band)), by = grp]
  n[, rel := n / ref]
  w <- dcast(n, band10 ~ grp, value.var = c("n", "ref", "rel"), sep = "")
  w[, ratio := relP2 / relC]
  w[, extra_lots := (relP2 - relC) * refP2]
  setcolorder(w, c("band10", "nC", "refC", "relC", "nP2", "refP2", "relP2", "ratio", "extra_lots"))
  setorder(w, band10)
  w[]
}

# =============================================================================
# Phase 2: four results on the group sample
# Contents: group_variants(), group_monthly_index(), group_fit_decay_free(),
#   group_dynamics(), group_bunch_bootstrap(), group_bulk_window(),
#   group_band_summary(), group_s1_fit(), group_tex_line(),
#   group_save_figure(), group_plot_c2(), group_plot_s1()
# =============================================================================

# Sample variants: every result is computed without and with Karl's bulk filter
GROUP_VARIANTS <- data.table(variant = c("no_bulk_filter", "bulk_filter"),
                             label   = c("No bulk filter", "Bulk filter"),
                             drop_bulk = c(FALSE, TRUE))
group_variants <- function() GROUP_VARIANTS

# Result 2: monthly index S on the group sample (decision K23)
GROUP_INDEX <- list(
  start_date = as.IDate("2020-09-15"),   # September 2020 = 15-30 Sep (P1b only)
  end_date   = as.IDate("2023-06-30"),
  first_ym = "2020-09", last_ym = "2023-06",
  pre      = c("2018-01", "2019-12"),    # comparison variant of the 75k decay
  p1b      = c("2020-09", "2021-05"),    # pre-level of 139k = mean over P1b
  decay_from = c("2021-06", "2021-08"),  # fit of the 75k decay: main and without the first two months
  event_ref  = "2021-06",                # event time 0 in figure C2
  event_range = c(-9, 24)                # September 2020 to June 2023
)
# Result 3: summary range of the B4 bands, (80k, 130k] (closest to 75k-125k)
GROUP_B4_SUMMARY_BANDS <- c(80, 120)
# Result 4: label of the LaTeX row (format of I_bunch_sens_p1b.tex)
GROUP_TEX_LABEL <- "strict cutoff: lots at 139,000 above"

# group_monthly_index(): bunching_index() of module C on the group sample with
#   the lots of 2018-2019 (pre-level of the comparison variant) and of
#   15 Sep 2020 to 30 Jun 2023. Months in between are left out.
# Output: monthly series (columns of bunching_index()) for 2018-01..2019-12
#         and 2020-09..2023-06
group_monthly_index <- function(dt, c, filters) {
  d <- dt[date <= as.IDate("2019-12-31") |
            (date >= GROUP_INDEX$start_date & date <= GROUP_INDEX$end_date)]
  s <- bunching_index(d, c, num_width = 1000, half_window = 20000, by = "ym", filters = filters)
  s[(ym >= GROUP_INDEX$pre[1] & ym <= GROUP_INDEX$pre[2]) |
      (ym >= GROUP_INDEX$first_ym & ym <= GROUP_INDEX$last_ym)]
}

# group_fit_decay_free(): exponential decay with a free asymptote (decision K23),
#   S_t = asym + A * exp(-lambda * (t - t0)), t0 = from_ym, fitted with nls()
#   on the months from_ym ... to_ym. Half-life = ln(2) / lambda, delta-method
#   SE = ln(2) / lambda^2 * SE(lambda). Start values: asym = mean of the last
#   6 months, A = first value - asym, lambda = ln(2) / 3 (if nls fails:
#   ln(2) / 1, then ln(2) / 12).
# Output: one-row data.table
group_fit_decay_free <- function(series, from_ym, to_ym) {
  s <- series[ym_num >= ym_to_num(from_ym) & ym_num <= ym_to_num(to_ym) & !is.na(S)][order(ym_num)]
  s[, t := ym_num - ym_to_num(from_ym)]
  a0 <- mean(tail(s$S, 6))
  fit <- NULL; msg_txt <- ""
  for (hl0 in c(3, 1, 12)) {
    fit <- tryCatch(nls(S ~ asym + A * exp(-lambda * t), data = s,
                        start = list(asym = a0, A = s$S[1] - a0, lambda = log(2) / hl0),
                        control = nls.control(maxiter = 500)),
                    error = function(e) e)
    if (!inherits(fit, "error")) break
    msg_txt <- conditionMessage(fit)
  }
  out <- data.table(fit_from = from_ym, fit_to = to_ym, n_months = nrow(s))
  if (inherits(fit, "error")) {
    return(out[, `:=`(converged = FALSE, asymptote = NA_real_, asymptote_se = NA_real_,
                      A = NA_real_, lambda = NA_real_, lambda_se = NA_real_, half_life = NA_real_,
                      half_life_se = NA_real_, half_life_ci_low = NA_real_,
                      half_life_ci_high = NA_real_, message = msg_txt)])
  }
  co <- summary(fit)$coefficients
  lam <- co["lambda", "Estimate"]; lam_se <- co["lambda", "Std. Error"]
  hl <- log(2) / lam; hl_se <- log(2) / lam^2 * lam_se
  out[, `:=`(converged = TRUE, asymptote = co["asym", "Estimate"],
             asymptote_se = co["asym", "Std. Error"], A = co["A", "Estimate"],
             lambda = lam, lambda_se = lam_se, half_life = hl, half_life_se = hl_se,
             half_life_ci_low = hl - 1.96 * hl_se, half_life_ci_high = hl + 1.96 * hl_se,
             message = "converged")]
  out[]
}

# group_dynamics(): metrics of result 2 for one monthly series.
#   139k: baseline = mean over P1b (2020-09..2021-05), plateau 2022-01..2023-06,
#         build-up from 2021-06 (month 0).
#   75k:  plateau 2020-10..2021-05, build-up from 2020-09 (month 0); decay
#         fitted on 2021-06..2023-06 and 2021-08..2023-06. Main: free asymptote
#         (group_fit_decay_free); its asymptote (fit from 2021-06) is also the
#         baseline of the build-up. Comparison: pre-level 2018-2019 with
#         fit_decay() of module C (S_t - pre = A exp(-lambda t)).
#   Build-up = first month from month 0 with S >= baseline + share * (plateau - baseline).
# Output: data.table, one row per baseline / decay-fit variant
group_dynamics <- function(series, c) {
  thr <- c   # inside DYNAMICS_SETUP[...] the name c would be the column c
  plat_months <- DYNAMICS_SETUP[DYNAMICS_SETUP$c == thr]
  if (nrow(plat_months) != 1) stop("No plateau months for c = ", thr)
  plateau <- period_mean(series, plat_months$plateau_from, plat_months$plateau_to)
  start_ym <- format(REGIMES[regime == plat_months$regime, start], "%Y-%m")
  row <- function(baseline_type, baseline, decay = NULL) {
    out <- data.table(c = c, baseline_type = baseline_type, baseline = baseline,
                      plateau = plateau,
                      plateau_period = paste(plat_months$plateau_from, "to", plat_months$plateau_to),
                      month0 = start_ym,
                      buildup_50 = buildup_time(series, start_ym, baseline + 0.5 * (plateau - baseline)),
                      buildup_90 = buildup_time(series, start_ym, baseline + 0.9 * (plateau - baseline)))
    if (!is.null(decay)) out <- cbind(out, decay)
    out
  }
  if (c == 139000) {
    return(row("mean over P1b", period_mean(series, GROUP_INDEX$p1b[1], GROUP_INDEX$p1b[2])))
  }
  # 75k: main variant, free asymptote
  free <- lapply(GROUP_INDEX$decay_from, function(f) group_fit_decay_free(series, f, GROUP_INDEX$last_ym))
  asym <- free[[1]]$asymptote
  rows <- lapply(free, function(fr) {
    row("free asymptote (fit from 2021-06)", asym,
        fr[, .(decay_model = "free asymptote", fit_from, fit_to, n_months, converged,
               asymptote, asymptote_se, lambda, lambda_se, half_life, half_life_se,
               half_life_ci_low, half_life_ci_high)])
  })
  # comparison: pre-level 2018-2019 (fit_decay of module C)
  pre <- period_mean(series, GROUP_INDEX$pre[1], GROUP_INDEX$pre[2])
  rows_pre <- lapply(GROUP_INDEX$decay_from, function(f) {
    fd <- fit_decay(series, f, GROUP_INDEX$last_ym, pre)
    row("pre-level 2018-2019", pre,
        fd[, .(decay_model = "fixed asymptote = pre-level 2018-2019", fit_from = f,
               fit_to = GROUP_INDEX$last_ym, n_months = nls_months, converged = nls_converged,
               asymptote = pre, asymptote_se = NA_real_, lambda = nls_lambda,
               lambda_se = nls_lambda_se, half_life, half_life_se, half_life_ci_low,
               half_life_ci_high)])
  })
  rbindlist(c(rows, rows_pre))
}

# group_bunch_bootstrap(): bunching at 139k with the group's specification
#   and their residual bootstrap (section 3.3): the seed is set once, then P2
#   and the control period are bootstrapped one after the other (independent
#   draws); in each replication the residuals of the fitted bins are drawn
#   with replacement (resid[ceil(runiform() * n_fit)]), added to the fitted
#   values and floored at 0; excluded bins keep their observed counts.
#   Difference = draw r of P2 minus draw r of the control period. SE = sd of
#   the draws; 95 % interval = 2.5 / 97.5 percentiles with Stata's _pctile
#   definition (R quantile type 2).
# Input : dt, strict (TRUE = lots at 139,000 in the first bin above), filters,
#         reps, seed, periods (first P2, then the control period)
# Output: list(summary = one row per period + "diff", draws = matrix)
group_bunch_bootstrap <- function(dt, strict, filters, reps = BOOT_REPS, seed = GROUP_SEED,
                                  periods = c("P2", GROUP_CTRL_REGIME), spec = GROUP_BUNCH) {
  set.seed(seed)
  draws <- matrix(NA_real_, reps, length(periods), dimnames = list(NULL, periods))
  est <- list()
  for (g in periods) {
    bins <- group_bunch_bins(dt, g, window = spec$window, excl_below = spec$excl_below,
                             excl_above = spec$excl_above, dummies_5k = spec$dummies_5k,
                             strict = strict, filters = filters)
    f <- group_bunch_fit(bins, spec$poly_degree, spec$excl_below)
    fitted <- !bins$excluded
    n_fit  <- sum(fitted)
    resid  <- bins$n[fitted] - f$n_hat[fitted]
    draws[, g] <- vapply(seq_len(reps), function(r) {
      cnt <- bins$n
      cnt[fitted] <- pmax(0, f$n_hat[fitted] + resid[ceiling(runif(n_fit) * n_fit)])
      group_bunch_fit(bins, spec$poly_degree, spec$excl_below, counts = cnt)$stats[["b"]]
    }, numeric(1))
    est[[g]] <- data.table(period = g, b = f$stats[["b"]], excess = f$stats[["B"]],
                           missing = f$stats[["M"]], n_obs_below = sum(bins$n[bins$region == "below"]),
                           n_at_139000 = apply_filters(dt[regime == g], filters)[v == 139000, .N])
  }
  q <- function(x, p) as.numeric(quantile(x, p, type = 2))
  summ <- rbindlist(est)
  summ[, `:=`(se = apply(draws, 2, sd)[period],
              ci_low = vapply(period, function(g) q(draws[, g], 0.025), numeric(1)),
              ci_high = vapply(period, function(g) q(draws[, g], 0.975), numeric(1)))]
  dd <- draws[, periods[1]] - draws[, periods[2]]
  summ <- rbind(summ, data.table(period = "diff", b = summ$b[1] - summ$b[2],
                                 excess = NA_real_, missing = NA_real_, n_obs_below = NA_integer_,
                                 n_at_139000 = NA_integer_, se = sd(dd),
                                 ci_low = q(dd, 0.025), ci_high = q(dd, 0.975)))
  list(summary = summ[, `:=`(strict = strict, reps = reps, seed = seed)][], draws = draws)
}

# group_bulk_window(): bulk entries (Karl's flag) with values in [from, to),
#   by regime and value, and the authorities with the most of them.
# Output: list(by_value, top_authorities (top_n per regime))
group_bulk_window <- function(dt, regimes, from, to, top_n = 5) {
  b <- dt[bulk == TRUE & regime %in% regimes & v >= from & v < to]
  b[, regime := as.character(regime)]
  by_value <- b[, .(n_bulk_lots = .N, n_cells = uniqueN(paste(cf_amministrazione_appaltante, ym)),
                    n_authorities = uniqueN(cf_amministrazione_appaltante)), by = .(regime, value = v)]
  setorder(by_value, regime, value)
  top <- b[, .(n_bulk_lots = .N, values = paste(format(sort(unique(v)), big.mark = ","), collapse = "; "),
               months = paste(sort(unique(ym)), collapse = "; ")),
           by = .(regime, cf_amministrazione_appaltante,
                  authority = denominazione_amministrazione_appaltante)]
  setorder(top, regime, -n_bulk_lots)
  top <- top[, head(.SD, top_n), by = regime]
  top[, share_of_regime_bulk := n_bulk_lots / b[, .N, by = regime][match(top$regime, regime), N]]
  list(by_value = by_value, top_authorities = top)
}

# group_band_summary(): summary of the B4 band ratios over the bands with lower
#   bound in GROUP_B4_SUMMARY_BANDS, i.e. (80k, 130k]: mean ratio and OLS slope
#   of log(ratio) on the band midpoint per 10,000 euro (as the D1 ramp).
group_band_summary <- function(b4) {
  r <- b4[band10 >= GROUP_B4_SUMMARY_BANDS[1] & band10 <= GROUP_B4_SUMMARY_BANDS[2]]
  co <- summary(lm(log(ratio) ~ I((band10 + 5) / 10), data = r))$coefficients
  data.table(bands = sprintf("(%dk, %dk]", GROUP_B4_SUMMARY_BANDS[1], GROUP_B4_SUMMARY_BANDS[2] + 10),
             n_bands = nrow(r), mean_ratio = mean(r$ratio), ramp_per_10k = co[2, 1],
             ramp_se = co[2, 2], ramp_p = co[2, 4])
}

# group_s1_fit(): impact share alpha and half-life of the group's adjustment
#   curve S1, recovered from its fitted column: fit(m) = 1 - (1 - alpha) exp(-lambda m),
#   so alpha = fit(0) and lambda = -log((1 - fit(1)) / (1 - alpha)).
group_s1_fit <- function(s1) {
  alpha <- s1[mo == 0, fit]
  lambda <- -log((1 - s1[mo == 1, fit]) / (1 - alpha))
  data.table(alpha = alpha, lambda = lambda, half_life = log(2) / lambda)
}

# group_tex_line(): one LaTeX row in the format of
#   repo_gruppe/results/tables/tex/I_bunch_sens_p1b.tex: label & b(P2) & b(P1b) & diff
group_tex_line <- function(label, b_p2, b_ctrl, diff) {
  sprintf("%s & %5.1f & %5.1f & %5.1f \\\\", label, b_p2, b_ctrl, diff)
}

# group_save_figure(): as save_figure(), into output/figures/.
group_save_figure <- function(p, name, height = 5, width = FIG_WIDTH) {
  png_path <- file.path(GROUP_FIG_DIR, paste0(name, ".png"))
  ggsave(png_path, p, width = width, height = height, dpi = FIG_DPI, bg = "white")
  ggsave(file.path(GROUP_FIG_DIR, paste0(name, ".pdf")), p, width = width, height = height,
         device = "pdf")
  msg("Saved figure figures/", basename(png_path), " + .pdf")
  invisible(png_path)
}

# group_plot_c2(): figure C2 of module C cut to September 2020 - June 2023
#   (event time -9 to +24 relative to June 2021), without the markers of P1a
#   and of the EU threshold. Same style as fig_C2_event_time.
# Input : ev (monthly series of 75k and 139k: columns ym_num, c, S), subtitle
#         first line, title (NULL = none)
group_plot_c2 <- function(ev, subtitle_first, title = "Bunching index around the switch from 75k to 139k (monthly)",
                          label_size = 2.5) {
  ev <- copy(ev)
  ev[, t := ym_num - ym_to_num(GROUP_INDEX$event_ref)]
  ev <- ev[t >= GROUP_INDEX$event_range[1] & t <= GROUP_INDEX$event_range[2]]
  ev[, threshold := factor(label_k(c), levels = c("75k", "139k"))]
  to_event <- function(d) event_time_of_date(d, GROUP_INDEX$event_ref)
  mk <- time_marker_table(to_event)[type == "switch" & !grepl("^P1a", label)]
  mk <- mk[x >= GROUP_INDEX$event_range[1] - 1 & x <= GROUP_INDEX$event_range[2] + 0.5]
  y_max <- max(100 * ev$S, na.rm = TRUE)
  ggplot(ev, aes(x = t, y = 100 * S, colour = threshold, shape = threshold)) +
    shade_regime(to_event) +
    time_markers(mk, label_size = label_size) +
    geom_line(linewidth = TS_LINEWIDTH) +
    geom_point(size = TS_POINT_SIZE) +
    scale_colour_manual(values = THRESHOLD_COLOURS[c("75k", "139k")], labels = function(x) paste0("c = ", x)) +
    scale_shape_manual(values = THRESHOLD_SHAPES[c("75k", "139k")], labels = function(x) paste0("c = ", x)) +
    scale_x_continuous(breaks = c(-9, seq(-6, 24, 6)), limits = GROUP_INDEX$event_range + c(-1.2, 0.6),
                       expand = expansion(mult = 0)) +
    scale_y_continuous(limits = c(0, y_max * 1.75), breaks = seq(0, 100, 5),
                       expand = expansion(mult = c(0, 0))) +
    labs(x = "Months relative to June 2021 (0 = June 2021, start of the 139k regime)",
         y = "Bunching index S (%)", title = title,
         subtitle = paste0(subtitle_first, "\n",
                           "Group sample, lots from 15 Sep 2020 to 30 Jun 2023 (September 2020 = 15-30 Sep).\n",
                           "Dashed lines: regime switches. Grey area: P1b (75k).")) +
    theme_karl() +
    theme(plot.subtitle = element_text(size = 9))
}

# group_plot_s1(): the group's adjustment curve S1 (S1_adjustment_curve_p1b.csv)
#   redrawn in Karl's style: estimate with 95 % interval and the fitted curve
#   1 - (1 - a) exp(-l m); dotted lines at 0 and 1.
#   fit_label = legend label of the fitted curve (shorter in the paper version).
group_plot_s1 <- function(s1, title = NULL, subtitle = NULL, fit_label = "Fitted 1 - (1 - a) exp(-l m)") {
  col <- THRESHOLD_COLOURS[["139k"]]
  s1 <- copy(s1)[, `:=`(est_lab = "Estimate (95% CI)", fit_lab = fit_label)]
  ggplot(s1, aes(x = mo)) +
    geom_hline(yintercept = c(0, 1), linetype = "dotted", colour = "grey40", linewidth = 0.4) +
    geom_errorbar(aes(ymin = lo, ymax = hi, colour = est_lab), width = 0.35,
                  linewidth = 0.4, alpha = 0.6) +
    geom_line(aes(y = fit, colour = fit_lab), linetype = "dashed",
              linewidth = 0.7) +
    geom_point(aes(y = closed, colour = est_lab), shape = 17, size = TS_POINT_SIZE) +
    scale_colour_manual(values = setNames(c(col, "black"), c("Estimate (95% CI)", fit_label)),
                        guide = guide_legend(override.aes = list(linetype = c("blank", "dashed"),
                                                                 shape = c(17, NA), alpha = 1))) +
    scale_x_continuous(breaks = seq(0, 21, 3), limits = c(-0.6, 21.6), expand = expansion(mult = 0)) +
    scale_y_continuous(breaks = seq(0, 1.2, 0.2), limits = c(0, 1.25)) +
    labs(x = "Months since 1 June 2021", y = "Share of the adjustment completed",
         title = title, subtitle = subtitle) +
    theme_karl() +
    theme(plot.subtitle = element_text(size = 9))
}

# =============================================================================
# Paper versions of figures G2a and G2b (Karl's request, 2026-11-18)
# Contents: group_plot_c2_paper(), group_paper_figures()
# Only the bulk-filter variant; same numbers as the figures above. Changes:
# y axis 0-20 %, no P3 line, no titles or subtitles (the panel figure has only
# the two panel headings), no rotated labels at the dashed lines (horizontal
# "75k regime" / "139k regime" at the top instead), September 2020 (15-30 Sep
# only) as a hollow symbol, width 16 cm (one A4 text column), all text at least
# 9 pt in print (paper_figure() of fn_plots.R).
# =============================================================================
GROUP_PAPER <- list(
  width = 16 / 2.54,                     # 16 cm in inches
  height_c2 = 3.6, height_panel = 3.9,   # inches
  y_max = 20,                            # y axis of C2 in percent
  text_pt = 9.5,                         # text written into the panels
  title_a = "(a) Take-up of direct award at 139k",
  title_b = "(b) Lots just below the threshold",
  y_label_c2 = "Share of lots in the last EUR 1,000\nbelow the threshold (%)",
  y_label_s1 = "Share of the adjustment completed"
)

# group_plot_c2_paper(): print version of C2 (see the header of this section).
# Input : ev (monthly series of 75k and 139k: columns ym, ym_num, c, S),
#         x_label, y_label, regime_labels (text in the grey area and right of it),
#         label_top (top of these labels as a share of the y axis), label_lineheight
# Output: ggplot object (apply paper_figure() before saving)
group_plot_c2_paper <- function(ev, x_label = "Months relative to June 2021 (0 = June 2021)",
                                y_label = GROUP_PAPER$y_label_c2,
                                regime_labels = c("75k regime", "139k regime"),
                                label_top = 0.96, label_lineheight = 0.9) {
  ev <- copy(ev)
  ev[, t := ym_num - ym_to_num(GROUP_INDEX$event_ref)]
  ev <- ev[t >= GROUP_INDEX$event_range[1] & t <= GROUP_INDEX$event_range[2]]
  if (max(100 * ev$S, na.rm = TRUE) > GROUP_PAPER$y_max) {
    stop("A value lies above the y-axis limit of the paper version of C2.")
  }
  ev[, threshold := factor(label_k(c), levels = c("75k", "139k"))]
  ev[, partial := ym == GROUP_INDEX$first_ym]          # September 2020: 15-30 Sep only
  part <- ev[partial == TRUE]
  hollow <- c(`75k` = 21, `139k` = 24)[as.character(part$threshold)]   # fillable circle / triangle
  to_event <- function(d) event_time_of_date(d, GROUP_INDEX$event_ref)
  x_p1b <- to_event(REGIMES[regime == "P1b", start])
  x_p2  <- to_event(REGIMES[regime == "P2", start])
  txt <- GROUP_PAPER$text_pt / ggplot2::.pt
  y_txt <- GROUP_PAPER$y_max * label_top
  ggplot(ev, aes(x = t, y = 100 * S, colour = threshold, shape = threshold)) +
    shade_regime(to_event) +
    geom_vline(xintercept = c(x_p1b, x_p2), linetype = "dashed", colour = "grey40", linewidth = 0.4) +
    annotate("text", x = (x_p1b + x_p2) / 2, y = y_txt, label = regime_labels[1], size = txt,
             colour = "grey20", vjust = 1, lineheight = label_lineheight) +
    annotate("text", x = x_p2 + 0.6, y = y_txt, label = regime_labels[2], size = txt,
             colour = "grey20", hjust = 0, vjust = 1, lineheight = label_lineheight) +
    geom_line(linewidth = TS_LINEWIDTH) +
    geom_point(data = ev[partial == FALSE], size = TS_POINT_SIZE) +
    geom_point(data = part, shape = unname(hollow), fill = "white", size = TS_POINT_SIZE,
               stroke = 0.9, show.legend = FALSE) +
    scale_colour_manual(values = THRESHOLD_COLOURS[c("75k", "139k")], labels = function(x) paste0("c = ", x)) +
    scale_shape_manual(values = THRESHOLD_SHAPES[c("75k", "139k")], labels = function(x) paste0("c = ", x)) +
    scale_x_continuous(breaks = c(-9, seq(-6, 24, 6)), limits = GROUP_INDEX$event_range + c(-1.2, 0.6),
                       expand = expansion(mult = 0)) +
    scale_y_continuous(limits = c(0, GROUP_PAPER$y_max), breaks = seq(0, GROUP_PAPER$y_max, 5),
                       expand = expansion(mult = 0)) +
    labs(x = x_label, y = y_label) +
    theme_karl()
}

# group_paper_figures(): write the two paper versions (bulk-filter variant).
# Input : ev (monthly series with the bulk filter, 2020-09 to 2023-06), s1 (the
#         group's S1_adjustment_curve_p1b.csv), which ("c2" and/or "panel":
#         the figures to write)
# Output: fig_G2a_C2_event_time_bulk_filter_paper and
#         fig_G2b_S1_C2_panel_bulk_filter_paper (PNG 300 dpi and PDF)
# In the panel, (b) has the short y-axis title "Share just below c (%)" and both
# panels have the same width (Karl, 2026-11-18).
group_paper_figures <- function(ev, s1, which = c("c2", "panel")) {
  if ("c2" %in% which) {
    p_c2 <- paper_figure(group_plot_c2_paper(ev))
    group_save_figure(p_c2, "fig_G2a_C2_event_time_bulk_filter_paper",
                      height = GROUP_PAPER$height_c2, width = GROUP_PAPER$width)
  }
  if ("panel" %in% which) {
    p_a <- paper_figure(group_plot_s1(s1, fit_label = "Fitted curve")) +
      labs(title = GROUP_PAPER$title_a, y = "Share of the adjustment\ncompleted")
    p_b <- paper_figure(group_plot_c2_paper(ev, x_label = "Months relative to June 2021",
                                            y_label = "Share just below c (%)",
                                            regime_labels = c("75k\nregime", "139k\nregime"),
                                            label_top = 0.99, label_lineheight = 0.8)) +
      labs(title = GROUP_PAPER$title_b)
    p_panel <- (p_a + p_b + plot_layout(widths = c(1, 1))) &
      theme(plot.title = element_text(size = PAPER_MIN_PT + 1.5, face = "bold"))
    group_save_figure(p_panel, "fig_G2b_S1_C2_panel_bulk_filter_paper",
                      height = GROUP_PAPER$height_panel, width = GROUP_PAPER$width)
  }
  invisible(TRUE)
}
