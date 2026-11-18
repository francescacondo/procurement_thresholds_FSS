# =============================================================================
# fn_dynamics.R -- Module C: bunching index over time and its dynamics
# -----------------------------------------------------------------------------
# Contents: ym_to_num(), quarter_mid_date(), event_time_of_date(),
#           bunching_index(), index_series(), period_mean(), buildup_time(),
#           excess_share(), decay_first_below(), empty_decay_fit(), fit_decay(),
#           dynamics_metrics()
# All functions take the sample filters as a parameter, so that modules E and
# F can re-run them on another sample (e.g. without central authorities).
# Index (spec 9.3):  S_{c,t} = N_t([c - 1000, c)) / N_t([c - 20000, c + 20000))
# =============================================================================

# ym_to_num(): month label "2021-06" -> running month number (2018-01 = 1).
ym_to_num <- function(ym) {
  (as.integer(substr(ym, 1, 4)) - 2018L) * 12L + as.integer(substr(ym, 6, 7))
}

# quarter_mid_date(): quarter label "2021Q3" -> the 15th of its middle month
#   (2021-08-15). Used to place quarterly values on a date axis.
quarter_mid_date <- function(quarter) {
  y <- as.integer(substr(quarter, 1, 4))
  q <- as.integer(substr(quarter, 6, 6))
  as.Date(sprintf("%d-%02d-15", y, (q - 1L) * 3L + 2L))
}

# event_time_of_date(): position of a calendar date on an event-time axis in
#   months. Month m relative to ref_ym is drawn at x = m and covers
#   [m - 0.5, m + 0.5); e.g. with ref_ym = "2021-06" the date 2021-06-01 lies
#   at -0.5 and 2020-01-01 at -17.5.
# Input : date (Date or IDate vector), ref_ym (month label of event time 0)
# Output: numeric vector
event_time_of_date <- function(date, ref_ym) {
  date  <- as.Date(date)
  first <- as.Date(format(date, "%Y-%m-01"))
  next_first <- as.Date(vapply(first, function(d) as.numeric(seq(d, by = "month", length.out = 2)[2]),
                               numeric(1)), origin = "1970-01-01")
  days_in_month <- as.numeric(next_first - first)
  m <- ym_to_num(format(date, "%Y-%m")) - ym_to_num(ref_ym)
  m - 0.5 + (as.numeric(format(date, "%d")) - 1) / days_in_month
}

# bunching_index(): share of the lots just below a threshold among the lots
#   around it, per month or per quarter.
# Input : dt          lot-level data (data/lots_45_250.rds or lots_all.rds)
#         c           threshold in euro (e.g. 139000)
#         num_width   width of the numerator interval [c - num_width, c);
#                     1000 = main index, 2000 = variant
#         half_window half width of the denominator interval (20000)
#         by          "ym" (month) or "quarter"
#         filters     sample filters (see default_filters())
#         exclude_values  exact lot values that are left out of the numerator
#                     AND the denominator, e.g. 139000 for the S_140 variant
#                     without the lots at exactly 139,000 (decision K7).
#                     NULL (default) = main index.
# Output: data.table with columns <by>, (ym_num), c, num_width, variant
#         ("main", or e.g. "excl_139000"), n_num, n_den, S.
#         Every month/quarter 2018-2023 appears; S = NA if n_den = 0.
#         Quarterly values pool the counts of the quarter (sum of numerators
#         divided by sum of denominators).
bunching_index <- function(dt, c, num_width = 1000, half_window = 20000,
                           by = "ym", filters = default_filters(),
                           exclude_values = NULL) {
  if (!by %in% c("ym", "quarter")) stop("by must be 'ym' or 'quarter'.")
  # The lot data have a column "c" (threshold in force). Inside dt[...] the name
  # c would refer to that column, so the argument is copied to "thr".
  thr <- c
  d <- apply_filters(dt, filters)
  d <- d[v >= thr - half_window & v < thr + half_window]
  variant <- "main"
  if (!is.null(exclude_values)) {
    d <- d[!v %in% exclude_values]
    variant <- paste0("excl_", paste(exclude_values, collapse = "_"))
  }
  out <- d[, .(n_num = sum(v >= thr - num_width & v < thr), n_den = .N), by = by]
  grid <- unique(month_table()[, by, with = FALSE])        # all months / quarters
  out <- merge(grid, out, by = by, all.x = TRUE)
  out[is.na(n_den), `:=`(n_num = 0L, n_den = 0L)]
  out[, S := fifelse(n_den > 0, n_num / n_den, NA_real_)]
  out[, `:=`(c = thr, num_width = num_width, variant = variant)]
  if (by == "ym") out[, ym_num := ym_to_num(ym)]
  setcolorder(out, intersect(c(by, "ym_num", "c", "num_width", "variant", "n_num", "n_den", "S"),
                             names(out)))
  out[]
}

# index_series(): bunching_index() for several thresholds and numerator widths.
# Output: one long data.table (rows = threshold x numerator width x period)
index_series <- function(dt, thresholds = DYNAMICS_SETUP$c, num_widths = c(1000, 2000),
                         by = "ym", filters = default_filters()) {
  rbindlist(lapply(thresholds, function(cc) {
    rbindlist(lapply(num_widths, function(w) {
      bunching_index(dt, cc, num_width = w, by = by, filters = filters)
    }))
  }))
}

# period_mean(): arithmetic mean of the monthly index over the months
#   from ... to (inclusive), as decided in DECISIONS.md (P1).
# Input : series (monthly output of bunching_index for one c and width)
period_mean <- function(series, from, to) {
  series[ym_num >= ym_to_num(from) & ym_num <= ym_to_num(to), mean(S, na.rm = TRUE)]
}

# buildup_time(): months from the regime start (start month = month 0, decision
#   P2) until the monthly index first reaches the target value.
# Output: integer, NA if the target is never reached
buildup_time <- function(series, start_ym, target) {
  s <- series[ym_num >= ym_to_num(start_ym)][order(ym_num)]
  hit <- s[!is.na(S) & S >= target]
  if (nrow(hit) == 0) return(NA_integer_)
  as.integer(hit$ym_num[1] - ym_to_num(start_ym))
}

# excess_share(): excess of the index over the pre-level, as a share of the
#   plateau excess: (S_t - pre) / (plateau - pre).
excess_share <- function(S, pre, plateau) (S - pre) / (plateau - pre)

# decay_first_below(): months from t0 (= month 0) until the excess first falls
#   below `share` (0.5) of the plateau excess (fallback measure of spec 9.3).
# Output: integer, NA if this does not happen before end_ym
decay_first_below <- function(series, t0_ym, end_ym, pre, plateau, share = 0.5) {
  s <- series[ym_num >= ym_to_num(t0_ym) & ym_num <= ym_to_num(end_ym)][order(ym_num)]
  hit <- s[!is.na(S) & excess_share(S, pre, plateau) < share]
  if (nrow(hit) == 0) return(NA_integer_)
  as.integer(hit$ym_num[1] - ym_to_num(t0_ym))
}

# empty_decay_fit(): the result row of fit_decay() when nothing is estimated.
empty_decay_fit <- function(n_months = 0L, message = "not estimated") {
  data.table(nls_converged = FALSE, nls_A = NA_real_, nls_lambda = NA_real_,
             nls_lambda_se = NA_real_, half_life = NA_real_, half_life_se = NA_real_,
             half_life_ci_low = NA_real_, half_life_ci_high = NA_real_,
             nls_months = as.integer(n_months), nls_message = message)
}

# fit_decay(): exponential decay of the excess after the threshold moved away,
#   S_t - pre = A * exp(-lambda * (t - t0)), fitted with nls() on the months
#   t0 ... end_ym. Half-life = ln(2) / lambda; its standard error by the delta
#   method: SE(t_half) = ln(2) / lambda^2 * SE(lambda).
# Input : series (monthly index for one c), t0_ym, end_ym, pre (pre-level)
# Output: one-row data.table (converged = FALSE and NAs if nls fails)
fit_decay <- function(series, t0_ym, end_ym, pre) {
  s <- series[ym_num >= ym_to_num(t0_ym) & ym_num <= ym_to_num(end_ym) & !is.na(S)][order(ym_num)]
  s[, t := ym_num - ym_to_num(t0_ym)]
  s[, y := S - pre]
  empty <- empty_decay_fit(nrow(s), "")
  fit <- tryCatch(
    nls(y ~ A * exp(-lambda * t), data = s,
        start = list(A = max(s$y[1], 1e-4), lambda = log(2) / 6),   # start: half-life 6 months
        control = nls.control(maxiter = 500)),
    error = function(e) e)
  if (inherits(fit, "error")) {
    empty[, nls_message := conditionMessage(fit)]
    return(empty)
  }
  co <- summary(fit)$coefficients
  lambda <- co["lambda", "Estimate"]
  lambda_se <- co["lambda", "Std. Error"]
  hl <- log(2) / lambda
  hl_se <- log(2) / lambda^2 * lambda_se
  data.table(nls_converged = TRUE, nls_A = co["A", "Estimate"], nls_lambda = lambda,
             nls_lambda_se = lambda_se, half_life = hl, half_life_se = hl_se,
             half_life_ci_low = hl - 1.96 * hl_se, half_life_ci_high = hl + 1.96 * hl_se,
             nls_months = nrow(s), nls_message = "converged")
}

# dynamics_metrics(): all metrics of spec 9.3 for one threshold.
# Input : series   monthly index of this threshold (one numerator width)
#         setup    one row of DYNAMICS_SETUP (c, regime, plateau_from/to,
#                  decay_t0, decay_type)
#         pre_period  months of the pre-level (default PRE_PERIOD)
# Output: one-row data.table: pre-level, plateau, build-up time to 50 % and
#         90 % of the way from pre-level to plateau, and the decay measures
dynamics_metrics <- function(series, setup, pre_period = PRE_PERIOD) {
  start_ym <- format(REGIMES[regime == setup$regime, start], "%Y-%m")
  pre      <- period_mean(series, pre_period[1], pre_period[2])
  plateau  <- period_mean(series, setup$plateau_from, setup$plateau_to)
  out <- data.table(
    c = setup$c, num_width = series$num_width[1], variant = series$variant[1],
    pre_level = pre, plateau = plateau, plateau_excess = plateau - pre,
    plateau_period = paste(setup$plateau_from, "to", setup$plateau_to),
    regime_start = start_ym,
    buildup_50 = buildup_time(series, start_ym, pre + 0.5 * (plateau - pre)),
    buildup_90 = buildup_time(series, start_ym, pre + 0.9 * (plateau - pre)),
    decay_t0 = setup$decay_t0, decay_type = setup$decay_type)
  decay <- data.table(decay_months_to_50 = NA_integer_, excess_share_t0 = NA_real_,
                      excess_share_end = NA_real_)
  nls_part <- empty_decay_fit()
  if (setup$decay_type %in% c("nls", "descriptive")) {
    s_t0  <- series[ym == setup$decay_t0, S]
    s_end <- series[ym == DECAY_END, S]
    decay <- data.table(
      decay_months_to_50 = decay_first_below(series, setup$decay_t0, DECAY_END, pre, plateau),
      excess_share_t0  = excess_share(s_t0, pre, plateau),
      excess_share_end = excess_share(s_end, pre, plateau))
  }
  if (setup$decay_type == "nls") nls_part <- fit_decay(series, setup$decay_t0, DECAY_END, pre)
  cbind(out, decay, nls_part)
}
