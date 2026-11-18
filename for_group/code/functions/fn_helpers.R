# =============================================================================
# fn_helpers.R -- Small helper functions used by all scripts
# -----------------------------------------------------------------------------
# Contents: start_script(), end_script(), msg(), fmt_n(), upsert_csv(),
#           log_step(), log_diagnostic(), log_warning(), record_controls(),
#           save_table(), save_figure(), write_session_info()
# Logs are "idempotent": re-running a script replaces its old log rows
# instead of adding duplicates.
# =============================================================================

# start_script(): print a header, remember the script name and start time,
#   and delete the warnings that this script logged in an earlier run.
# Input : name of the script, e.g. "01_import.R"
# Output: none (sets SCRIPT_NAME and SCRIPT_START in the global environment)
start_script <- function(name) {
  assign("SCRIPT_NAME", name, envir = globalenv())
  assign("SCRIPT_START", Sys.time(), envir = globalenv())
  warn_file <- file.path(LOG_DIR, "warnings.csv")
  if (file.exists(warn_file)) {
    w <- fread(warn_file, colClasses = "character")
    fwrite(w[script != name], warn_file)
  }
  cat("\n=====", name, "=====", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n")
}

# end_script(): print how long the script took.
end_script <- function() {
  secs <- as.numeric(difftime(Sys.time(), SCRIPT_START, units = "secs"))
  msg(sprintf("%s finished in %.1f seconds.", SCRIPT_NAME, secs))
}

# msg(): print a time-stamped progress message.
# Input : any number of strings or numbers (pasted together without spaces)
msg <- function(...) {
  cat(format(Sys.time(), "[%H:%M:%S] "), ..., "\n", sep = "")
}

# fmt_n(): format numbers with thousands separators, e.g. 1733719 -> "1,733,719".
fmt_n <- function(x, digits = 0) {
  ifelse(is.na(x), "NA",
         formatC(x, format = "f", digits = digits, big.mark = ","))
}

# upsert_csv(): write rows into a CSV file and replace old rows with the same key.
# Input : new_rows (data.table), path (CSV file), key (name(s) of key columns),
#         order_by (columns used to sort the file)
# Output: the complete updated table (invisible); the file is rewritten
upsert_csv <- function(new_rows, path, key, order_by = key) {
  new_rows <- as.data.table(new_rows)
  new_rows[, (key) := lapply(.SD, as.character), .SDcols = key]
  if (file.exists(path) && file.size(path) > 0) {
    old <- fread(path, colClasses = list(character = key), encoding = "UTF-8")
    old <- old[!new_rows, on = key]          # drop rows that are replaced
    new_rows <- rbind(old, new_rows, fill = TRUE)
  }
  setorderv(new_rows, order_by)
  fwrite(new_rows, path)
  invisible(new_rows)
}

# log_step(): record one step of the sample flow in output/logs/sample_flow.csv
#   (columns step, description, n_lots, n_dropped; spec section 4).
log_step <- function(step, description, n_lots, n_dropped = NA_real_) {
  upsert_csv(data.table(step = step, description = description,
                        n_lots = n_lots, n_dropped = n_dropped),
             file.path(LOG_DIR, "sample_flow.csv"), key = "step")
  msg(sprintf("Step %s: %s | lots: %s | dropped: %s",
              step, description, fmt_n(n_lots), fmt_n(n_dropped)))
}

# log_diagnostic(): record a single number or text (e.g. "rows with missing
#   value") in output/logs/diagnostics.csv.
log_diagnostic <- function(name, value, note = "") {
  value_chr <- if (is.numeric(value)) {
    trimws(formatC(value, format = "fg", digits = 10, big.mark = ""))
  } else {
    as.character(value)
  }
  # (the column is called "name" because "key" is a reserved argument of data.table())
  upsert_csv(data.table(name = name, value = value_chr, note = note,
                        script = get0("SCRIPT_NAME", ifnotfound = "interactive")),
             file.path(LOG_DIR, "diagnostics.csv"), key = "name")
  msg("Diagnostic ", name, " = ", value_chr, if (nzchar(note)) paste0(" (", note, ")"))
}

# log_warning(): record a warning (e.g. a model that did not converge) in
#   output/logs/warnings.csv and print it. 10_summary.R lists these warnings.
log_warning <- function(text) {
  path <- file.path(LOG_DIR, "warnings.csv")
  row <- data.table(script = get0("SCRIPT_NAME", ifnotfound = "interactive"),
                    time = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
                    message = text)
  if (file.exists(path)) row <- rbind(fread(path, colClasses = "character"), row)
  fwrite(row, path)
  msg("WARNING: ", text)
}

# record_controls(): compare computed control values with the expected values
#   and store them in output/logs/control_values.csv (one row per id).
# Input : data.table with columns id, group, description, expected, computed,
#         tolerance_pct (allowed deviation in percent)
# Output: the updated table (invisible). deviation_pct = 100 * (computed -
#         expected) / expected; outside_tolerance = TRUE if |deviation| > tolerance.
record_controls <- function(controls) {
  ctr <- copy(as.data.table(controls))
  ctr[, deviation_pct := ifelse(expected == 0,
                                ifelse(computed == 0, 0, NA_real_),
                                100 * (computed - expected) / abs(expected))]
  ctr[, outside_tolerance := is.na(deviation_pct) | abs(deviation_pct) > tolerance_pct]
  ctr[, script := get0("SCRIPT_NAME", ifnotfound = "interactive")]
  out <- upsert_csv(ctr, file.path(LOG_DIR, "control_values.csv"), key = "id")
  for (i in seq_len(nrow(ctr))) {
    msg(sprintf("Control %-8s expected %12s | computed %12s | deviation %7.2f%% %s",
                ctr$id[i], format(ctr$expected[i], big.mark = ","),
                format(round(ctr$computed[i], 4), big.mark = ","),
                ctr$deviation_pct[i], ifelse(ctr$outside_tolerance[i], "<-- CHECK", "")))
  }
  invisible(out)
}

# save_table(): write a table as CSV to output/tables/<name>.csv
save_table <- function(dt, name) {
  path <- file.path(TAB_DIR, paste0(name, ".csv"))
  fwrite(dt, path)
  msg("Saved table  ", basename(path), " (", nrow(dt), " rows)")
  invisible(path)
}

# save_figure(): save a ggplot as PNG (300 dpi) and PDF in output/figures/.
# Input : p (ggplot or patchwork object), name (file name without extension),
#         height in inches (width is 7 inches by default, spec section 4)
save_figure <- function(p, name, height = 5, width = FIG_WIDTH) {
  png_path <- file.path(FIG_DIR, paste0(name, ".png"))
  pdf_path <- file.path(FIG_DIR, paste0(name, ".pdf"))
  ggsave(png_path, p, width = width, height = height, dpi = FIG_DPI, bg = "white")
  # Standard PDF device (the cairo PDF device needs XQuartz, which is not
  # installed on this Mac). Labels therefore use plain ASCII characters.
  ggsave(pdf_path, p, width = width, height = height, device = "pdf")
  msg("Saved figure ", basename(png_path), " + .pdf")
  invisible(png_path)
}

# write_session_info(): store R version and package versions for reproducibility.
write_session_info <- function() {
  writeLines(capture.output(sessionInfo()), file.path(LOG_DIR, "session_info.txt"))
}
