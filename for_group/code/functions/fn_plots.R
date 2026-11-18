# =============================================================================
# fn_plots.R -- Common style for all figures
# -----------------------------------------------------------------------------
# Contents: theme_karl(), label_k(), date_en(), series_shapes(),
#           time_marker_table(), time_markers(), shade_regime(),
#           plot_index_quarterly(), paper_figure(), save_paper_figure(),
#           threshold_lines()
# Style (Karl's bachelor thesis, decision D42): theme_bw(base_size = 11) in
# Helvetica, light grey major grid, black panel frame, grey facet strips,
# legend at the bottom without a title, Okabe-Ito colours (00_setup.R).
# English labels, euro amounts as "75k", thresholds as dashed vertical lines.
# =============================================================================

# theme_karl(): the common ggplot theme of all figures.
# Input : base_size  base font size in points
#         rotate_x   TRUE: x-axis text turned by 45 degrees (date and value
#                    axes); FALSE for axes with categories (heatmap B1)
# Output: ggplot theme
theme_karl <- function(base_size = 11, rotate_x = TRUE) {
  th <- theme_bw(base_size = base_size, base_family = FIG_FONT) +
    theme(panel.grid.minor  = element_blank(),
          panel.grid.major  = element_line(colour = "grey88", linewidth = 0.4),
          panel.border      = element_rect(colour = "black", fill = NA, linewidth = 0.5),
          strip.background  = element_rect(fill = "grey90", colour = "black", linewidth = 0.5),
          strip.text        = element_text(face = "bold"),
          axis.text         = element_text(colour = "grey30"),
          legend.position   = "bottom",
          legend.direction  = "horizontal",
          legend.title      = element_blank(),
          plot.title.position = "plot",
          plot.title        = element_text(face = "bold"),
          # extra space on the right so that the last x-axis label is not cut
          plot.margin       = margin(6, 14, 6, 6))
  if (rotate_x) th <- th + theme(axis.text.x = element_text(angle = 45, hjust = 1, vjust = 1))
  th
}

# Text written into the panels (geom_text, geom_label, annotate("text")) uses
# the same font as the theme.
update_geom_defaults("text",  list(family = FIG_FONT))
update_geom_defaults("label", list(family = FIG_FONT))

# label_k(): axis labels in thousands of euro, e.g. 75000 -> "75k".
label_k <- scales::label_number(scale = 1e-3, suffix = "k", big.mark = ",")

# date_en(): dates as "15 Sep 2020" with English month names, independent of
#   the language settings of the computer.
date_en <- function(d) {
  d <- as.Date(d)
  sprintf("%d %s %s", as.integer(format(d, "%d")), month.abb[as.integer(format(d, "%m"))],
          format(d, "%Y"))
}

# series_shapes(): point shapes for the series of a figure with several lines
#   (circle, triangle, square, diamond, cross), named like the colours.
# Input : keys  names of the series (e.g. names of the colour vector)
# Output: named vector of shapes
series_shapes <- function(keys) setNames(SERIES_SHAPES[seq_along(keys)], keys)

# time_marker_table(): the dates marked in time-series figures: the four regime
#   switches (dashed) and the EU threshold change of 2020-01-01 (thin grey).
# Input : to_x  function that turns dates into positions on the x axis
#               (identity for a date axis, event_time_of_date() for event time)
# Output: data.table with columns x, label, type ("switch" or "eu")
time_marker_table <- function(to_x = as.Date) {
  sw <- REGIMES[-1]
  rbind(data.table(x = to_x(sw$start),
                   label = sprintf("%s: %s (%s)", sw$regime, label_k(sw$c), date_en(sw$start)),
                   type = "switch"),
        data.table(x = to_x(EU_139_DATE), label = EU_139_LABEL, type = "eu"))
}

# time_markers(): vertical lines with rotated labels (written along the line,
#   on its left side, starting at the top of the panel). Regime switches are
#   grey dashed lines, the EU threshold change a thin solid grey line.
# Input : markers (output of time_marker_table(), possibly filtered),
#         label_size (text size in mm), show_labels
# Output: list of ggplot layers (add with "+")
time_markers <- function(markers, label_size = 2.5, show_labels = TRUE) {
  lines <- list(
    geom_vline(data = markers[type == "switch"], aes(xintercept = x),
               linetype = "dashed", colour = "grey40", linewidth = 0.4),
    geom_vline(data = markers[type == "eu"], aes(xintercept = x),
               colour = "grey65", linewidth = 0.3))
  if (!show_labels) return(lines)
  c(lines, list(
    # fixed colours (no colour scale), so that the figure keeps its own colour scale
    geom_text(data = markers[type == "switch"], aes(x = x, y = Inf, label = label),
              angle = 90, hjust = 1.03, vjust = -0.5, size = label_size,
              colour = "grey20", inherit.aes = FALSE),
    geom_text(data = markers[type == "eu"], aes(x = x, y = Inf, label = label),
              angle = 90, hjust = 1.03, vjust = -0.5, size = label_size,
              colour = "grey45", inherit.aes = FALSE)
  ))
}

# shade_regime(): light grey rectangle behind the whole height of the panel
#   for the time of one regime (default P1b, the 75k regime, like the March
#   2020 shading in Karl's bachelor thesis). Draw it first, before the lines.
# Input : to_x   function that turns dates into positions on the x axis
#         shade  regime to shade
#         ymin, ymax  vertical extent; -Inf / Inf = the whole panel. On a log
#                y axis -Inf does not exist: pass the lower limit of the axis.
# Output: ggplot layer
shade_regime <- function(to_x = as.Date, shade = "P1b", ymin = -Inf, ymax = Inf) {
  i <- which(REGIMES$regime == shade)
  annotate("rect", xmin = to_x(REGIMES$start[i]), xmax = to_x(REGIMES$end[i] + 1L),
           ymin = ymin, ymax = ymax, fill = SHADE_FILL)
}

# plot_index_quarterly(): quarterly bunching index (in %) over time, one line
#   per value of `colour_by` (e.g. the threshold, or a group in module E), with
#   the regime switches and the EU threshold change marked and P1b shaded.
# Input : d (columns quarter, S and the colour_by column), colours (named
#         vector), shapes (named vector; NULL = threshold shapes for
#         thresholds, otherwise circle, triangle, ... in the order of
#         colours), labels (legend labels, named like colours), title, subtitle
# Output: ggplot object
plot_index_quarterly <- function(d, colour_by = "threshold", colours = THRESHOLD_COLOURS,
                                 shapes = NULL, labels = waiver(), title = NULL, subtitle = NULL,
                                 show_marker_labels = TRUE, y_max = NULL) {
  d <- copy(d)
  d[, x := quarter_mid_date(quarter)]
  d[, grp := factor(get(colour_by), levels = names(colours))]
  if (is.null(shapes)) {
    shapes <- if (colour_by == "threshold") THRESHOLD_SHAPES[names(colours)] else series_shapes(names(colours))
  }
  if (is.null(y_max)) y_max <- max(100 * d$S, na.rm = TRUE)
  # headroom above the data for the rotated labels of the vertical lines
  headroom <- if (show_marker_labels) 1.75 else 1.1
  ggplot(d, aes(x = x, y = 100 * S, colour = grp, shape = grp)) +
    shade_regime(as.Date) +
    time_markers(time_marker_table(as.Date), show_labels = show_marker_labels) +
    geom_line(linewidth = TS_LINEWIDTH) +
    geom_point(size = TS_POINT_SIZE) +
    scale_colour_manual(values = colours, labels = labels, name = NULL) +
    scale_shape_manual(values = shapes, labels = labels, name = NULL) +
    scale_x_date(date_breaks = "1 year", date_labels = "%Y",
                 limits = as.Date(c("2018-01-01", "2024-01-01")), expand = expansion(mult = 0.01)) +
    scale_y_continuous(limits = c(0, y_max * headroom), breaks = seq(0, 100, 5),
                       expand = expansion(mult = c(0, 0))) +
    labs(x = NULL, y = "Bunching index S (%)", title = title, subtitle = subtitle) +
    theme_karl() +
    theme(plot.subtitle = element_text(size = 9))
}

# paper_figure(): print version of a figure for the paper (Karl, decision K17).
#   Same content; only the layout changes: no title and no subtitle (they go
#   into the caption) and all text at least `min_pt` points when the figure is
#   printed at its saved width (PAPER_WIDTH). Theme text (axis labels, legend,
#   facet strips) is set to min_pt + 0.5 and axis titles to min_pt + 1.5
#   points (legends have no title, theme_karl()); text layers (geom_text, geom_label, annotate("text"))
#   smaller than min_pt are enlarged to min_pt. The text layers are copied
#   first, so that the original figure object is not changed.
# Input : p (ggplot object), min_pt (minimum font size in points)
# Output: ggplot object
paper_figure <- function(p, min_pt = PAPER_MIN_PT) {
  min_mm <- min_pt / ggplot2::.pt          # geom text sizes are given in mm
  p <- p + labs(title = NULL, subtitle = NULL) +
    theme(axis.text    = element_text(size = min_pt + 0.5),
          legend.text  = element_text(size = min_pt + 0.5),
          strip.text   = element_text(size = min_pt + 0.5),
          axis.title   = element_text(size = min_pt + 1.5))
  p$layers <- lapply(p$layers, function(l) {
    sz <- l$aes_params$size
    if (inherits(l$geom, c("GeomText", "GeomLabel")) && is.numeric(sz) && any(sz < min_mm)) {
      # copy of the layer that inherits everything else from the original layer
      # (a new name is needed: ggproto() refers to its parent by name)
      l_copy <- ggplot2::ggproto(NULL, l)
      l_copy$aes_params$size <- pmax(sz, min_mm)
      return(l_copy)
    }
    l
  })
  p
}

# save_paper_figure(): save the print version (see paper_figure()) as PNG
#   (300 dpi) and PDF in output/paper/, width PAPER_WIDTH (6.5 inches).
save_paper_figure <- function(p, name, height) {
  dir.create(PAPER_DIR, recursive = TRUE, showWarnings = FALSE)
  png_path <- file.path(PAPER_DIR, paste0(name, ".png"))
  ggsave(png_path, p, width = PAPER_WIDTH, height = height, dpi = FIG_DPI, bg = "white")
  ggsave(file.path(PAPER_DIR, paste0(name, ".pdf")), p, width = PAPER_WIDTH, height = height,
         device = "pdf")
  msg("Saved paper figure ", basename(png_path), " + .pdf")
  invisible(png_path)
}

# threshold_lines(): dashed vertical lines at the given thresholds.
# Input : x (thresholds in euro), colour, linewidth
# Output: a ggplot layer that can be added with "+"
threshold_lines <- function(x = THRESHOLD_LINES, colour = "grey40", linewidth = 0.4) {
  geom_vline(xintercept = x, linetype = "dashed", colour = colour, linewidth = linewidth)
}
