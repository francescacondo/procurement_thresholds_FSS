# =============================================================================
# fn_bunching.R -- Module B: bunching around a threshold
# -----------------------------------------------------------------------------
# Contents: ratio_5k(), count_at_value(), bunching_bins(), fit_counterfactual(),
#           bunching_stats(), bunching_bootstrap(), estimate_bunching(),
#           bunching_matrix(), bunching_differences()
# Method (spec 9.2; Chetty, Friedman, Olsen, Pistaferri 2011, QJE 126(2)):
#   1. Count lots in 1k bins inside an estimation window around threshold c.
#   2. Leave out the bins close to c (the "excluded range" [z_L, z_U), in
#      thousand euro relative to c) and fit a polynomial of degree 7 in z (the
#      bin midpoint relative to c) plus dummies for round bins (multiples of
#      5,000 and 10,000) to the remaining bins.
#   3. The fitted values in all bins are the "counterfactual" distribution,
#      i.e. what the counts would look like without the threshold.
#   4. Excess mass B = observed minus counterfactual lots just below c;
#      b = B relative to the average counterfactual count per 1k bin there;
#      missing mass M = counterfactual minus observed lots just above c.
#   5. Uncertainty: residual bootstrap (resample the residuals of the fitted
#      bins, refit, recompute B, b and M).
# All functions take the sample filters as a parameter (modules E and F).
# =============================================================================

# ratio_5k(): lots in [c - 5000, c) divided by lots in [c, c + 5000), per
#   group (default: per regime). Only for comparison with Kollege 1 (spec 9.2).
# Input : dt (lot-level data), c (threshold in euro), filters, by, width
# Output: data.table with columns <by>, n_below, n_above, ratio_5k
ratio_5k <- function(dt, c, filters = default_filters(), by = "regime", width = 5000) {
  thr <- c   # the lot data have a column "c"; inside dt[...] use thr instead
  d <- apply_filters(dt, filters)[v >= thr - width & v < thr + width]
  out <- d[, .(n_below = sum(v < thr), n_above = sum(v >= thr)), by = by]
  out[, ratio_5k := n_below / n_above]
  setorderv(out, by)
  out[]
}

# count_at_value(): number of lots exactly equal to a value, per group.
# Input : dt, value (euro), filters, by
# Output: data.table with columns <by>, n (groups without such lots are missing)
count_at_value <- function(dt, value, filters = default_filters(), by = "regime") {
  val <- value   # local copy, so that no column of dt can shadow it
  out <- apply_filters(dt, filters)[v == val, .(n = .N), by = by]
  setorderv(out, by)
  out[]
}

# bunching_bins(): lots per value bin for one cell of the matrix (one threshold,
#   one regime or several regimes pooled), with the variables of the model.
# Input : dt             lot-level data (data/lots_45_250.rds)
#         c              threshold in euro
#         regimes        one regime, or several that are pooled (e.g. c("P1a", "P1b"))
#         window         c(from, to): bins cover from <= v < to
#         z_L, z_U       excluded range [z_L, z_U) in thousand euro relative to c
#         extra_exclude  NULL or c(from, to): bins with from <= bin < to are also
#                        excluded from the fit (c = 150k: the 139k/140k area)
#         bin_width      width of the bins in euro (1000 in the main analysis)
#         round_dummies  bins that contain a multiple of these values get a dummy
#                        (columns r5k, r10k). With 1k bins (and 500 euro bins)
#                        this is the same as "the lower bound is a multiple"
#                        (spec 9.2); the general rule is needed for 2k bins,
#                        whose lower bounds are odd thousands when c = 139k
#                        (robustness check F1, decision D32)
#         filters        sample filters (see default_filters())
#         exclude_values exact lot values that are dropped before counting
#                        (e.g. 139000 for the c = 140k variant, decision K9)
# Output: data.table, one row per bin: bin (lower bound), n (lots), z (bin
#         midpoint minus c, in thousand euro), r5k/r10k (0/1), excluded (TRUE =
#         not used in the fit), region ("below" = z in [z_L, 0), "above" = z in
#         [0, z_U), "outside" otherwise)
bunching_bins <- function(dt, c, regimes, window, z_L = -5, z_U = 5, extra_exclude = NULL,
                          bin_width = 1000, round_dummies = BUNCHING_ROUND_DUMMIES,
                          filters = default_filters(), exclude_values = NULL) {
  thr <- c
  d <- dt[regime %in% regimes]
  if (!is.null(exclude_values)) d <- d[!v %in% exclude_values]
  d[, cell := "cell"]          # one group: the selected regimes pooled
  bins <- aggregate_bins(d, bin_width = bin_width, filters = filters, by = "cell",
                         v_min = window[1], v_max = window[2], anchor = thr)
  bins <- bins[, .(bin, n)]
  bins[, z := (bin + bin_width / 2 - thr) / 1000]
  # dummy = 1 if the bin [bin, bin + bin_width) contains a multiple of r
  for (r in round_dummies) {
    set(bins, j = paste0("r", r / 1000, "k"),
        value = as.integer(ceiling(bins$bin / r) * r < bins$bin + bin_width))
  }
  bins[, excluded := z >= z_L & z < z_U]
  if (!is.null(extra_exclude) && !anyNA(extra_exclude)) {
    bins[bin >= extra_exclude[1] & bin < extra_exclude[2], excluded := TRUE]
  }
  bins[, region := fifelse(z >= z_L & z < 0, "below", fifelse(z >= 0 & z < z_U, "above", "outside"))]
  bins[]
}

# fit_counterfactual(): polynomial counterfactual (spec 9.2)
#     n_j = sum_k beta_k z_j^k + gamma_5 R5_j + gamma_10 R10_j + e_j,
#   estimated with lm() on the bins outside the excluded range and predicted
#   for all bins. poly() uses orthogonal polynomials (numerically stable);
#   predict() evaluates them correctly in the excluded bins.
# Input : bins (output of bunching_bins), counts (counts per bin; default the
#         observed counts, the bootstrap passes resampled counts), poly_degree
# Output: numeric vector n_hat (counterfactual count per bin)
fit_counterfactual <- function(bins, counts = bins$n, poly_degree = BUNCHING_POLY_DEGREE) {
  d <- copy(bins)
  set(d, j = "n_use", value = counts)   # set() avoids a clash with the column n
  dummies <- grep("^r[0-9]+k$", names(d), value = TRUE)
  # a dummy that is constant in the fitted bins (all 0, or all 1 = same as the
  # intercept) cannot be estimated and is left out
  dummies <- dummies[vapply(dummies, function(col) uniqueN(d[[col]][!d$excluded]) > 1, logical(1))]
  fml <- as.formula(paste0("n_use ~ poly(z, ", poly_degree, ")",
                           paste0(" + ", dummies, collapse = "")))
  fit <- lm(fml, data = d[excluded == FALSE])
  as.numeric(predict(fit, newdata = d))
}

# bunching_stats(): excess mass B, normalised excess mass b and missing mass M.
#     B = sum over z in [z_L, 0) of (n - n_hat)
#     b = B / ((1 / |z_L|) * sum over z in [z_L, 0) of n_hat)
#     M = sum over z in [0, z_U) of (n_hat - n)
# Input : bins (with column region), counts (observed or bootstrap counts),
#         n_hat (counterfactual), z_L
# Output: named numeric vector c(B, b, M)
bunching_stats <- function(bins, counts, n_hat, z_L) {
  below <- bins$region == "below"
  above <- bins$region == "above"
  B <- sum(counts[below] - n_hat[below])
  b <- B / (sum(n_hat[below]) / abs(z_L))
  M <- sum(n_hat[above] - counts[above])
  c(B = B, b = b, M = M)
}

# bunching_bootstrap(): residual bootstrap of B, b and M (spec 9.2).
#   In every replication the residuals of the fitted bins are drawn with
#   replacement and added to their counterfactual counts; the counts in the
#   excluded bins stay as observed; the polynomial is fitted again.
# Input : bins, n_hat (counterfactual of the original fit), z_L, reps, seed,
#         poly_degree
# Output: matrix with reps rows and columns B, b, M
bunching_bootstrap <- function(bins, n_hat, z_L, reps = BOOT_REPS, seed = SEED,
                               poly_degree = BUNCHING_POLY_DEGREE) {
  set.seed(seed)                       # spec section 4: seed before every bootstrap
  fitted <- !bins$excluded
  resid  <- bins$n[fitted] - n_hat[fitted]
  t(vapply(seq_len(reps), function(i) {
    n_star <- bins$n
    n_star[fitted] <- n_hat[fitted] + sample(resid, length(resid), replace = TRUE)
    bunching_stats(bins, n_star, fit_counterfactual(bins, n_star, poly_degree), z_L)
  }, numeric(3)))
}

# estimate_bunching(): one cell of the bunching matrix.
# Input : dt, c, regimes, window, z_L, z_U, extra_exclude, bin_width,
#         poly_degree, round_dummies, filters, exclude_values (see
#         bunching_bins), reps and seed of the bootstrap
# Output: list with
#         summary: one-row data.table with B, b, M, their bootstrap SE and 95 %
#                  percentile interval, the number of fitted bins below and
#                  above the excluded range, lots and counterfactual lots in
#                  [c + z_L * 1000, c), months of the regime(s), B per month
#                  and M / B
#         bins   : the bins with counterfactual n_hat (for the fit figures)
estimate_bunching <- function(dt, c, regimes, window, z_L = -5, z_U = 5, extra_exclude = NULL,
                              bin_width = 1000, poly_degree = BUNCHING_POLY_DEGREE,
                              round_dummies = BUNCHING_ROUND_DUMMIES,
                              filters = default_filters(), exclude_values = NULL,
                              reps = BOOT_REPS, seed = SEED) {
  bins <- bunching_bins(dt, c, regimes, window, z_L, z_U, extra_exclude, bin_width,
                        round_dummies, filters, exclude_values)
  n_hat <- fit_counterfactual(bins, bins$n, poly_degree)
  est   <- bunching_stats(bins, bins$n, n_hat, z_L)
  boot  <- bunching_bootstrap(bins, n_hat, z_L, reps, seed, poly_degree)
  q <- function(x, p) as.numeric(quantile(x, p, type = 7))
  months <- regime_months(filters)[regime %in% regimes, sum(months)]
  summary <- data.table(
    c = c, regime = paste(regimes, collapse = "+"), n_months = months,
    n_bins = nrow(bins),
    n_fit_below = sum(!bins$excluded & bins$z < z_L),
    n_fit_above = sum(!bins$excluded & bins$z >= z_U),
    z_L = z_L, z_U = z_U,
    n_lots_window = sum(bins$n),
    n_obs_below = sum(bins$n[bins$region == "below"]),
    n_cf_below  = sum(n_hat[bins$region == "below"]),
    B = est[["B"]], B_se = sd(boot[, "B"]), B_ci_low = q(boot[, "B"], 0.025), B_ci_high = q(boot[, "B"], 0.975),
    b = est[["b"]], b_se = sd(boot[, "b"]), b_ci_low = q(boot[, "b"], 0.025), b_ci_high = q(boot[, "b"], 0.975),
    M = est[["M"]], M_se = sd(boot[, "M"]), M_ci_low = q(boot[, "M"], 0.025), M_ci_high = q(boot[, "M"], 0.975),
    reps = reps)
  summary[, `:=`(B_per_month = B / n_months, M_over_B = M / B)]
  bins[, n_hat := n_hat]
  list(summary = summary, bins = bins)
}

# bunching_matrix(): estimate_bunching() for every threshold in `setup` and
#   every regime (spec 9.2: 4 thresholds x 5 regimes = 20 cells), plus the
#   simple counts n_at_c (lots exactly at c) and ratio_5k.
# Input : dt, setup (BUNCHING_SETUP), regimes, bin_width, poly_degree,
#         round_dummies, filters, exclude_values, reps, z_L (NULL = from setup;
#         a number overrides it, for robustness check F3)
# Output: list with summary (one row per cell; diagonal = TRUE where c is the
#         threshold in force) and bins (all cells, long format)
bunching_matrix <- function(dt, setup = BUNCHING_SETUP, regimes = REGIME_LEVELS,
                            bin_width = 1000, poly_degree = BUNCHING_POLY_DEGREE,
                            round_dummies = BUNCHING_ROUND_DUMMIES,
                            filters = default_filters(), exclude_values = NULL,
                            reps = BOOT_REPS, z_L = NULL) {
  res <- list(); bins_all <- list()
  for (i in seq_len(nrow(setup))) {
    s <- setup[i]
    zl <- if (is.null(z_L)) s$z_L else z_L
    at_c <- count_at_value(dt, s$c, filters)
    r5   <- ratio_5k(dt, s$c, filters)
    for (r in regimes) {
      msg(sprintf("  bunching c = %s, regime %s (%d bootstrap replications)", label_k(s$c), r, reps))
      e <- estimate_bunching(dt, s$c, r, c(s$win_from, s$win_to), zl, s$z_U,
                             c(s$extra_from, s$extra_to), bin_width, poly_degree,
                             round_dummies, filters, exclude_values, reps)
      e$summary[, `:=`(diagonal = (r == s$diag_regime),
                       n_at_c = if (r %in% at_c$regime) at_c[regime == r, n] else 0L,
                       ratio_5k = if (r %in% r5$regime) r5[regime == r, ratio_5k] else NA_real_)]
      res[[length(res) + 1]] <- e$summary
      bins_all[[length(bins_all) + 1]] <- e$bins[, `:=`(c = s$c, regime = r)]
    }
  }
  list(summary = rbindlist(res), bins = rbindlist(bins_all))
}

# bunching_differences(): difference in b between the diagonal cell of each
#   threshold and every other regime, SE_diff = sqrt(SE_1^2 + SE_2^2) (spec 9.2;
#   the cells are estimated on separate samples).
# Input : summary (output of bunching_matrix()$summary)
# Output: one row per threshold x other regime: b_diag, b_other, diff, se_diff,
#         95 % interval (normal approximation) and z = diff / se_diff
bunching_differences <- function(summary) {
  diag <- summary[diagonal == TRUE, .(c, regime_diag = regime, b_diag = b, b_se_diag = b_se)]
  oth  <- summary[diagonal == FALSE, .(c, regime_other = regime, b_other = b, b_se_other = b_se)]
  out  <- merge(diag, oth, by = "c")
  out[, `:=`(diff = b_diag - b_other, se_diff = sqrt(b_se_diag^2 + b_se_other^2))]
  out[, `:=`(ci_low = diff - 1.96 * se_diff, ci_high = diff + 1.96 * se_diff, z = diff / se_diff)]
  setorder(out, c, regime_other)
  out[]
}
