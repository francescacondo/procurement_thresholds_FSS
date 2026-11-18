# =============================================================================
# 11_group_sample.R -- Load the group's sample and check it
# -----------------------------------------------------------------------------
# Purpose : Loads the extract of the sample of the group's Stata pipeline
#           (repo_gruppe/code/full_analysis_commented.do, sections 1.1-1.3),
#           data/lots_group.rds. The extract was built from the 72 raw ANAC
#           files by code/make_extract.R with exactly the group's rules
#           (services/supplies, ordinary sectors, importo_lotto > 0, years
#           2018-2023, stato filter, framework call-offs dropped; cancelled and
#           PNRR lots stay). Karl's bulk flag (>= 50 lots with the same value
#           per authority and month) is a column but is NOT applied here.
#           Writes the sample flow of make_extract.R (data/sample_flow.csv) as
#           tab_G0_sample_flow.csv and checks the 140 control values against
#           the group's tables:
#             a) 1,454,116 lots; b) 2,298 lots at exactly 139,000 in P2;
#             c) all band counts nC and nP2 of B4_band_ratios_p1b.csv;
#             d) bunching with the group's specification: b(P2) = 12.80,
#                b(P1b) = 0.50 and all 8 rows of B3 (two decimals);
#             e) four descriptive facts of the group (descriptives_p1b.csv).
#           The checks that need the raw files (headers of the 72 files, raw
#           text of dates and values) are in code/make_extract.R.
# Inputs  : data/lots_group.rds, data/sample_flow.csv;
#           data/group_tables/B3_..., B4_..., descriptives_p1b.csv
# Outputs : output/tables/tab_G0_*.csv   sample flow, controls, B3 and B4
#                                        replication
# Runtime : a few seconds
# Usage   : run by run.R; alone: Rscript code/11_group_sample.R (in for_group)
# =============================================================================

source(file.path("code", "00_setup.R"))
t_start <- Sys.time()
cat("\n===== 11_group_sample.R =====", format(t_start, "%Y-%m-%d %H:%M:%S"), "\n")
group_dirs()

# ---- 1. Extract and sample flow (built by make_extract.R) ----------------------------------
lots <- readRDS(GROUP_LOTS_RDS)
missing_cols <- setdiff(GROUP_EXTRACT_COLS, names(lots))
if (length(missing_cols) > 0) {
  stop("data/lots_group.rds lacks the columns ", paste(missing_cols, collapse = ", "),
       ". Rebuild it with code/make_extract.R.")
}
msg("Loaded data/lots_group.rds: ", fmt_n(nrow(lots)), " lots, bulk flag not applied")

flow <- group_read_flow()
group_save_table(flow, "tab_G0_sample_flow")
print(flow)
if (flow[.N, n_lots] != nrow(lots)) {
  stop("The last step of data/sample_flow.csv does not match the number of lots in data/lots_group.rds.")
}

# ---- 2. Control values a)-e) ----------------------------------------------------------------
desc  <- fread(file.path(GROUP_REPO_TAB, "descriptives_p1b.csv"))
b3_st <- fread(file.path(GROUP_REPO_TAB, "B3_bunching_sensitivity_p1b.csv"))
b4_st <- fread(file.path(GROUP_REPO_TAB, "B4_band_ratios_p1b.csv"))
d_val <- function(nm) desc[name == nm, value]

ctr <- list()
ctr[[1]] <- group_ctrl("a", "Lots in the group sample", GROUP_EXPECTED_N_LOTS, nrow(lots))
ctr[[2]] <- group_ctrl("b", "Lots at exactly 139,000 in P2", GROUP_EXPECTED_N139_P2,
                       lots[regime == "P2" & v == 139000, .N])

# c) B4: band counts of the control period (nC) and of P2 (nP2)
b4_r <- group_b4_bands(lots)
b4_cmp <- merge(b4_st[, .(band10, nC_stata = nC, nP2_stata = nP2, refC_stata = refC,
                          refP2_stata = refP2, ratio_stata = ratio)],
                b4_r[, .(band10, nC_R = nC, nP2_R = nP2, refC_R = refC, refP2_R = refP2,
                         ratio_R = ratio)], by = "band10", all = TRUE)
group_save_table(b4_cmp, "tab_G0_B4_replication")
for (i in seq_len(nrow(b4_cmp))) {
  r <- b4_cmp[i]
  ctr[[length(ctr) + 1]] <- group_ctrl(sprintf("c_nC_%d", r$band10),
                                       sprintf("B4 nC, band (%dk, %dk]", r$band10, r$band10 + 10),
                                       r$nC_stata, r$nC_R)
  ctr[[length(ctr) + 1]] <- group_ctrl(sprintf("c_nP2_%d", r$band10),
                                       sprintf("B4 nP2, band (%dk, %dk]", r$band10, r$band10 + 10),
                                       r$nP2_stata, r$nP2_R)
}

# d) Bunching at 139k with the group's specification: main values and B3 grid
b3_r <- group_b3_grid(lots)
ctr[[length(ctr) + 1]] <- group_ctrl("d_main_P2",  "b(P2), main specification (3.2)",  12.80, b3_r[spec == 1, bP2], 2)
ctr[[length(ctr) + 1]] <- group_ctrl("d_main_P1b", "b(P1b), main specification (3.2)", 0.50,  b3_r[spec == 1, bP1b], 2)
b3_cols <- c("bP0", "excessP0", "missingP0", "bP1b", "excessP1b", "missingP1b",
             "bP2", "excessP2", "missingP2", "b_diff")
b3_long <- merge(melt(b3_st, id.vars = c("spec", "label"), measure.vars = b3_cols,
                      value.name = "stata"),
                 melt(b3_r, id.vars = c("spec", "label"), measure.vars = b3_cols,
                      value.name = "R")[, label := NULL],
                 by = c("spec", "variable"))
b3_long[, `:=`(abs_diff = R - stata, match_2dec = round(R, 2) == round(stata, 2))]
setorder(b3_long, spec, variable)
group_save_table(b3_long, "tab_G0_B3_replication")
for (i in seq_len(nrow(b3_long))) {
  r <- b3_long[i]
  ctr[[length(ctr) + 1]] <- group_ctrl(sprintf("d_B3_%d_%s", r$spec, r$variable),
                                       sprintf("B3 row %d (%s): %s", r$spec, r$label, r$variable),
                                       r$stata, r$R, 2, half_unit = TRUE)
}

# e) Additional descriptive facts of the group (section 1.13)
ctr[[length(ctr) + 1]] <- group_ctrl("e_cancelled", "Lots with CIG outcome ANNULLATA (codes 2, 6, 7)",
                                     d_val("n_cancelled"), lots[cancelled_esito == TRUE, .N])
ctr[[length(ctr) + 1]] <- group_ctrl("e_share_central", "Share of lots of central authorities",
                                     d_val("share_central"), lots[, mean(central)], 4)
ctr[[length(ctr) + 1]] <- group_ctrl("e_window_p1b", "Lots within +/-40k of 139k in P1b",
                                     d_val("n_window_p1b"), lots[regime == "P1b" & abs(v - 139000) <= 40000, .N])
ctr[[length(ctr) + 1]] <- group_ctrl("e_window_p0", "Lots within +/-40k of 139k in P0",
                                     d_val("n_window_p0"), lots[regime == "P0" & abs(v - 139000) <= 40000, .N])

controls <- rbindlist(ctr)
group_save_table(controls, "tab_G0_controls")

# ---- 3. Result ------------------------------------------------------------------------------------
cat("\nControl values: ", controls[pass == TRUE, .N], " of ", nrow(controls), " pass.\n", sep = "")
if (any(!controls$pass)) print(controls[pass == FALSE])
msg(sprintf("11_group_sample.R finished in %.1f seconds.",
            as.numeric(difftime(Sys.time(), t_start, units = "secs"))))
if (any(!controls$pass)) {
  stop("Control values failed (see output/tables/tab_G0_controls.csv).")
}
