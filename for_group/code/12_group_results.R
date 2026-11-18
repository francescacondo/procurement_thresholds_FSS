# =============================================================================
# 12_group_results.R -- Four additional results on the group sample
# -----------------------------------------------------------------------------
# Purpose : On the group sample (data/lots_group.rds, checked in
#           11_group_sample.R), each result without and with Karl's bulk filter:
#           1. Bunching at 75k in P1b and P2 with Karl's specification
#              (module B), the difference, and the bulk entries in 70k-80k.
#           2. Monthly bunching index S for 75k and 139k, September 2020 to
#              June 2023: plateau, build-up to 50 % / 90 %, decay of S_75
#              (free asymptote; comparison with the pre-level 2018-2019);
#              figure C2 cut to this period and a panel with the group's S1.
#           3. Density ratio P2/P1b in 5k bins (module D1) and the replication
#              of the group's B4 (10k bands, reference 220k-300k).
#           4. Bunching at 139k with a strict cutoff (group's specification,
#              lots at 139,000 in the first bin above) with the group's
#              residual bootstrap, and Karl's specification on their sample.
# Inputs  : data/lots_group.rds; data/group_tables/ (the group's tables);
#           output/tables/tab_G0_controls.csv (written by 11_group_sample.R)
# Outputs : output/tables/tab_G1_* ... tab_G4_*, tex/*.tex
#           output/figures/fig_G2a_*, fig_G2b_* (PNG + PDF)
#           output/RESULTS_GROUP.md, output/group_results.rds
# Runtime : about 10 seconds (bootstraps)
# Usage   : run by run.R after 11_group_sample.R; alone:
#           Rscript code/12_group_results.R (in for_group)
# =============================================================================

source(file.path("code", "00_setup.R"))
t_start <- Sys.time()
cat("\n===== 12_group_results.R =====", format(t_start, "%Y-%m-%d %H:%M:%S"), "\n")
group_dirs()
dir.create(file.path(GROUP_TAB_DIR, "tex"), showWarnings = FALSE)

lots <- readRDS(GROUP_LOTS_RDS)
msg("Loaded data/lots_group.rds: ", fmt_n(nrow(lots)), " lots")
V <- group_variants()
flt <- function(i) list(drop_bulk = V$drop_bulk[i])

# Control values of 11_group_sample.R (only for the first lines of RESULTS_GROUP.md)
ctrl_path <- file.path(GROUP_TAB_DIR, "tab_G0_controls.csv")
if (!file.exists(ctrl_path)) stop("output/tables/tab_G0_controls.csv not found: run 11_group_sample.R first (run.R does this).")
ctrl_tab <- fread(ctrl_path)
# The group's published results
s1    <- fread(file.path(GROUP_REPO_TAB, "S1_adjustment_curve_p1b.csv"))
b4_st <- fread(file.path(GROUP_REPO_TAB, "B4_band_ratios_p1b.csv"))
coef_st <- fread(file.path(GROUP_REPO_TAB, "coefficients_p1b.csv"))
st_bunch <- coef_st[tbl == "bunch" & row == "main", .(period = col, b, se, ci_low = lo, ci_high = hi)]

# ---- Result 1: bunching at 75k with Karl's specification -------------------------------------
set75 <- BUNCHING_SETUP[BUNCHING_SETUP$c == 75000]
win75 <- c(set75$win_from, set75$win_to)
est75 <- function(dt, regime, filters, variant) {
  e <- estimate_bunching(dt, 75000, regime, win75, set75$z_L, set75$z_U, filters = filters)
  n_at <- apply_filters(dt[regime %in% e$summary$regime], filters)[v == 75000, .N]
  e$summary[, `:=`(variant = variant, n_at_c = n_at)][]
}
# Extra variant: no bulk filter, but the bulk entries at exactly 70,000 removed
lots_no70 <- lots[!(bulk == TRUE & v == 70000)]
r1 <- rbindlist(c(
  lapply(seq_len(nrow(V)), function(i) rbindlist(lapply(c("P1b", "P2"), function(r) est75(lots, r, flt(i), V$variant[i])))),
  list(rbindlist(lapply(c("P1b", "P2"), function(r)
    est75(lots_no70, r, list(drop_bulk = FALSE), "no_bulk_filter_without_bulk_at_70000"))))))
r1_diff <- r1[, .(regime = "P1b - P2", b = b[regime == "P1b"] - b[regime == "P2"],
                  b_se = sqrt(b_se[regime == "P1b"]^2 + b_se[regime == "P2"]^2)), by = variant]
r1_diff[, `:=`(b_ci_low = b - 1.96 * b_se, b_ci_high = b + 1.96 * b_se, ci_type = "normal, SE_diff = sqrt(SE1^2 + SE2^2)")]
r1_out <- rbind(r1[, .(variant, regime, b, b_se, b_ci_low, b_ci_high, ci_type = "bootstrap percentile",
                       B, B_se, M, n_obs_below, n_cf_below, n_lots_window, n_at_c)],
                r1_diff, fill = TRUE)
group_save_table(r1_out, "tab_G1_bunching_75k")

# Bulk entries in [70k, 80k) by regime and value, and the five largest authorities
bw <- group_bulk_window(lots, c("P1b", "P2"), 70000, 80000, top_n = 5)
group_save_table(bw$by_value, "tab_G1_bulk_70_80k_by_value")
group_save_table(bw$top_authorities, "tab_G1_bulk_70_80k_top_authorities")
# Where the bulk entries of the 75k window lie, and how much they move B and b
bulk_eff <- rbindlist(lapply(c("P1b", "P2"), function(r) {
  b <- lots[bulk == TRUE & regime == r & v >= win75[1] & v < win75[2]]
  get_b <- function(var, col) r1[variant == var & regime == r][[col]]
  data.table(regime = r,
             bulk_in_window_45_125k = nrow(b),
             bulk_below_70_75k = b[v >= 70000 & v < 75000, .N],
             bulk_at_70000 = b[v == 70000, .N],
             bulk_above_75_80k = b[v >= 75000 & v < 80000, .N],
             bulk_in_fitted_bins = b[v < 70000 | v >= 80000, .N],
             B_no_filter = get_b("no_bulk_filter", "B"), B_bulk_filter = get_b("bulk_filter", "B"),
             B_without_bulk_70000 = get_b("no_bulk_filter_without_bulk_at_70000", "B"),
             b_no_filter = get_b("no_bulk_filter", "b"), b_bulk_filter = get_b("bulk_filter", "b"),
             b_without_bulk_70000 = get_b("no_bulk_filter_without_bulk_at_70000", "b"))
}))
bulk_eff[, `:=`(delta_B = B_no_filter - B_bulk_filter, delta_b = b_no_filter - b_bulk_filter,
                delta_b_from_70000 = b_no_filter - b_without_bulk_70000)]
group_save_table(bulk_eff, "tab_G1_bulk_effect")

# ---- Result 2: monthly index S, September 2020 to June 2023 -----------------------------------
series <- rbindlist(lapply(seq_len(nrow(V)), function(i) {
  rbindlist(lapply(c(75000, 139000), function(cc) {
    group_monthly_index(lots, cc, flt(i))[, variant := V$variant[i]]
  }))
}))
group_save_table(series[, .(variant, c, ym, n_num, n_den, S = round(S, 6),
                            use = fifelse(ym <= GROUP_INDEX$pre[2], "pre-level 2018-2019 (comparison only)",
                                          "Sep 2020 - Jun 2023"))],
                 "tab_G2_index_monthly")
dyn <- rbindlist(lapply(seq_len(nrow(V)), function(i) {
  rbindlist(lapply(c(75000, 139000), function(cc) {
    group_dynamics(series[variant == V$variant[i] & c == cc], cc)[, variant := V$variant[i]]
  }), fill = TRUE)
}), fill = TRUE)
setcolorder(dyn, "variant")
group_save_table(dyn, "tab_G2_dynamics_metrics")

# Decomposition of S_139 by central and other authorities (Karl's request after
# phase 2). Central = ANAC section "SEZIONE REGIONALE CENTRALE" (variable
# `central`, the group's definition of section 1.4). Periods: P1b (baseline of
# S_139) and 2018-2019 (Karl's earlier pre-level). S_mean = mean of the monthly
# values (as the baseline), S_pooled = sum of numerators / sum of denominators;
# share_den / share_num = share of the group in the lots of [c - 20k, c + 20k)
# and of [c - 1k, c).
s139_cen <- rbindlist(lapply(seq_len(nrow(V)), function(i) {
  rbindlist(lapply(c("all", "TRUE", "FALSE"), function(gv) {
    fl <- flt(i)
    if (gv != "all") fl <- c(fl, list(group_col = "central", group_value = gv))
    s <- group_monthly_index(lots, 139000, fl)
    rbindlist(lapply(list(GROUP_INDEX$pre, GROUP_INDEX$p1b), function(pp) {
      x <- s[ym >= pp[1] & ym <= pp[2]]
      data.table(variant = V$variant[i],
                 authorities = c(all = "All", `TRUE` = "Central", `FALSE` = "Other")[[gv]],
                 period = if (identical(pp, GROUP_INDEX$pre)) "2018-2019" else "P1b",
                 months = nrow(x), months_without_lots = x[n_den == 0, .N],
                 S_mean = mean(x$S, na.rm = TRUE), S_pooled = sum(x$n_num) / sum(x$n_den),
                 n_num = sum(x$n_num), n_den = sum(x$n_den))
    }))
  }))
}))
s139_cen[, `:=`(share_den = n_den / n_den[authorities == "All"],
                share_num = n_num / n_num[authorities == "All"]), by = .(variant, period)]
group_save_table(s139_cen, "tab_G2_s139_central")
if (s139_cen[authorities == "All" & period == "P1b", any(abs(S_mean - dyn[c == 139000][match(variant, dyn[c == 139000]$variant), baseline]) > 1e-12)]) {
  stop("S_139 decomposition: the mean over P1b of all lots differs from the baseline in tab_G2_dynamics_metrics.")
}
if (dyn[!is.na(converged) & converged == FALSE, .N] > 0) {
  msg("WARNING: a decay fit did not converge (see tab_G2_dynamics_metrics.csv).")
}

# Figures: C2 cut to Sep 2020 - Jun 2023, and the panel S1 (group) | C2
s1_fit <- group_s1_fit(s1)
fig_files <- character(0)
for (i in seq_len(nrow(V))) {
  ev <- series[variant == V$variant[i] & ym >= GROUP_INDEX$first_ym]
  first_line <- paste0("S = lots in [c - 1k, c) / lots in [c - 20k, c + 20k), ",
                       if (V$drop_bulk[i]) "without bulk entries." else "including bulk entries (no bulk filter).")
  p_c2 <- group_plot_c2(ev, first_line)
  nm <- paste0("fig_G2a_C2_event_time_", V$variant[i])
  group_save_figure(p_c2, nm, height = 5.2)
  fig_files <- c(fig_files, nm)

  p_left <- group_plot_s1(
    s1, title = "(a) Group (Stata): speed of adjustment to 139k (S1)",
    subtitle = sprintf(paste0("Gap in direct-award share, (75k, 139k] vs (139k, 180k],\n",
                              "relative to P1b; 1 = mean gap in months 12-21.\n",
                              "Fitted: a = %.2f, half-life of the remaining gap %.2f months."),
                       s1_fit$alpha, s1_fit$half_life))
  p_right <- group_plot_c2(ev, first_line, title = "(b) Bunching index S, group sample (C2)",
                           label_size = 2.3) +
    labs(x = "Months relative to June 2021 (0 = June 2021)")
  p_panel <- (p_left + p_right + plot_layout(widths = c(1, 1.35))) &
    theme(plot.title = element_text(size = 11.5))
  nm <- paste0("fig_G2b_S1_C2_panel_", V$variant[i])
  group_save_figure(p_panel, nm, height = 5.6, width = 13)
  fig_files <- c(fig_files, nm)
}
# Paper versions of G2a and G2b (Karl's request, 2026-11-18): bulk-filter variant
# only, width 16 cm; captions written by hand (not in this folder)
group_paper_figures(series[variant == "bulk_filter" & ym >= GROUP_INDEX$first_ym], s1)
fig_files <- c(fig_files, "fig_G2a_C2_event_time_bulk_filter_paper", "fig_G2b_S1_C2_panel_bulk_filter_paper")

# ---- Result 3: density ratio P2/P1b ----------------------------------------------------------------
d1 <- rbindlist(lapply(seq_len(nrow(V)), function(i) {
  sc <- shape_counts(lots, bin_width = 5000, v_range = WINDOW, filters = flt(i))
  density_ratios(sc, "P2", "P1b", norm = "i_ref", N_variant = "all")[, variant := V$variant[i]]
}))
d1_lr <- rbindlist(lapply(V$variant, function(vv) ratio_level_ramp(d1[variant == vv])[, variant := vv]))
setcolorder(d1, "variant"); setcolorder(d1_lr, "variant")
group_save_table(d1, "tab_G3_density_ratio_5k")
group_save_table(d1_lr, "tab_G3_level_ramp_5k")

b4 <- rbindlist(lapply(seq_len(nrow(V)), function(i) group_b4_bands(lots, filters = flt(i))[, variant := V$variant[i]]))
b4 <- merge(b4, b4_st[, .(band10, nC_stata = nC, nP2_stata = nP2, ratio_stata = ratio)], by = "band10")
setcolorder(b4, "variant"); setorder(b4, variant, band10)
group_save_table(b4, "tab_G3_b4_bands")
b4_sum <- rbind(group_band_summary(b4_st)[, source := "group (Stata), B4_band_ratios_p1b.csv"],
                rbindlist(lapply(V$variant, function(vv) group_band_summary(b4[variant == vv])[, source := vv])))
b4_match <- b4[variant == "no_bulk_filter", sum(nC == nC_stata & nP2 == nP2_stata)]
setcolorder(b4_sum, "source")
group_save_table(b4_sum, "tab_G3_b4_summary")

# ---- Result 4: bunching at 139k with a strict cutoff ------------------------------------------------
r4 <- list()
for (i in seq_len(nrow(V))) {
  for (strict in c(TRUE, FALSE)) {
    bt <- group_bunch_bootstrap(lots, strict = strict, filters = flt(i))
    # (computed outside dt[...], where `strict` would be the column of the summary)
    spec_label <- if (strict) "group, strict cutoff (139,000 above)" else "group, as published (139,000 below)"
    r4[[length(r4) + 1]] <- bt$summary[, `:=`(variant = V$variant[i], spec = spec_label,
                                              ci_type = "bootstrap percentile (Stata _pctile)")]
  }
  # Karl's specification (module B) on the group sample
  set139 <- BUNCHING_SETUP[BUNCHING_SETUP$c == 139000]
  k <- rbindlist(lapply(c("P2", "P1b"), function(r) {
    e <- estimate_bunching(lots, 139000, r, c(set139$win_from, set139$win_to), set139$z_L, set139$z_U,
                           filters = flt(i))$summary
    e[, n_at_c := apply_filters(lots[regime == r], flt(i))[v == 139000, .N]]
  }))
  kk <- k[, .(period = regime, b, excess = B, missing = M, n_obs_below, n_at_139000 = n_at_c,
              se = b_se, ci_low = b_ci_low, ci_high = b_ci_high)]
  kd <- data.table(period = "diff", b = kk$b[1] - kk$b[2], se = sqrt(kk$se[1]^2 + kk$se[2]^2))
  kd[, `:=`(ci_low = b - 1.96 * se, ci_high = b + 1.96 * se)]
  r4[[length(r4) + 1]] <- rbind(kk[, ci_type := "bootstrap percentile"],
                                kd[, ci_type := "normal, SE_diff = sqrt(SE1^2 + SE2^2)"], fill = TRUE)[
    , `:=`(variant = V$variant[i], spec = "Karl (module B: [95k, 200k), 139,000 above)",
           strict = TRUE, reps = BOOT_REPS, seed = SEED)]
}
r4 <- rbindlist(r4, fill = TRUE)
setcolorder(r4, c("variant", "spec", "period", "b", "se", "ci_low", "ci_high", "ci_type"))
group_save_table(r4, "tab_G4_bunching_139k")

# LaTeX rows in the format of I_bunch_sens_p1b.tex (group's sample = no bulk filter)
for (i in seq_len(nrow(V))) {
  x <- r4[variant == V$variant[i] & spec == "group, strict cutoff (139,000 above)"]
  line <- group_tex_line(GROUP_TEX_LABEL, x[period == "P2", b], x[period == GROUP_CTRL_REGIME, b],
                         x[period == "diff", b])
  fn <- if (V$drop_bulk[i]) "I_bunch_sens_strict_bulkfilter_p1b.tex" else "I_bunch_sens_strict_p1b.tex"
  writeLines(line, file.path(GROUP_TAB_DIR, "tex", fn))
  msg("Wrote tables/tex/", fn, ": ", line)
}

# Objects for RESULTS_GROUP.md
saveRDS(list(r1 = r1, r1_diff = r1_diff, bw = bw, bulk_eff = bulk_eff, dyn = dyn, s1_fit = s1_fit,
             d1_lr = d1_lr, b4_sum = b4_sum, b4_match = b4_match, r4 = r4, st_bunch = st_bunch,
             fig_files = fig_files, s139_cen = s139_cen),
        file.path(GROUP_OUT_DIR, "group_results.rds"))
msg(sprintf("Results computed in %.1f seconds.", as.numeric(difftime(Sys.time(), t_start, units = "secs"))))

# ---- RESULTS_GROUP.md -----------------------------------------------------------------------------
# Every number below is taken from the objects computed above (or read from
# the group's CSV files and from tab_G0_controls.csv of 11_group_sample.R).
f   <- function(x, d = 2) ifelse(is.na(x), "-", formatC(x, format = "f", digits = d, big.mark = ","))
fse <- function(b, se, d = 2) sprintf("%s (%s)", f(b, d), f(se, d))
fci <- function(lo, hi, d = 2) sprintf("[%s, %s]", f(lo, d), f(hi, d))
md_row  <- function(...) paste0("| ", paste(unlist(list(...)), collapse = " | "), " |")    # one row; a vector gives several cells
md_rows <- function(...) paste0("| ", do.call(paste, c(list(...), sep = " | ")), " |")  # one row per element (table columns)
g1  <- function(var, reg) r1[variant == var & regime == reg]
g1d <- function(var) r1_diff[variant == var]
gdy <- function(var, cc, base = NULL, from = NULL) {
  x <- dyn[variant == var & c == cc]
  if (!is.null(base)) x <- x[baseline_type == base]
  if (!is.null(from)) x <- x[fit_from == from]
  x[1]
}
g4 <- function(var, sp, per) r4[variant == var & startsWith(spec, sp) & period == per]
scen <- function(var, au, per) s139_cen[variant == var & authorities == au & period == per]
# Note on the baseline of S_139 (central vs other authorities), main variant = bulk filter
cen_p1b <- scen("bulk_filter", "Central", "P1b"); oth_p1b <- scen("bulk_filter", "Other", "P1b")
cen_pre <- scen("bulk_filter", "Central", "2018-2019"); oth_pre <- scen("bulk_filter", "Other", "2018-2019")
all_pre <- scen("bulk_filter", "All", "2018-2019")
cen_same <- s139_cen[, isTRUE(all.equal(S_mean[variant == "no_bulk_filter"], S_mean[variant == "bulk_filter"]))]
cen_concentrated <- cen_p1b$S_mean > 2 * oth_p1b$S_mean && cen_p1b$share_num > cen_p1b$share_den
cen_note <- sprintf(paste0(
  "**Note on the baseline of S_139.** Over P1b, S_139 is %s %% for central authorities (ANAC section CENTRALE, the group's definition in section 1.4) and %s %% for all other authorities%s. ",
  "Central authorities account for %s %% of the lots in [119k, 159k) but %s %% of the lots in [138k, 139k). In 2018-2019 the values are %s %% (central) and %s %% (other; all lots %s %%). ",
  "%s From 1 January 2020 the EU threshold for supplies and services of central government authorities was 139,000 euro (Delegated Regulation (EU) 2019/1828; 144,000 euro in 2018-2019), so 139k already separated procedure types for central authorities in P1b (note in section 1.3 of the group's do-file). ",
  "%s"),
  f(100 * cen_p1b$S_mean), f(100 * oth_p1b$S_mean),
  if (cen_same) " (identical with and without the bulk filter)" else "",
  f(100 * cen_p1b$share_den, 1), f(100 * cen_p1b$share_num, 1),
  f(100 * cen_pre$S_mean), f(100 * oth_pre$S_mean), f(100 * all_pre$S_mean),
  if (cen_concentrated) "The higher P1b baseline is thus concentrated in central authorities, which bunch below 139k already before the 139k direct-award threshold." else
    "The difference between central and other authorities is small.",
  if (cen_concentrated) "The P1b baseline of 139k therefore contains bunching that is not caused by the 139k direct-award threshold; the build-up times of S_139 measured from it are relative to this higher level." else "")
both <- function(fun) c(fun("no_bulk_filter"), fun("bulk_filter"))
FREE <- "free asymptote (fit from 2021-06)"; PRE <- "pre-level 2018-2019"

st <- function(p) st_bunch[period == p]
b4s <- function(src) b4_sum[source == src]
b4_stata <- b4_sum[startsWith(source, "group")]
excess_shift <- both(function(vv) g4(vv, "group, as published", "P2")$excess - g4(vv, "group, strict", "P2")$excess)
n_bands <- nrow(b4_st)

md <- c(
  "# RESULTS_GROUP.md",
  "",
  sprintf("Four additional results on the sample of the group's Stata pipeline (`repo_gruppe/code/full_analysis_commented.do`), written by `code/12_group_results.R` on %s. Sample: `data/lots_group.rds` (%s lots; extract of the group sample, rebuilt from the raw ANAC files by `code/make_extract.R` and checked in `code/11_group_sample.R`: %d of %d control values against the group's tables pass, `tab_G0_controls.csv`).",
          format(Sys.time(), "%Y-%m-%d %H:%M"), fmt_n(nrow(lots)), ctrl_tab[pass == TRUE, .N], nrow(ctrl_tab)),
  "",
  "Each result is computed **without** the bulk filter (the group's sample as it is) and **with** Karl's bulk filter (>= 50 lots with the same value per authority and month dropped). Standard errors in parentheses, 95 % intervals in brackets.",
  "",
  "## Comparison table",
  "",
  md_row("Measure", "Group (Stata)", "Group sample, no bulk filter", "Group sample, bulk filter"),
  md_row("---", "---", "---", "---"),
  # Result 1
  md_row("**1** b(75k, P1b), Karl's spec", "-",
         both(function(vv) fse(g1(vv, "P1b")$b, g1(vv, "P1b")$b_se))),
  md_row("**1** b(75k, P2)", "-",
         both(function(vv) fse(g1(vv, "P2")$b, g1(vv, "P2")$b_se))),
  md_row("**1** b(75k, P1b) - b(75k, P2)", "-",
         both(function(vv) fse(g1d(vv)$b, g1d(vv)$b_se))),
  # Result 2
  md_row("**2** S_139 baseline: mean over P1b (%)", "-",
         both(function(vv) f(100 * gdy(vv, 139000)$baseline))),
  md_row("**2** S_139 over P1b: central / other authorities (%) (see note)", "-",
         both(function(vv) sprintf("%s / %s", f(100 * scen(vv, "Central", "P1b")$S_mean),
                                   f(100 * scen(vv, "Other", "P1b")$S_mean)))),
  md_row("**2** S_139 plateau 2022-01 to 2023-06 (%)", "-",
         both(function(vv) f(100 * gdy(vv, 139000)$plateau))),
  md_row("**2** S_139 build-up to 50 % / 90 % (months, 0 = June 2021)",
         sprintf("S1 (direct-award gap, other measure): impact a = %s, half-life of the remaining gap %s months",
                 f(s1_fit$alpha), f(s1_fit$half_life)),
         both(function(vv) sprintf("%d / %d", gdy(vv, 139000)$buildup_50, gdy(vv, 139000)$buildup_90))),
  md_row("**2** S_75 plateau 2020-10 to 2021-05 (%)", "-",
         both(function(vv) f(100 * gdy(vv, 75000, FREE)$plateau))),
  md_row("**2** S_75 half-life, free asymptote, fit 2021-06 to 2023-06 (months)", "-",
         both(function(vv) fse(gdy(vv, 75000, FREE, "2021-06")$half_life, gdy(vv, 75000, FREE, "2021-06")$half_life_se))),
  md_row("**2** S_75 half-life, free asymptote, fit 2021-08 to 2023-06 (months)", "-",
         both(function(vv) fse(gdy(vv, 75000, FREE, "2021-08")$half_life, gdy(vv, 75000, FREE, "2021-08")$half_life_se))),
  md_row("**2** S_75 fitted asymptote, fit from 2021-06 (%)", "-",
         both(function(vv) fse(100 * gdy(vv, 75000, FREE, "2021-06")$asymptote,
                               100 * gdy(vv, 75000, FREE, "2021-06")$asymptote_se))),
  md_row("**2** Comparison: S_75 half-life with pre-level 2018-2019, fit from 2021-06 / 2021-08", "-",
         both(function(vv) sprintf("%s / %s", f(gdy(vv, 75000, PRE, "2021-06")$half_life),
                                   f(gdy(vv, 75000, PRE, "2021-08")$half_life)))),
  # Result 3
  md_row("**3** D1 level P2/P1b, 5k bins 75k-125k (main)", "-",
         both(function(vv) fse(d1_lr[variant == vv]$level, d1_lr[variant == vv]$level_se, 3))),
  md_row("**3** D1 ramp per 10k (p)", "-",
         both(function(vv) sprintf("%s (p = %s)", f(d1_lr[variant == vv]$ramp_per_10k, 4), f(d1_lr[variant == vv]$ramp_p)))),
  md_row("**3** B4 mean ratio P2/P1b, 10k bands (80k, 130k] (comparison)", f(b4_stata$mean_ratio, 3),
         both(function(vv) f(b4s(vv)$mean_ratio, 3))),
  md_row("**3** B4 slope of log ratio per 10k, (80k, 130k] (p)",
         sprintf("%s (p = %s)", f(b4_stata$ramp_per_10k, 4), f(b4_stata$ramp_p)),
         both(function(vv) sprintf("%s (p = %s)", f(b4s(vv)$ramp_per_10k, 4), f(b4s(vv)$ramp_p)))),
  md_row("**3** B4 bands with nC and nP2 equal to Stata", sprintf("%d bands", n_bands),
         sprintf("%d of %d", b4_match, n_bands), "- (bulk entries removed)"),
  # Result 4
  md_row("**4** b(139k, P2), group spec, strict cutoff", sprintf("%s %s (139,000 below)", f(st("P2")$b), fci(st("P2")$ci_low, st("P2")$ci_high)),
         both(function(vv) { x <- g4(vv, "group, strict", "P2"); sprintf("%s %s", f(x$b), fci(x$ci_low, x$ci_high)) })),
  md_row("**4** b(139k, P1b), group spec, strict cutoff", sprintf("%s %s (139,000 below)", f(st("P1b")$b), fci(st("P1b")$ci_low, st("P1b")$ci_high)),
         both(function(vv) { x <- g4(vv, "group, strict", "P1b"); sprintf("%s %s", f(x$b), fci(x$ci_low, x$ci_high)) })),
  md_row("**4** Difference P2 - P1b, strict cutoff", sprintf("%s %s (139,000 below)", fse(st("diff")$b, st("diff")$se), fci(st("diff")$ci_low, st("diff")$ci_high)),
         both(function(vv) { x <- g4(vv, "group, strict", "diff"); sprintf("%s %s", fse(x$b, x$se), fci(x$ci_low, x$ci_high)) })),
  md_row("**4** Check: group spec as published (139,000 below), difference with the R bootstrap",
         sprintf("%s %s", fse(st("diff")$b, st("diff")$se), fci(st("diff")$ci_low, st("diff")$ci_high)),
         both(function(vv) { x <- g4(vv, "group, as published", "diff"); sprintf("%s %s", fse(x$b, x$se), fci(x$ci_low, x$ci_high)) })),
  md_row("**4** Karl's spec: b(139k, P2) / b(139k, P1b)", "-",
         both(function(vv) sprintf("%s / %s", f(g4(vv, "Karl", "P2")$b), f(g4(vv, "Karl", "P1b")$b)))),
  md_row("**4** Karl's spec: difference P2 - P1b", "-",
         both(function(vv) fse(g4(vv, "Karl", "diff")$b, g4(vv, "Karl", "diff")$se))),
  "",
  sprintf("Note on result 2: %s (P1b: central %s %%, other %s %%; EU threshold of central authorities 139k in 2020-2021), see the note under result 2. The build-up time of S_75 is not reported here because the window starts with the 75k regime (appendix of result 2 only).",
          if (cen_concentrated) "the P1b baseline of S_139 is high mainly because of central authorities" else
            "central and other authorities have a similar P1b baseline of S_139",
          f(100 * cen_p1b$S_mean), f(100 * oth_p1b$S_mean)),
  "",
  "Karl's specification (module B): left-closed 1k bins [k, k + 1k), lots at exactly c count above, window [45k, 125k) for 75k and [95k, 200k) for 139k, excluded range [c - 5k, c + 5k), polynomial of degree 7, 5k/10k dummies, residual bootstrap with 200 replications (seed 20261109 before each cell), SE of a difference = sqrt(SE1^2 + SE2^2). The group's specification: right-closed bins (k - 1k, k] in (100k, 200k], excluded (134k, 144k], same polynomial and dummies, their residual bootstrap (seed 20261104 once, P2 then P1b, difference per replication, counts floored at 0, percentile interval with Stata's `_pctile` definition).",
  "",
  "## Result 1: bunching at 75k (Karl's specification)",
  "",
  md_row("Sample", "b(75k, P1b)", "95 % CI", "b(75k, P2)", "95 % CI", "Difference P1b - P2", "B in P1b (lots)", "B in P2 (lots)"),
  md_row("---", "---", "---", "---", "---", "---", "---", "---"),
  unlist(lapply(c("no_bulk_filter", "bulk_filter", "no_bulk_filter_without_bulk_at_70000"), function(vv) {
    lab <- c(no_bulk_filter = "No bulk filter", bulk_filter = "Bulk filter",
             no_bulk_filter_without_bulk_at_70000 = "No bulk filter, only the bulk entries at 70,000 removed")[[vv]]
    md_row(lab, fse(g1(vv, "P1b")$b, g1(vv, "P1b")$b_se), fci(g1(vv, "P1b")$b_ci_low, g1(vv, "P1b")$b_ci_high),
           fse(g1(vv, "P2")$b, g1(vv, "P2")$b_se), fci(g1(vv, "P2")$b_ci_low, g1(vv, "P2")$b_ci_high),
           fse(g1d(vv)$b, g1d(vv)$b_se), f(g1(vv, "P1b")$B, 0), f(g1(vv, "P2")$B, 0))
  })),
  "",
  "**Bulk entries with values in [70k, 80k)** (Karl's flag; `tab_G1_bulk_70_80k_by_value.csv`):",
  "",
  md_row("Regime", "Value (EUR)", "Bulk lots", "Authority-month cells", "Authorities"),
  md_row("---", "---", "---", "---", "---"),
  bw$by_value[, md_rows(regime, f(value, 0), f(n_bulk_lots, 0), n_cells, n_authorities)],
  "",
  "**Authorities with the most bulk entries in [70k, 80k)** (up to five per regime; fewer exist):",
  "",
  md_row("Regime", "Authority", "Tax code", "Bulk lots", "Share of the regime's bulk lots in 70k-80k", "Values (EUR)", "Month(s)"),
  md_row("---", "---", "---", "---", "---", "---", "---"),
  bw$top_authorities[, md_rows(regime, authority, cf_amministrazione_appaltante, f(n_bulk_lots, 0),
                              paste0(f(100 * share_of_regime_bulk, 1), " %"), values, months)],
  "",
  "**How much the entries at 70,000 drive b(75k)** (`tab_G1_bulk_effect.csv`): bulk lots in the 75k window [45k, 125k) and their position; B and b without filter, with filter and with only the bulk entries at 70,000 removed.",
  "",
  md_row("Regime", "Bulk lots in [45k, 125k)", "at 70,000", "in [75k, 80k)", "in fitted bins", "b no filter", "b bulk filter", "b without bulk at 70,000", "Drop of b: only 70,000 removed / all bulk removed"),
  md_row("---", "---", "---", "---", "---", "---", "---", "---", "---"),
  bulk_eff[, md_rows(regime, f(bulk_in_window_45_125k, 0), f(bulk_at_70000, 0), f(bulk_above_75_80k, 0),
                     f(bulk_in_fitted_bins, 0), f(b_no_filter), f(b_bulk_filter), f(b_without_bulk_70000),
                     sprintf("%s / %s", f(delta_b_from_70000), f(delta_b)))],
  "",
  sprintf(paste0("All bulk lots in [70k, 75k) are at exactly 70,000 (P1b %s, P2 %s; authority-month cells: P1b %d, P2 %d). ",
                 "They lie in the excluded range below 75k, so each of them adds one lot to the excess mass B without changing the counterfactual. ",
                 "Removing only these entries lowers b(75k) by %s in P1b and by %s in P2; the full bulk filter lowers it by %s and %s. ",
                 "The entries at 70,000 therefore account for the whole effect of the bulk filter on b(75k); the other bulk lots of the window ",
                 "(at 75,000 or in the fitted bins) change b by at most %s."),
          f(bulk_eff[regime == "P1b", bulk_at_70000], 0), f(bulk_eff[regime == "P2", bulk_at_70000], 0),
          bw$by_value[regime == "P1b" & value == 70000, sum(n_cells)],
          bw$by_value[regime == "P2" & value == 70000, sum(n_cells)],
          f(bulk_eff[regime == "P1b", delta_b_from_70000]), f(bulk_eff[regime == "P2", delta_b_from_70000]),
          f(bulk_eff[regime == "P1b", delta_b]), f(bulk_eff[regime == "P2", delta_b]),
          f(bulk_eff[, max(abs(delta_b - delta_b_from_70000))], 3)),
  "",
  "## Result 2: monthly index S, September 2020 to June 2023",
  "",
  "S = lots in [c - 1k, c) / lots in [c - 20k, c + 20k), lots from 15 Sep 2020 to 30 Jun 2023 (September 2020 = 15-30 Sep). Plateau and build-up as in module C (means of monthly values; build-up = first month with S >= baseline + 50 % / 90 % of plateau - baseline). Baseline of 139k = mean over P1b; baseline of 75k = fitted asymptote of the decay (main) or the pre-level 2018-2019 (comparison). Decay of S_75: S_t = asymptote + A exp(-lambda (t - t0)), half-life ln(2) / lambda, delta-method SE (`tab_G2_dynamics_metrics.csv`).",
  "",
  md_row("Measure", "No bulk filter", "Bulk filter"),
  md_row("---", "---", "---"),
  md_row("S_139: baseline (mean over P1b, %) / plateau (%)",
         both(function(vv) sprintf("%s / %s", f(100 * gdy(vv, 139000)$baseline), f(100 * gdy(vv, 139000)$plateau)))),
  md_row("S_139: build-up 50 % / 90 % (months from June 2021)",
         both(function(vv) sprintf("%d / %d", gdy(vv, 139000)$buildup_50, gdy(vv, 139000)$buildup_90))),
  md_row("S_75: plateau (%)", both(function(vv) f(100 * gdy(vv, 75000, FREE)$plateau))),
  unlist(lapply(c("2021-06", "2021-08"), function(fr) {
    c(md_row(sprintf("S_75, free asymptote, fit %s to 2023-06: half-life (SE) [95 %% CI], months", fr),
             both(function(vv) { x <- gdy(vv, 75000, FREE, fr); sprintf("%s %s", fse(x$half_life, x$half_life_se), fci(x$half_life_ci_low, x$half_life_ci_high)) })),
      md_row(sprintf("S_75, free asymptote, fit %s: asymptote (%%), months in fit", fr),
             both(function(vv) { x <- gdy(vv, 75000, FREE, fr); sprintf("%s, %d", fse(100 * x$asymptote, 100 * x$asymptote_se), x$n_months) })))
  })),
  unlist(lapply(c("2021-06", "2021-08"), function(fr) {
    md_row(sprintf("Comparison: S_75 with pre-level 2018-2019 (%%) as asymptote, fit %s: half-life (SE)", fr),
           both(function(vv) { x <- gdy(vv, 75000, PRE, fr); sprintf("pre %s: %s", f(100 * x$baseline), fse(x$half_life, x$half_life_se)) }))
  })),
  md_row("Appendix only (not in the comparison table, because the window starts with the 75k regime): S_75 build-up 50 % / 90 % (months from Sep 2020), baseline = asymptote / = pre-level 2018-2019",
         both(function(vv) sprintf("%d / %d; %d / %d", gdy(vv, 75000, FREE)$buildup_50, gdy(vv, 75000, FREE)$buildup_90,
                                   gdy(vv, 75000, PRE)$buildup_50, gdy(vv, 75000, PRE)$buildup_90))),
  "",
  cen_note,
  "",
  md_row("Authorities", "Period", "S_139 (%), no bulk filter", "S_139 (%), bulk filter",
         "Share of lots in [119k, 159k), no filter / filter", "Share of lots in [138k, 139k), no filter / filter"),
  md_row("---", "---", "---", "---", "---", "---"),
  unlist(lapply(c("P1b", "2018-2019"), function(per) lapply(c("All", "Central", "Other"), function(au) {
    a <- scen("no_bulk_filter", au, per); b <- scen("bulk_filter", au, per)
    md_row(au, per, f(100 * a$S_mean), f(100 * b$S_mean),
           sprintf("%s %% / %s %%", f(100 * a$share_den, 1), f(100 * b$share_den, 1)),
           sprintf("%s %% / %s %%", f(100 * a$share_num, 1), f(100 * b$share_num, 1)))
  }))),
  "",
  "S_139 = mean of the monthly values (as the baseline); pooled values and counts in `tab_G2_s139_central.csv`.",
  "",
  "Figures (`output/figures/`, PNG and PDF): `fig_G2a_C2_event_time_<variant>` (C2 cut to September 2020 - June 2023, without the markers of P1a and of the EU threshold) and `fig_G2b_S1_C2_panel_<variant>` (left: the group's S1 redrawn from `S1_adjustment_curve_p1b.csv`; right: C2), each for `no_bulk_filter` and `bulk_filter`.",
  "",
  "## Result 3: density ratio P2/P1b",
  "",
  "Main result: Karl's D1 (5k bins 45k-250k, numerator without lots at multiples of 1,000, normalisation (i) = lots 250k-1M, level = mean ratio over 75k-125k, ramp = OLS slope of log ratio per 10k). Comparison: the group's B4 (10k bands (band, band + 10k], all lots, each period scaled by its count in (220k, 300k]), summarised over (80k, 130k] (`tab_G3_*`).",
  "",
  md_row("Measure", "Group (Stata)", "No bulk filter", "Bulk filter"),
  md_row("---", "---", "---", "---"),
  md_row("D1 level P2/P1b (SE)", "-", both(function(vv) fse(d1_lr[variant == vv]$level, d1_lr[variant == vv]$level_se, 3))),
  md_row("D1 ramp per 10k (SE), p", "-", both(function(vv) sprintf("%s, p = %s", fse(d1_lr[variant == vv]$ramp_per_10k, d1_lr[variant == vv]$ramp_se, 4), f(d1_lr[variant == vv]$ramp_p)))),
  md_row("B4 mean ratio, (80k, 130k]", f(b4_stata$mean_ratio, 3), both(function(vv) f(b4s(vv)$mean_ratio, 3))),
  md_row("B4 slope of log ratio per 10k (SE), p", sprintf("%s, p = %s", fse(b4_stata$ramp_per_10k, b4_stata$ramp_se, 4), f(b4_stata$ramp_p)),
         both(function(vv) sprintf("%s, p = %s", fse(b4s(vv)$ramp_per_10k, b4s(vv)$ramp_se, 4), f(b4s(vv)$ramp_p)))),
  "",
  sprintf("Without the bulk filter the B4 replication reproduces the counts nC and nP2 of %d of the %d bands of the group; the ratios per band are in `tab_G3_b4_bands.csv`.", b4_match, n_bands),
  "",
  "## Result 4: bunching at 139k with a strict cutoff",
  "",
  "Strict cutoff: the group's specification, but the lots at exactly 139,000 count to the first bin above, (139k, 140k]. Both bins lie in the excluded range, so the counterfactual does not change: the excess mass falls by exactly the number of lots at 139,000 and the missing mass above rises by the same number.",
  sprintf("Check: excess (as published) - excess (strict) in P2 = %s (no bulk filter) and %s (bulk filter); lots at 139,000 in P2: %s.",
          f(excess_shift[1], 2), f(excess_shift[2], 2), f(g4("no_bulk_filter", "group, strict", "P2")$n_at_139000, 0)),
  "",
  md_row("Specification", "Sample", "b(P2) [95 % CI]", "b(P1b) [95 % CI]", "Difference (SE) [95 % CI]", "Excess P2 (lots)", "Missing mass above, P2 (lots)"),
  md_row("---", "---", "---", "---", "---", "---", "---"),
  md_row("Group, as published (139,000 below)", "Group (Stata)",
         sprintf("%s %s", f(st("P2")$b), fci(st("P2")$ci_low, st("P2")$ci_high)),
         sprintf("%s %s", f(st("P1b")$b), fci(st("P1b")$ci_low, st("P1b")$ci_high)),
         sprintf("%s %s", fse(st("diff")$b, st("diff")$se), fci(st("diff")$ci_low, st("diff")$ci_high)), "-", "-"),
  unlist(lapply(c("group, strict", "group, as published", "Karl"), function(sp) {
    lapply(c("no_bulk_filter", "bulk_filter"), function(vv) {
      p2 <- g4(vv, sp, "P2"); p1 <- g4(vv, sp, "P1b"); d <- g4(vv, sp, "diff")
      md_row(c(`group, strict` = "Group, strict cutoff (139,000 above)",
               `group, as published` = "Group, as published (139,000 below)",
               Karl = "Karl (module B: [95k, 200k), 139,000 above)")[[sp]],
             c(no_bulk_filter = "No bulk filter", bulk_filter = "Bulk filter")[[vv]],
             sprintf("%s %s", f(p2$b), fci(p2$ci_low, p2$ci_high)),
             sprintf("%s %s", f(p1$b), fci(p1$ci_low, p1$ci_high)),
             sprintf("%s %s", fse(d$b, d$se), fci(d$ci_low, d$ci_high)),
             f(p2$excess, 0), f(p2$missing, 0))
    })
  })),
  "",
  "LaTeX rows in the format of `I_bunch_sens_p1b.tex` (columns b(P2), b(P1b), difference): `output/tables/tex/I_bunch_sens_strict_p1b.tex` (group sample without bulk filter, as in their table) and `output/tables/tex/I_bunch_sens_strict_bulkfilter_p1b.tex`:",
  "",
  "```",
  readLines(file.path(GROUP_TAB_DIR, "tex", "I_bunch_sens_strict_p1b.tex")),
  readLines(file.path(GROUP_TAB_DIR, "tex", "I_bunch_sens_strict_bulkfilter_p1b.tex")),
  "```",
  "",
  "Bootstrap intervals differ slightly from Stata because R draws other random numbers; point estimates do not (as published: b(P2), b(P1b) and the difference equal the group's values).",
  "",
  "## Files",
  "",
  "- Tables (`output/tables/`): `tab_G0_*` (sample flow, control values, B3/B4 replication), `tab_G1_*` (result 1), `tab_G2_*` (result 2), `tab_G3_*` (result 3), `tab_G4_bunching_139k.csv` (result 4), `tex/*.tex`.",
  "- Figures (`output/figures/`): `fig_G2a_*`, `fig_G2b_*` (PNG 300 dpi and PDF).",
  "- How to run: `Rscript run.R` in the folder for_group; `code/make_extract.R` rebuilds the data extract from the raw ANAC files (see `README.md`)."
)
writeLines(md, file.path(GROUP_OUT_DIR, "RESULTS_GROUP.md"), useBytes = TRUE)
msg("Wrote output/RESULTS_GROUP.md (", length(md), " lines)")
msg(sprintf("12_group_results.R finished in %.1f seconds.", as.numeric(difftime(Sys.time(), t_start, units = "secs"))))
