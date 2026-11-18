# =============================================================================
# 00_setup.R -- Packages, paths, constants and helper functions
# -----------------------------------------------------------------------------
# Purpose : Shared setup for all scripts. Every script starts with
#             source(file.path("code", "00_setup.R"))
#           This file loads the packages, defines the folder paths, the legal
#           regimes and thresholds, the colours of the figures, and loads the
#           helper functions from code/functions/.
# Inputs  : the files in code/functions/
# Outputs : objects in the R session (the scripts create the output folders)
# Runtime : about 1 second
# Usage   : the working directory must be the folder for_group (run.R checks
#           this). In RStudio: Session > Set Working Directory > Choose Directory.
# -----------------------------------------------------------------------------
# A very short data.table primer (used in all scripts):
#   dt[i, j, by]      i = which rows, j = what to compute, by = groups
#   dt[v > 1000]      keep rows with v > 1000
#   dt[, .N, by = x]  count rows (.N) per value of x
#   dt[, y := v * 2]  add or overwrite column y "by reference" (no copy)
#   .(a = ..., b = ...) is short for list(a = ..., b = ...)
# =============================================================================

# ---- 1. Packages -------------------------------------------------------------
# Only the four CRAN packages that these scripts use.
suppressPackageStartupMessages({
  library(data.table)  # fast import, filtering and aggregation
  library(ggplot2)     # figures
  library(scales)      # axis labels such as "75k"
  library(patchwork)   # combine several ggplots into one figure
})
options(scipen = 999)  # print 1000000 instead of 1e+06

# The raw data are UTF-8 (Italian accents). RStudio uses a UTF-8 locale by
# default; Rscript in a terminal may start with the plain "C" locale.
if (!isTRUE(l10n_info()[["UTF-8"]])) {
  invisible(suppressWarnings(Sys.setlocale("LC_CTYPE", "en_US.UTF-8")))
}

# When run with Rscript, R would write stray plots to "Rplots.pdf" in the
# project folder. Figures are saved explicitly with save_figure(), so the
# default device is set to a "null" PDF device that writes no file.
if (!interactive()) options(device = function(...) grDevices::pdf(file = NULL))

# ---- 2. Paths -----------------------------------------------------------------
# All paths are relative to the folder for_group, which must be the working
# directory. Inputs are read from data/, everything is written to output/.
ROOT_DIR <- normalizePath(getwd(), mustWork = TRUE)
CODE_DIR <- file.path(ROOT_DIR, "code")
DATA_DIR <- file.path(ROOT_DIR, "data")      # inputs (shipped): extract, sample flow, group tables
OUT_DIR  <- file.path(ROOT_DIR, "output")    # created by the scripts, not shipped
FIG_DIR  <- file.path(OUT_DIR, "figures")    # PNG (300 dpi) + PDF
TAB_DIR  <- file.path(OUT_DIR, "tables")     # CSV tables
LOG_DIR  <- file.path(OUT_DIR, "logs")       # run log, checks of the raw files

if (!file.exists(file.path(CODE_DIR, "00_setup.R")) || !dir.exists(DATA_DIR)) {
  stop("Folders 'code' and 'data' not found in ", ROOT_DIR, ".\n",
       "Please set the working directory to the folder for_group.")
}

# ---- 3. Legal regimes (spec, section 2) ----------------------------------------
# Regimes are assigned by the CIG publication date (data_pubblicazione).
# c = direct-award threshold for services and supplies (direct award only for
# values STRICTLY below c). Months = days / 30.4375 (average month length).
REGIMES <- data.table(
  regime = c("P0", "P1a", "P1b", "P2", "P3"),
  start  = as.IDate(c("2018-01-01", "2020-07-17", "2020-09-15", "2021-06-01", "2023-07-01")),
  end    = as.IDate(c("2020-07-16", "2020-09-14", "2021-05-31", "2023-06-30", "2023-12-31")),
  c      = c(40000, 150000, 75000, 139000, 140000),
  legal_basis = c("Art. 36(2)(a) D.Lgs. 50/2016",
                  "DL 76/2020, Art. 1(2)(a), original version",
                  "DL 76/2020 as amended by L. 120/2020",
                  "DL 77/2021, Art. 51",
                  "Art. 50(1)(b) D.Lgs. 36/2023")
)
REGIMES[, days := as.integer(end - start) + 1L]
REGIMES[, months := days / 30.4375]
REGIME_LEVELS <- REGIMES$regime              # "P0" "P1a" "P1b" "P2" "P3"
REGIME_SWITCHES <- REGIMES$start[-1]          # 2020-07-17, 2020-09-15, 2021-06-01, 2023-07-01
DATA_START <- as.IDate("2018-01-01")
DATA_END   <- as.IDate("2023-12-31")

# ---- 4. Value ranges and sample rules -------------------------------------------
VALUE_MIN <- 1000          # step 3: keep 1,000 <= v < 1,000,000
VALUE_MAX <- 1e6
WINDOW    <- c(45000, 250000)   # analysis window (below 45k SmartCIG lots are missing)
REF_BAND  <- c(250000, 1e6)     # reference band
BULK_MIN_LOTS <- 50        # step 5: >= 50 lots with identical value per authority-month
SEED <- 20261109           # seed for every bootstrap (spec, section 4)

# Thresholds drawn as dashed lines in the histograms (spec 9.1)
THRESHOLD_LINES <- c(75000, 139000, 140000, 214000)

# Exact values counted per month (spec 8, data/exact_values_month.csv)
EXACT_VALUES <- c(39900, 39999, 40000, 74900, 74999, 75000, 138000, 138999,
                  139000, 139999, 140000, 149999, 150000)

# Value bands of tables A2, A3 and D3 (lower bound inclusive, upper exclusive)
BANDS <- data.table(
  band  = c("45-70k", "70-75k", "75-125k", "125-134k", "134-139k", "139-140k",
            "140-160k", "160-210k", "210-250k", "250k-1M (ref)"),
  lower = c(45, 70,  75, 125, 134, 139, 140, 160, 210,  250) * 1000,
  upper = c(70, 75, 125, 134, 139, 140, 160, 210, 250, 1000) * 1000
)

# Procedure labels that count as "special procedures" (only used in robustness
# check F8). "È" is the letter "E with grave accent" (written this way so
# that the file works with every text encoding).
SPECIAL_PROC_LABELS <- c(
  "AFFIDAMENTO DIRETTO A SOCIETA' IN HOUSE",
  "AFFIDAMENTO DIRETTO PER VARIANTE SUPERIORE AL 20% DELL'IMPORTO CONTRATTUALE",
  "AFFIDAMENTO DIRETTO PER MODIFICHE CONTRATTUALI O VARIANTI PER LE QUALI È NECESSARIA UNA NUOVA PROCEDURA DI AFFIDAMENTO",
  "AFFIDAMENTO DIRETTO PER LAVORI, SERVIZI O FORNITURE SUPPLEMENTARI",
  "AFFIDAMENTO DIRETTO A SOCIETA' RAGGRUPPATE/CONSORZIATE O CONTROLLATE NELLE CONCESSIONI E NEI PARTENARIATI",
  "AFFIDAMENTO DIRETTO EX ART.5 DELLA LEGGE N.381/91",
  "AFFIDAMENTO RISERVATO"
)
# Mark the labels as UTF-8, like the imported data. Without this, the label
# with the accented letter does not match when R runs in a non-UTF-8 locale
# (e.g. Rscript in a terminal without the LANG variable).
Encoding(SPECIAL_PROC_LABELS) <- "UTF-8"

# ---- Module C: bunching index over time (spec 9.3) ---------------------------------
# Pre-level period of the monthly index (before the EU threshold change 2020)
PRE_PERIOD <- c("2018-01", "2019-12")
# The EU threshold for central authorities became 139k on 2020-01-01. It explains
# a slight rise of S_139 in 2020 (spec section 12); drawn as a thin grey line.
EU_139_DATE  <- as.IDate("2020-01-01")
EU_139_LABEL <- "EU threshold 139k (central authorities)"
# Per threshold: regime in which it applies, plateau months, start of the decay
# (decay_t0) and how the decay is measured ("nls" fit or "descriptive" only).
DYNAMICS_SETUP <- data.table(
  c            = c(75000, 139000, 140000),
  regime       = c("P1b", "P2", "P3"),
  plateau_from = c("2020-10", "2022-01", "2023-08"),
  plateau_to   = c("2021-05", "2023-06", "2023-12"),
  decay_t0     = c("2021-06", "2023-07", NA),
  decay_type   = c("nls", "descriptive", "none")
)
DECAY_END <- "2023-12"   # last month used for the decay (decision P3)
# Variant of S_140 without the lots at exactly this value (Karl, decision K7)
S140_VARIANT_EXCLUDE <- 139000

# ---- Module B: bunching matrix (spec 9.2) -------------------------------------------
# One row per threshold c: estimation window [win_from, win_to) in 1k bins, the
# excluded range [z_L, z_U) around c (in thousand euro relative to c), and an
# additional excluded range [extra_from, extra_to) (only for c = 150k: the area
# of the 139k/140k thresholds). diag_regime = the regime in which c is the
# direct-award threshold (the "diagonal" of the matrix).
BUNCHING_SETUP <- data.table(
  c           = c(75000, 139000, 140000, 150000),
  win_from    = c(45000, 95000, 95000, 100000),
  win_to      = c(125000, 200000, 200000, 210000),
  z_L         = -5,
  z_U         = 5,
  extra_from  = c(NA, NA, NA, 134000),
  extra_to    = c(NA, NA, NA, 141000),
  diag_regime = c("P1b", "P2", "P3", "P1a")
)
BUNCHING_POLY_DEGREE   <- 7                # degree p of the polynomial
BUNCHING_ROUND_DUMMIES <- c(5000, 10000)   # dummies for bins starting at multiples of these
BOOT_REPS <- 200                           # residual bootstrap replications
# Notch variants (spec 9.2; decision K3: no z_U = 40 for 75k). Variants with
# fewer than NOTCH_MIN_BINS_ABOVE fitted bins above the excluded range are fragile.
NOTCH_SETUP <- rbind(data.table(c = 139000, regime = "P2",  z_U = c(5, 10, 20, 40)),
                     data.table(c = 75000,  regime = "P1b", z_U = c(5, 10, 20)))
NOTCH_MIN_BINS_ABOVE <- 15
# Karl, decision K14: the variant 139k/P2 with z_U = 40 is kept in the CSV with
# this note and left out of the table in RESULTS_SUMMARY.md
NOTCH_UNINFORMATIVE_NOTE <- "uninformative (SE of M too large)"
# Plausibility check (Karl, decision K11): excess mass at 139k in P2 reported by
# Kollege 2 (FSS_prelim.pdf, Table 9; other window, dummies and bulk rule)
KOLLEGE2_B_139_P2 <- 10600

# ---- Module D: global shape (spec 9.4) ----------------------------------------------
# D1 regime pairs (numerator a / denominator b)
D1_PAIRS <- data.table(a = c("P1b", "P2", "P2", "P3"), b = c("P0", "P1b", "P0", "P2"))
# Normalisation (ii): all lots 45k-250k outside these two ranges
D1_NORM_II_EXCLUDE <- list(c(65000, 85000), c(125000, 160000))
# Range for the "level" (mean ratio) and the "ramp" (slope of log ratio)
D1_LEVEL_RANGE <- c(75000, 125000)

# D2 piecewise power law: segments [from, to) and regime comparisons (base vs comp)
D2_SEGMENTS <- data.table(segment = c("S1", "S2", "S3"),
                          from = c(45000, 80000, 160000),
                          to   = c(70000, 125000, 210000))
D2_COMPARISONS <- data.table(base = c("P1b", "P0"), comp = "P2")

# D5 relative density index (Karl, decision K8): L = lots in [num_from, num_to)
# divided by lots in [den_from, den_to); all lots incl. round amounts, no bulk.
D5_INDICES <- data.table(index    = c("L139", "L75"),
                         num_from = c(80000, 45000),  num_to = c(125000, 70000),
                         den_from = c(160000, 80000), den_to = c(210000, 125000))
D5_NW_LAG <- 3   # Newey-West lags (months)
# Regime transitions: jumps from the regression and the 6-month comparison
# (last 6 full months before vs first 6 full months after; months with a
# regime switch inside, 2020-07 and 2020-09, are not used)
D5_TRANSITIONS <- data.table(
  transition  = c("P0->P1b", "P1b->P2", "P2->P3"),
  from        = c("P0", "P1b", "P2"),
  to          = c("P1b", "P2", "P3"),
  before_from = c("2020-01", "2020-12", "2023-01"),
  before_to   = c("2020-06", "2021-05", "2023-06"),
  after_from  = c("2020-10", "2021-06", "2023-07"),
  after_to    = c("2021-03", "2021-11", "2023-12")
)

# ---- Module E: heterogeneity (spec 9.5) -----------------------------------------------
# Groups of lots: column of the lot data and its value (compared as text).
# Note: central == TRUE is the same set of lots as macro == "National" (both
# mean sezione_regionale == "SEZIONE REGIONALE CENTRALE").
E_GROUPS <- data.table(
  dimension   = c("Central authority", "Central authority", "Object", "Object",
                  rep("Macro area", 5)),
  group       = c("Central", "Not central", "Services", "Supplies",
                  "North", "Centre", "South", "National", "Unclassified"),
  group_col   = c("central", "central", "object", "object", rep("macro", 5)),
  group_value = c("TRUE", "FALSE", "services", "supplies",
                  "North", "Centre", "South", "National", "Unclassified")
)
# Okabe-Ito colours (as in section 5 below; written out here because this
# section comes first). Central and National are the same lots: same colour.
E_GROUP_COLOURS <- c(Central = "#CC79A7", `Not central` = "#0072B2",
                     Services = "#E69F00", Supplies = "#56B4E9",
                     North = "#0072B2", Centre = "#009E73", South = "#D55E00",
                     National = "#CC79A7", Unclassified = "#7F7F7F")
E_B_REGIMES <- c("P0", "P2")   # b for c = 139k in these regimes (spec 9.5)

# Module E extension (Karl, 2026-11-09; script 08b_E_sectors_regions.R, decisions
# D39, K20, D41): sectors = the E_CPV_TOP_N CPV divisions with the most lots
# 45k-250k (no bulk), regions = the 19 regions and 2 autonomous provinces of
# sezione_regionale. Main measure per group: b(139k, P2) - b(139k, P0). Groups
# with fewer than E_MIN_LOTS_B lots 45k-250k (no bulk, 2018-2023) are described
# only, without b.
E_CPV_TOP_N  <- 10
E_MIN_LOTS_B <- 5000

# CPV divisions (first two digits of cod_cpv): official English names of the
# CPV 2008 (Commission Regulation (EC) No 213/2008, Annex I, division level;
# spelling as in the regulation) and a shorter label for the figures.
# Divisions 03-44 and 48 are supplies, 45 works, 50-98 services (CPV structure).
CPV_DIVISIONS <- data.table(
  cpv2 = c("03", "09", "14", "15", "16", "18", "19", "22", "24", "30", "31", "32",
           "33", "34", "35", "37", "38", "39", "41", "42", "43", "44", "45", "48",
           "50", "51", "55", "60", "63", "64", "65", "66", "70", "71", "72", "73",
           "75", "76", "77", "79", "80", "85", "90", "92", "98"),
  label = c(
    "Agricultural, farming, fishing, forestry and related products",
    "Petroleum products, fuel, electricity and other sources of energy",
    "Mining, basic metals and related products",
    "Food, beverages, tobacco and related products",
    "Agricultural machinery",
    "Clothing, footwear, luggage articles and accessories",
    "Leather and textile fabrics, plastic and rubber materials",
    "Printed matter and related products",
    "Chemical products",
    "Office and computing machinery, equipment and supplies except furniture and software packages",
    "Electrical machinery, apparatus, equipment and consumables; lighting",
    "Radio, television, communication, telecommunication and related equipment",
    "Medical equipments, pharmaceuticals and personal care products",
    "Transport equipment and auxiliary products to transportation",
    "Security, fire-fighting, police and defence equipment",
    "Musical instruments, sport goods, games, toys, handicraft, art materials and accessories",
    "Laboratory, optical and precision equipments (excl. glasses)",
    "Furniture (incl. office furniture), furnishings, domestic appliances (excl. lighting) and cleaning products",
    "Collected and purified water",
    "Industrial machinery",
    "Machinery for mining, quarrying, construction equipment",
    "Construction structures and materials; auxiliary products to construction (except electric apparatus)",
    "Construction work",
    "Software package and information systems",
    "Repair and maintenance services",
    "Installation services (except software)",
    "Hotel, restaurant and retail trade services",
    "Transport services (excl. Waste transport)",
    "Supporting and auxiliary transport services; travel agencies services",
    "Postal and telecommunications services",
    "Public utilities",
    "Financial and insurance services",
    "Real estate services",
    "Architectural, construction, engineering and inspection services",
    "IT services: consulting, software development, Internet and support",
    "Research and development services and related consultancy services",
    "Administration, defence and social security services",
    "Services related to the oil and gas industry",
    "Agricultural, forestry, horticultural, aquacultural and apicultural services",
    "Business services: law, marketing, consulting, recruitment, printing and security",
    "Education and training services",
    "Health and social work services",
    "Sewage, refuse, cleaning and environmental services",
    "Recreational, cultural and sporting services",
    "Other community, social and personal services"),
  label_short = c(
    "Agricultural, fishing, forestry products", "Petroleum products, fuel, energy",
    "Mining, basic metals", "Food, beverages, tobacco", "Agricultural machinery",
    "Clothing, footwear, luggage", "Leather, textiles, plastic, rubber", "Printed matter",
    "Chemical products", "Office and computing machinery, supplies",
    "Electrical machinery; lighting", "Radio, TV, telecom equipment",
    "Medical equipment, pharmaceuticals", "Transport equipment",
    "Security, fire-fighting, defence equipment", "Musical instruments, sport goods, toys",
    "Laboratory, optical, precision equipment", "Furniture, appliances, cleaning products",
    "Collected and purified water", "Industrial machinery",
    "Mining and construction machinery", "Construction structures and materials",
    "Construction work", "Software packages, information systems",
    "Repair and maintenance services", "Installation services",
    "Hotel, restaurant, retail services", "Transport services",
    "Auxiliary transport, travel agencies", "Postal and telecom services", "Public utilities",
    "Financial and insurance services", "Real estate services",
    "Architectural, engineering, inspection services", "IT services",
    "Research and development services", "Administration, defence, social security",
    "Oil and gas industry services", "Agricultural, forestry, horticultural services",
    "Business services (law, consulting, printing)", "Education and training services",
    "Health and social work services", "Sewage, refuse, cleaning services",
    "Recreational, cultural, sporting services", "Other community, social, personal services")
)
CPV_DIVISIONS[, cpv_type := fcase(cpv2 == "45", "Works",
                                  as.integer(cpv2) < 50, "Supplies",
                                  default = "Services")]

# Regions: sezione_regionale without the prefix "SEZIONE REGIONALE ": 19
# regions and the two autonomous provinces Trento and Bolzano, which report
# separately and are kept as separate rows (Karl, decision K20; they are marked
# with E_AUTONOMOUS_NOTE and not interpreted). Central authorities (CENTRALE)
# and "NON CLASSIFICATO" are left out. English names for the figures.
E_REGION_EXCLUDE <- c("CENTRALE", "NON CLASSIFICATO")
E_AUTONOMOUS_NOTE <- "autonomous province, own procurement law"
E_REGIONS <- data.table(
  region = c("ABRUZZO", "BASILICATA", "CALABRIA", "CAMPANIA", "EMILIA ROMAGNA",
             "FRIULI VENEZIA GIULIA", "LAZIO", "LIGURIA", "LOMBARDIA", "MARCHE", "MOLISE",
             "PIEMONTE", "PUGLIA", "SARDEGNA", "SICILIA", "TOSCANA",
             "PROVINCIA AUTONOMA DI TRENTO", "PROVINCIA AUTONOMA DI BOLZANO",
             "UMBRIA", "VALLE D'AOSTA", "VENETO"),
  label  = c("Abruzzo", "Basilicata", "Calabria", "Campania", "Emilia-Romagna",
             "Friuli-Venezia Giulia", "Lazio", "Liguria", "Lombardy", "Marche", "Molise",
             "Piedmont", "Apulia", "Sardinia", "Sicily", "Tuscany",
             "Trento", "Bolzano", "Umbria", "Aosta Valley", "Veneto")
)
E_REGIONS[, unit_type := fifelse(grepl("^PROVINCIA AUTONOMA", region), "autonomous province", "region")]

# ---- Module F: robustness (spec 9.6) ----------------------------------------------------
# Target quantities (spec 9.6, plus the D5 jump of L139 from P1b to P2 in the
# interrupted time series with trend, Karl's decision K15)
F_TARGETS <- data.table(
  target = c("b_139_P2", "b_75_P1b", "b_140_P3", "d1_level_P2_P1b", "half_life_75",
             "d5_L139_P1b_P2"),
  label  = c("b (139k, P2)", "b (75k, P1b)", "b (140k, P3)",
             "D1 mean ratio P2/P1b, 75k-125k", "Half-life of S_75 (months)",
             "D5 jump of L139, P1b to P2 (%)")
)
F7_MONTHS <- 2   # F7: drop the first 2 months after each regime switch
# F10 (Karl, decision K5): replication of Kollege 2, FSS_prelim.pdf, section 3.5
# and Table 9: c = 139k, window 100k-200k, only the 10k dummy, excluded range
# [134k, 144k) (= z in [-5, 5)), P1a and P1b pooled, bulk entries included.
F10_SETUP <- list(c = 139000, window = c(100000, 200000), z_L = -5, z_U = 5,
                  round_dummies = 10000, filters = list(drop_bulk = FALSE),
                  periods = list(P0 = "P0", P1 = c("P1a", "P1b"), P2 = "P2", P3 = "P3"))
KOLLEGE2_TABLE9 <- data.table(
  period         = c("P0", "P1", "P2", "P3"),
  actual         = c(3269, 1527, 15318, 3703),   # lots in [134k, 139k)
  counterfactual = c(3660, 1502, 4704, 1245),
  excess         = c(-391, 25, 10614, 2458),
  b              = c(-0.534, 0.085, 11.283, 9.873)
)
KOLLEGE2_P2_B_SE <- 1.582                  # bootstrap SE of b in P2
KOLLEGE2_P2_B_CI <- c(8.417, 14.607)       # bootstrap percentile interval of b in P2
F10_TOLERANCE_PCT <- 2                     # deviations above 2 % are explained (K5)

# Macro areas, mapping as in Kollege 1 (do-file, part 5). The region name is
# sezione_regionale without the prefix "SEZIONE REGIONALE ".
MACRO_NORTH  <- c("LOMBARDIA", "VENETO", "PIEMONTE", "EMILIA ROMAGNA", "LIGURIA",
                  "FRIULI VENEZIA GIULIA", "VALLE D'AOSTA",
                  "PROVINCIA AUTONOMA DI TRENTO", "PROVINCIA AUTONOMA DI BOLZANO")
MACRO_CENTRE <- c("LAZIO", "TOSCANA", "UMBRIA", "MARCHE")

# ---- 5. Figure style (Karl's bachelor thesis style, decision D42) ------------------
# The theme theme_karl() is in R/functions/fn_plots.R. Colours: Okabe-Ito
# palette (colour-blind safe). Every threshold has one colour, and every regime
# the colour of its threshold (P0 = 40k grey, P1a = 150k sky blue, P1b = 75k
# blue, P2 = 139k vermilion, P3 = 140k bluish green).
FIG_FONT <- "Helvetica"
OKABE_ITO <- c(blue = "#0072B2", vermilion = "#D55E00", bluish_green = "#009E73",
               sky_blue = "#56B4E9", orange = "#E69F00", reddish_purple = "#CC79A7",
               grey = "#7F7F7F", black = "#000000")
THRESHOLD_COLOURS <- c("40k"  = OKABE_ITO[["grey"]],     "75k"  = OKABE_ITO[["blue"]],
                       "139k" = OKABE_ITO[["vermilion"]], "140k" = OKABE_ITO[["bluish_green"]],
                       "150k" = OKABE_ITO[["sky_blue"]])
REGIME_COLOURS <- c(P0 = OKABE_ITO[["grey"]], P1a = OKABE_ITO[["sky_blue"]],
                    P1b = OKABE_ITO[["blue"]], P2 = OKABE_ITO[["vermilion"]],
                    P3 = OKABE_ITO[["bluish_green"]])
# Point shapes for figures with several lines (filled: circle 16, triangle 17,
# square 15, diamond 18; a fifth series gets a cross, 4). SHAPES_OPEN = the
# hollow version of each filled shape (used for "95 % interval includes 1").
SERIES_SHAPES <- c(16, 17, 15, 18, 4)
SHAPES_OPEN   <- c(`16` = 1, `17` = 2, `15` = 0, `18` = 5, `4` = 4)
# Threshold and regime of the same threshold share a shape. 150k / P1a never
# appear as a line, so they get the fifth shape.
THRESHOLD_SHAPES <- c("75k" = 16, "139k" = 17, "140k" = 15, "40k" = 18, "150k" = 4)
REGIME_SHAPES    <- c(P1b = 16, P2 = 17, P3 = 15, P0 = 18, P1a = 4)
# Time series: lines and points, regime switches, shading of P1b (75k regime)
TS_LINEWIDTH  <- 0.9
TS_POINT_SIZE <- 1.6
SHADE_FILL    <- "grey90"   # P1b in time series, released range in D1, excluded range in B2
FIG_WIDTH <- 7   # inches
FIG_DPI   <- 300
# Print versions for the paper (Karl, decision K17): no title or subtitle,
# width 6.5 inches, all text at least 9 points
PAPER_DIR    <- file.path(OUT_DIR, "paper")
PAPER_WIDTH  <- 6.5
PAPER_MIN_PT <- 9

# ---- 6. Helper functions ----------------------------------------------------------
# All reusable functions live in code/functions/ (one file per topic).
for (fn_file in sort(list.files(file.path(CODE_DIR, "functions"),
                                pattern = "\\.R$", full.names = TRUE))) {
  source(fn_file)
}
rm(fn_file)
