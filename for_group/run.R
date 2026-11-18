# =============================================================================
# run.R -- Run everything: checks against the group's tables, then the results
# -----------------------------------------------------------------------------
# Purpose : Runs, each in its own R process and in this order,
#             code/11_group_sample.R   load the extract of the group sample
#                                      and check 140 control values against
#                                      the group's tables
#             code/12_group_results.R  four results on this sample, without
#                                      and with the bulk filter; tables,
#                                      figures and RESULTS_GROUP.md
#           and stops at the first error. The raw data are not needed:
#           code/make_extract.R rebuilds the extract from them (optional, not
#           run here; see README.md).
# Usage   : open a terminal in the folder for_group and type
#               Rscript run.R
#           In RStudio: open run.R, Session > Set Working Directory > To Source
#           File Location, then click "Source".
# Needs   : R with the packages data.table, ggplot2, scales and patchwork;
#           data/lots_group.rds, data/sample_flow.csv, data/group_tables/
# Outputs : everything in output/ (tables/, figures/, logs/, RESULTS_GROUP.md);
#           run log in output/logs/run_log.csv
# Runtime : about 15 seconds
# =============================================================================

# ---- 1. Started in the folder for_group? -------------------------------------------------
# Checked by the files of the folder, so that a renamed copy also works.
if (!all(file.exists("run.R", file.path("code", "00_setup.R"), "data"))) {
  stop("Please start run.R inside the folder for_group:\n",
       "  open a terminal in for_group and type   Rscript run.R\n",
       "  (current working directory: ", getwd(), ")", call. = FALSE)
}

# ---- 2. Packages and inputs ---------------------------------------------------------------
pkgs <- c("data.table", "ggplot2", "scales", "patchwork")
missing_pkgs <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_pkgs) > 0) {
  stop("Missing R packages: ", paste(missing_pkgs, collapse = ", "), "\n",
       "Install them with  install.packages(c(\"", paste(missing_pkgs, collapse = "\", \""), "\"))",
       call. = FALSE)
}
needed <- c(file.path("data", c("lots_group.rds", "sample_flow.csv")),
            file.path("data", "group_tables",
                      c("B3_bunching_sensitivity_p1b.csv", "B4_band_ratios_p1b.csv",
                        "S1_adjustment_curve_p1b.csv", "descriptives_p1b.csv",
                        "coefficients_p1b.csv")))
missing <- needed[!file.exists(needed)]
if (length(missing) > 0) {
  stop("Missing inputs:\n  ", paste(missing, collapse = "\n  "), call. = FALSE)
}

# ---- 3. Run the two scripts, each in its own R process ---------------------------------------
scripts  <- c("11_group_sample.R", "12_group_results.R")
rscript  <- file.path(R.home("bin"), "Rscript")
Sys.setenv(LANG = "en_US.UTF-8", LC_ALL = "en_US.UTF-8")
dir.create(file.path("output", "logs"), recursive = TRUE, showWarnings = FALSE)
log_path <- file.path("output", "logs", "run_log.csv")
run_id   <- format(Sys.time(), "%Y%m%d_%H%M%S")
t_start  <- Sys.time()
cat("run.R:", length(scripts), "scripts,", R.version.string, "\n")

for (s in scripts) {
  path <- file.path("code", s)
  t0 <- Sys.time()
  status <- system2(rscript, shQuote(path))          # output appears in the console
  secs <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  utils::write.table(data.frame(run_id = run_id, script = s, status = status, seconds = round(secs, 1),
                                finished_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
                     log_path, sep = ",", row.names = FALSE, quote = FALSE,
                     col.names = !file.exists(log_path), append = file.exists(log_path))
  if (status != 0) {
    stop("Script ", s, " stopped with an error (exit status ", status, "). See the messages above.",
         call. = FALSE)
  }
}

total <- as.numeric(difftime(Sys.time(), t_start, units = "secs"))
cat(sprintf("\nrun.R finished without errors: %d scripts in %.0f seconds.\n", length(scripts), total))
cat("Results: output/RESULTS_GROUP.md (tables in output/tables/, figures in output/figures/)\n")
