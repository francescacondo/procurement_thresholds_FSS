# =============================================================================
# fn_shape.R -- Module D: global shape of the distribution (D1-D5)
# -----------------------------------------------------------------------------
# Contents: shape_counts(), density_ratios(), all_density_ratios(),
#           ratio_level_ramp(), mass_accounting(), mass_changes(),
#           value_quantiles(), powerlaw_counts(), fit_powerlaw(),
#           relative_density(), nw_vcov(), its_data(), its_regression(),
#           switch_window_means()
# All functions take the sample filters as a parameter (module F).
# =============================================================================

# shape_counts(): counts per regime and value bin for the density ratios (D1),
#   plus the normalisation constants N of every regime.
# Input : dt          lot-level data (data/lots_all.rds; the reference band
#                     250k-1M is needed for normalisation (i))
#         bin_width   width of the value bins (5000 in the spec)
#         v_range     bins cover v_range[1] <= v < v_range[2] (45k-250k)
#         filters     sample filters (see default_filters())
# Output: list with
#         counts: regime, bin, n_all (all lots), n_nonround (lots that are not
#                 a multiple of 1,000 = numerator of R, spec 9.4)
#         norms : regime, N_ref_all, N_ref_nonround (lots 250k-1M),
#                 N_out_all, N_out_nonround (lots 45k-250k outside 65k-85k
#                 and 125k-160k), months
shape_counts <- function(dt, bin_width = 5000, v_range = WINDOW,
                         filters = default_filters()) {
  d <- apply_filters(dt, filters)
  w <- d[v >= v_range[1] & v < v_range[2]]
  w[, bin := floor(v / bin_width) * bin_width]
  counts <- w[, .(n_all = .N, n_nonround = sum(!round_1k)), by = .(regime, bin)]
  grid <- CJ(regime = sort(unique(d$regime)),
             bin = seq(v_range[1], v_range[2] - bin_width, by = bin_width))
  counts <- merge(grid, counts, by = c("regime", "bin"), all.x = TRUE)
  counts[is.na(n_all), `:=`(n_all = 0L, n_nonround = 0L)]

  # Normalisation (ii): window 45k-250k without the ranges around the thresholds
  in_norm2 <- d$v >= WINDOW[1] & d$v < WINDOW[2]
  for (r in D1_NORM_II_EXCLUDE) in_norm2 <- in_norm2 & !(d$v >= r[1] & d$v < r[2])
  d[, in_norm2 := in_norm2]
  norms <- d[, .(N_ref_all      = sum(v >= REF_BAND[1] & v < REF_BAND[2]),
                 N_ref_nonround = sum(v >= REF_BAND[1] & v < REF_BAND[2] & !round_1k),
                 N_out_all      = sum(in_norm2),
                 N_out_nonround = sum(in_norm2 & !round_1k)), by = regime]
  norms <- merge(norms, regime_months(filters)[, .(regime, months)], by = "regime")
  list(counts = counts[], norms = norms[])
}

# density_ratios(): R_j = (n_ja / N_a) / (n_jb / N_b) for one regime pair and
#   one normalisation, with a 95 % confidence interval from the Poisson
#   approximation SE(log R_j) = sqrt(1/n_ja + 1/n_jb + 1/N_a + 1/N_b).
# Input : sc        output of shape_counts()
#         a, b      regimes (numerator, denominator), e.g. "P2", "P1b"
#         norm      "i_ref" (lots 250k-1M), "ii_outside" (lots 45k-250k outside
#                   65k-85k and 125k-160k) or "iii_months" (months of the regime)
#         N_variant "all" (N counts all lots; main variant, decision K1) or
#                   "nonround" (N without lots with round_1k). Ignored for months.
# Output: data.table, one row per bin. For "iii_months" N is not a count, so
#         its 1/N terms are left out of the SE (decision D20).
density_ratios <- function(sc, a, b, norm = "i_ref", N_variant = "all") {
  if (norm == "iii_months") N_variant <- "-"
  N_col <- switch(norm,
                  i_ref      = paste0("N_ref_", N_variant),
                  ii_outside = paste0("N_out_", N_variant),
                  iii_months = "months",
                  stop("unknown normalisation: ", norm))
  Na <- sc$norms[regime == a][[N_col]]
  Nb <- sc$norms[regime == b][[N_col]]
  ca <- sc$counts[regime == a, .(bin, n_a = n_nonround)]
  cb <- sc$counts[regime == b, .(bin, n_b = n_nonround)]
  out <- merge(ca, cb, by = "bin")
  bin_width <- diff(sort(unique(sc$counts$bin)))[1]
  N_var_term <- if (norm == "iii_months") 0 else 1 / Na + 1 / Nb
  out[, `:=`(pair = paste0(a, "/", b), a = a, b = b, norm = norm, N_variant = N_variant,
             bin_mid = bin + bin_width / 2, N_a = Na, N_b = Nb)]
  out[, R := fifelse(n_a > 0 & n_b > 0, (n_a / N_a) / (n_b / N_b), NA_real_)]
  out[, se_log_R := fifelse(n_a > 0 & n_b > 0, sqrt(1 / n_a + 1 / n_b + N_var_term), NA_real_)]
  out[, `:=`(ci_low = R * exp(-1.96 * se_log_R), ci_high = R * exp(1.96 * se_log_R))]
  out[, ci_excludes_1 := !is.na(R) & (ci_low > 1 | ci_high < 1)]
  setcolorder(out, c("pair", "a", "b", "norm", "N_variant", "bin", "bin_mid",
                     "n_a", "n_b", "N_a", "N_b", "R", "se_log_R", "ci_low", "ci_high"))
  out[]
}

# all_density_ratios(): density_ratios() for every pair in `pairs` and every
#   normalisation (main N variant "all" plus the alternative "nonround").
# Output: one long data.table
all_density_ratios <- function(sc, pairs = D1_PAIRS) {
  combos <- data.table(norm      = c("i_ref", "i_ref", "ii_outside", "ii_outside", "iii_months"),
                       N_variant = c("all", "nonround", "all", "nonround", "-"))
  rbindlist(lapply(seq_len(nrow(pairs)), function(i) {
    rbindlist(lapply(seq_len(nrow(combos)), function(k) {
      density_ratios(sc, pairs$a[i], pairs$b[i], combos$norm[k], combos$N_variant[k])
    }))
  }))
}

# ratio_level_ramp(): summary of the density ratios in one value range
#   (default 75k-125k, spec 9.4):
#   level = arithmetic mean of R_j over the bins in the range,
#   ramp  = slope of an OLS regression of log R_j on the bin midpoint
#           (log points per 10,000 euro), with its standard error.
#   level_se = delta-method SE of the level under the Poisson approximation of
#           spec 9.4 (all counts independent Poisson; decision D33):
#           Var(level) = sum_j (R_j / K)^2 (1/n_ja + 1/n_jb) + level^2 (1/N_a + 1/N_b),
#           K = number of bins. For normalisation (iii) N is not a count and
#           its term is left out (as in D20).
# Input : ratios (output of density_ratios / all_density_ratios), range
# Output: one row per pair x normalisation x N variant
ratio_level_ramp <- function(ratios, range = D1_LEVEL_RANGE) {
  r <- ratios[bin >= range[1] & bin < range[2] & !is.na(R)]
  r[, {
    fit <- lm(log(R) ~ I(bin_mid / 10000))
    co  <- summary(fit)$coefficients
    K   <- .N
    lvl <- mean(R)
    N_term <- if (norm[1] == "iii_months") 0 else 1 / N_a[1] + 1 / N_b[1]
    lvl_se <- sqrt(sum((R / K)^2 * (1 / n_a + 1 / n_b)) + lvl^2 * N_term)
    .(n_bins = K, level = lvl, level_se = lvl_se, ramp_per_10k = co[2, 1], ramp_se = co[2, 2],
      ramp_p = co[2, 4], N_a = N_a[1], N_b = N_b[1], n_a_range = sum(n_a), n_b_range = sum(n_b))
  }, by = .(pair, a, b, norm, N_variant)]
}

# mass_accounting(): lots and value per month by value band and regime (D3),
#   with the share of each band in the window 45k-250k and the ratio to the
#   reference band.
# Input : dt (lot-level data incl. the reference band), bands (BANDS),
#         filters
# Output: data.table, one row per regime x band: n, lots_per_month,
#         value_per_month_meur (million euro), share_window (share of the band
#         among the lots 45k-250k; NA for the reference band), ratio_to_ref
#         (lots of the band / lots of the reference band)
mass_accounting <- function(dt, bands = BANDS, filters = default_filters()) {
  d <- apply_filters(dt, filters)
  d[, band := assign_band(v, bands)]
  lv <- d[!is.na(band), .(n = .N, value_sum = sum(v)), by = .(regime, band)]
  grid <- CJ(regime = sort(unique(d$regime)), band = factor(bands$band, levels = bands$band))
  lv <- merge(grid, lv, by = c("regime", "band"), all.x = TRUE)
  lv[is.na(n), `:=`(n = 0L, value_sum = 0)]
  lv <- merge(lv, regime_months(filters)[, .(regime, months)], by = "regime")
  ref_label <- bands$band[bands$lower >= REF_BAND[1]]
  lv[, in_window := !band %in% ref_label]
  lv[, `:=`(lots_per_month = n / months,
            value_per_month_meur = value_sum / months / 1e6)]
  lv[, share_window := fifelse(in_window, n / sum(n[in_window]), NA_real_), by = regime]
  lv[, ratio_to_ref := n / n[band %in% ref_label], by = regime]
  setorder(lv, regime, band)
  lv[]
}

# mass_changes(): change of every band between two regimes (D3).
# Input : levels (output of mass_accounting), from, to (regimes)
# Output: one row per band: lots per month, value per month and window share
#         in both regimes, absolute and percent changes, change of the ratio
#         to the reference band (percent) and of the window share (percentage
#         points and percent)
mass_changes <- function(levels, from, to) {
  f <- levels[regime == from]
  t <- levels[regime == to]
  out <- merge(f[, .(band, lpm_from = lots_per_month, vpm_from = value_per_month_meur,
                     share_from = share_window, ref_from = ratio_to_ref)],
               t[, .(band, lpm_to = lots_per_month, vpm_to = value_per_month_meur,
                     share_to = share_window, ref_to = ratio_to_ref)], by = "band")
  out[, `:=`(transition = paste0(from, "->", to),
             d_lots_per_month = lpm_to - lpm_from,
             pct_lots_per_month = 100 * (lpm_to / lpm_from - 1),
             d_value_per_month_meur = vpm_to - vpm_from,
             pct_value_per_month = 100 * (vpm_to / vpm_from - 1),
             pct_ratio_to_ref = 100 * (ref_to / ref_from - 1),
             d_share_window_pp = 100 * (share_to - share_from),
             pct_share_window = 100 * (share_to / share_from - 1))]
  setcolorder(out, c("transition", "band"))
  setorder(out, band)
  out[]
}

# value_quantiles(): percentiles of the lot value within a value range, per
#   regime (D4). R's default quantile definition (type 7) is used.
# Input : dt, probs (default deciles 10-90 %), v_range (45k-250k), filters
# Output: data.table with columns regime, p (in %), q (euro), n
value_quantiles <- function(dt, probs = seq(0.1, 0.9, by = 0.1), v_range = WINDOW,
                            filters = default_filters()) {
  d <- apply_filters(dt, filters)[v >= v_range[1] & v < v_range[2]]
  d[, .(p = round(100 * probs), q = as.numeric(quantile(v, probs, type = 7)), n = .N),
    by = regime][order(regime, p)]
}

# =============================================================================
# D2: piecewise power law (spec 9.4)
# =============================================================================

# powerlaw_counts(): lots per 1k bin and regime for D2, with the segment of
#   each bin and the log of the bin midpoint.
# Input : dt, segments (D2_SEGMENTS: segment, from, to), bin_width, filters
# Output: data.table, one row per regime x bin in min(from) <= v < max(to):
#         regime, bin, n (all lots), n_nonround (lots that are not a multiple
#         of 1,000 = the counts used in D2), months, segment (NA for bins
#         between the segments), log_v (log of the bin midpoint)
powerlaw_counts <- function(dt, segments = D2_SEGMENTS, bin_width = 1000,
                            filters = default_filters()) {
  bins <- aggregate_bins(dt, bin_width = bin_width, filters = filters, by = "regime",
                         v_min = min(segments$from), v_max = max(segments$to))
  bins <- merge(bins, regime_months(filters)[, .(regime, months)], by = "regime")
  seg_idx <- findInterval(bins$bin, segments$from)
  seg_idx[seg_idx == 0] <- NA
  inside <- !is.na(seg_idx) & bins$bin < segments$to[pmax(seg_idx, 1)]
  bins[, segment := fifelse(inside, segments$segment[seg_idx], NA_character_)]
  bins[, log_v := log(bin + bin_width / 2)]
  bins[, .(regime, bin, n, n_nonround, months, segment, log_v)]
}

# fit_powerlaw(): Poisson regression of D2 for one segment and one pair of regimes
#     E[n_jr] = exp(alpha + delta * D_r + beta * l_j + theta * D_r * l_j + log(months_r))
#   D_r = 1 for the comparison regime (P2 in the spec), 0 for the base regime;
#   l_j = log(bin midpoint) minus its mean over the bins of the segment.
#   delta = level shift (log points, at the centre of the segment), beta = slope
#   (elasticity of the density with respect to the lot value) in the base
#   regime, theta = change of the slope. Heteroskedasticity-robust SE.
# Input : counts (output of powerlaw_counts), base, comp (regimes), segment_id
# Output: list with row (one-row data.table of estimates) and fitted (the bins
#         with the fitted lots per month, for the figure)
fit_powerlaw <- function(counts, base, comp, segment_id) {
  d <- counts[segment == segment_id & regime %in% c(base, comp)]
  d[, l_c := log_v - mean(log_v)]            # both regimes have the same bins
  d[, D := as.integer(regime == comp)]
  fit <- fixest::fepois(n_nonround ~ D * l_c, data = d, offset = ~log(months),
                        vcov = "hetero", notes = FALSE)
  ct <- fixest::coeftable(fit)
  g  <- function(term, col) unname(ct[term, col])
  row <- data.table(
    comparison = paste(comp, "vs", base), base = base, comp = comp, segment = segment_id,
    from = min(d$bin), to = max(d$bin) + 1000, n_bins = uniqueN(d$bin),
    lots_base = d[regime == base, sum(n_nonround)], lots_comp = d[regime == comp, sum(n_nonround)],
    alpha = g("(Intercept)", 1), alpha_se = g("(Intercept)", 2),
    delta = g("D", 1), delta_se = g("D", 2), delta_p = g("D", 4),
    beta = g("l_c", 1), beta_se = g("l_c", 2), beta_p = g("l_c", 4),
    theta = g("D:l_c", 1), theta_se = g("D:l_c", 2), theta_p = g("D:l_c", 4))
  row[, `:=`(level_change_pct = 100 * (exp(delta) - 1), beta_comp = beta + theta)]
  d[, fitted_per_month := fitted(fit) / months]
  list(row = row, fitted = d[, .(base = base, comp = comp, regime, bin, segment, log_v,
                                 n_nonround, months, fitted_per_month)])
}

# =============================================================================
# D5: relative density index (Karl, decision K8)
# =============================================================================

# relative_density(): L_t = lots in [num_from, num_to) / lots in [den_from, den_to)
#   per month or quarter (quarter: counts pooled, as in D16). All lots incl.
#   round amounts; filters as in the main analysis (no bulk entries).
# Input : dt, indices (D5_INDICES), by ("ym" or "quarter"), filters
# Output: long data.table: <by>, index, n_num, n_den, L, log_L
relative_density <- function(dt, indices = D5_INDICES, by = "ym", filters = default_filters()) {
  d <- apply_filters(dt, filters)
  grid <- unique(month_table()[, by, with = FALSE])
  rbindlist(lapply(seq_len(nrow(indices)), function(i) {
    ix <- indices[i]
    cnt <- d[, .(n_num = sum(v >= ix$num_from & v < ix$num_to),
                 n_den = sum(v >= ix$den_from & v < ix$den_to)), by = by]
    cnt <- merge(grid, cnt, by = by, all.x = TRUE)
    cnt[is.na(n_num), `:=`(n_num = 0L, n_den = 0L)]
    cnt[, `:=`(index = ix$index,
               L = fifelse(n_den > 0, n_num / n_den, NA_real_))]
    cnt[, log_L := log(L)]
    setcolorder(cnt, c(by, "index"))
    cnt[]
  }))
}

# nw_vcov(): Newey-West covariance matrix of OLS coefficients (Bartlett weights
#   1 - l / (lag + 1)). Lags are counted in calendar months, so that two
#   observations count as l months apart only if their month numbers differ
#   by l (the months 2020-07 and 2020-09 are missing in D5).
# Input : fit (lm object), time (integer month number of every observation),
#         lag (number of lags), small_sample (TRUE: multiply by n / (n - k),
#         as Stata's newey)
# Output: k x k covariance matrix
nw_vcov <- function(fit, time, lag, small_sample = TRUE) {
  X <- model.matrix(fit)
  u <- X * residuals(fit)            # score of each observation (one row each)
  S <- crossprod(u)                  # lag 0
  for (l in seq_len(lag)) {
    j  <- match(time + l, time)      # observation exactly l months later
    ok <- !is.na(j)
    G  <- crossprod(u[ok, , drop = FALSE], u[j[ok], , drop = FALSE])
    S  <- S + (1 - l / (lag + 1)) * (G + t(G))
  }
  bread <- solve(crossprod(X))
  V <- bread %*% S %*% bread
  if (small_sample) V <- V * nrow(X) / (nrow(X) - ncol(X))
  V
}

# its_data(): monthly series of one index prepared for the interrupted time
#   series: regime dummies (base P0), month-of-year factor and trend; months
#   with a regime switch inside (2020-07, 2020-09) are dropped.
its_data <- function(series) {
  d <- merge(series, month_table()[, .(ym, ym_num, regime, regime_mixed)], by = "ym")
  d <- d[regime_mixed == FALSE & is.finite(log_L)]
  for (r in setdiff(REGIME_LEVELS, "P0")) set(d, j = paste0("d_", r), value = as.integer(d$regime == r))
  d[, month_of_year := factor(substr(ym, 6, 7))]
  d[, trend := ym_num]
  setorder(d, ym_num)
  d[]
}

# its_regression(): interrupted time series of D5 (b):
#     log(L_t) = a + sum_r b_r * D_r,t + month-of-year dummies (+ g * t) + e_t
#   with regime dummies P1a, P1b, P2, P3 (base P0), estimated by OLS with
#   Newey-West standard errors (D5_NW_LAG lags). The jump between two regimes
#   is the difference of their coefficients (P0 = 0), reported in log points
#   and as 100 * (exp(d) - 1) percent; the SE of a difference uses the full
#   covariance matrix: Var(b2 - b1) = Var(b2) + Var(b1) - 2 Cov(b1, b2).
# Input : series (monthly relative_density() output for ONE index),
#         trend (TRUE/FALSE), lag, transitions (D5_TRANSITIONS)
# Output: list with jumps (one row per transition) and fit (lm object), data,
#         vcov
its_regression <- function(series, trend = FALSE, lag = D5_NW_LAG, transitions = D5_TRANSITIONS) {
  d <- its_data(series)
  # Regime dummies without any month in the data are left out (robustness
  # check F7 drops 2020-08, the only full month of P1a); jumps from or to such
  # a regime are NA. In the main analysis all four dummies are used.
  dums <- paste0("d_", setdiff(REGIME_LEVELS, "P0"))
  dums <- dums[vapply(dums, function(x) any(d[[x]] == 1), logical(1))]
  fml <- as.formula(paste("log_L ~", paste(c(dums, "month_of_year"), collapse = " + ")))
  if (trend) fml <- update(fml, . ~ . + trend)
  fit <- lm(fml, data = d)
  V <- nw_vcov(fit, d$ym_num, lag)
  b <- coef(fit)
  jumps <- rbindlist(lapply(seq_len(nrow(transitions)), function(i) {
    tr <- transitions[i]
    needed <- paste0("d_", setdiff(c(tr$from, tr$to), "P0"))
    if (!all(needed %in% names(b))) {
      return(data.table(transition = tr$transition, d_log = NA_real_, se_log = NA_real_, p = NA_real_,
                        pct = NA_real_, pct_se = NA_real_, pct_ci_low = NA_real_, pct_ci_high = NA_real_))
    }
    g <- setNames(rep(0, length(b)), names(b))
    if (tr$to   != "P0") g[paste0("d_", tr$to)]   <- 1
    if (tr$from != "P0") g[paste0("d_", tr$from)] <- -1
    est <- sum(g * b)
    se  <- sqrt(as.numeric(t(g) %*% V %*% g))
    data.table(transition = tr$transition, d_log = est, se_log = se,
               p = 2 * pnorm(-abs(est / se)),
               pct = 100 * (exp(est) - 1), pct_se = 100 * exp(est) * se,   # delta method
               pct_ci_low = 100 * (exp(est - 1.96 * se) - 1),
               pct_ci_high = 100 * (exp(est + 1.96 * se) - 1))
  }))
  jumps[, `:=`(index = series$index[1], trend = trend, n_months = nrow(d), r2 = summary(fit)$r.squared,
               trend_per_year = if (trend) 12 * b[["trend"]] else NA_real_,
               trend_per_year_se = if (trend) 12 * sqrt(V["trend", "trend"]) else NA_real_)]
  setcolorder(jumps, c("index", "trend", "transition"))
  list(jumps = jumps, fit = fit, data = d, vcov = V)
}

# switch_window_means(): D5 (c): mean of log(L_t) in the 6 months after a
#   regime switch minus the mean in the 6 months before (months as in
#   D5_TRANSITIONS). se_naive = sqrt(var_before / 6 + var_after / 6) ignores
#   autocorrelation and seasonality and is only a rough guide.
# Input : series (monthly relative_density() output for ONE index), transitions
# Output: one row per transition
switch_window_means <- function(series, transitions = D5_TRANSITIONS) {
  rbindlist(lapply(seq_len(nrow(transitions)), function(i) {
    tr <- transitions[i]
    bef <- series[ym >= tr$before_from & ym <= tr$before_to, log_L]
    aft <- series[ym >= tr$after_from & ym <= tr$after_to, log_L]
    data.table(index = series$index[1], transition = tr$transition,
               months_before = paste(tr$before_from, "to", tr$before_to),
               months_after = paste(tr$after_from, "to", tr$after_to),
               n_before = length(bef), n_after = length(aft),
               mean_log_before = mean(bef), mean_log_after = mean(aft),
               d_log = mean(aft) - mean(bef),
               se_naive = sqrt(var(bef) / length(bef) + var(aft) / length(aft)))
  }))[, pct := 100 * (exp(d_log) - 1)][]
}
