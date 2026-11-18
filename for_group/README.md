# Distribution of lot values: extra results for the group paper

Karl Wagner, 18 November 2026. Computed in R on the group's sample, rebuilt from the raw ANAC CIG files. It matches the Stata pipeline lot by lot (1,454,116 lots; 140 checks against the group's tables, including all of B3 and B4).

## Folder

```
for_group/
  README.md
  run.R      runs everything (checks, results, figures)
  code/      00_setup.R, 11_group_sample.R, 12_group_results.R, make_extract.R,
             functions/ (7 files)
  data/      lots_group.rds   extract of the group sample (1,454,116 lots, 10 columns)
             sample_flow.csv  lots after each sample rule
             group_tables/    5 tables of the group's Stata pipeline (results/tables/)
  figures/   two figures for the paper, PNG and PDF
  output/    created by run.R (not shipped)
```

## Findings

P1b = 15 Sep 2020 to 31 May 2021 (threshold EUR 75,000). P2 = 1 Jun 2021 to 30 Jun 2023 (threshold EUR 139,000).

| # | Finding | Numbers |
| --- | --- | --- |
| 1 | The old bunching at 75k disappears | b(75k): 8.98 (SE 0.91) in P1b, 0.92 (SE 0.29) in P2 |
| 2 | Lot values adjust within months | 139k: 50% of the jump after 1 month, 90% after 4. 75k: half-life 1.5 months |
| 3 | Level shift, no ramp | density P2/P1b over 75k to 125k: 1.53; slope -0.006 per 10k (p = 0.58) |
| 4 | Strict cutoff (lots at 139,000 counted above) | difference P2 minus P1b: 10.3 (SE 1.4) instead of 12.3 |

Notes:
- The 75k results exclude bulk registrations: at least 50 lots of identical value by one authority in one month. Almost all are 7,255 lots of one authority at exactly EUR 70,000. Without the filter, b(75k) is 12.18 in P1b and 2.87 in P2. At 139k the filter changes nothing.
- Central authorities already bunch below 139k in P1b (share 8.2% vs 2.2% for other authorities), because 139k was their EU threshold from 2020.

## Figures

- `fig_G2a_C2_event_time_bulk_filter_paper`: monthly share of lots in the last EUR 1,000 below the threshold, for 75k and 139k, September 2020 to June 2023.
- `fig_G2b_S1_C2_panel_bulk_filter_paper`: (a) the group's take-up curve S1, (b) the same share as above. Use this one if S1 goes into the paper.

In the code this share is called index S. It needs another name in the paper, because S is already the group's concentration measure.

## How to run

Requirements: R (tested with 4.4.1) and the packages data.table, ggplot2, scales and patchwork (tested with 1.17.8, 3.5.2, 1.4.0 and 1.3.1). Install them with `install.packages(c("data.table", "ggplot2", "scales", "patchwork"))`. Nothing else is needed: no raw data, no group repository.

Copy the folder `for_group` anywhere, open a terminal in it and type:

```
Rscript run.R
```

This takes about 15 seconds. It loads the data extract, checks 140 numbers against the group's tables and stops if one fails, then computes the four results. All results are then in `output/RESULTS_GROUP.md`, with tables in `output/tables/` and figures in `output/figures/`. In RStudio: open `run.R`, choose Session > Set Working Directory > To Source File Location, then click "Source".

Optional: `code/make_extract.R` rebuilds `data/lots_group.rds` and `data/sample_flow.csv` from the raw data and checks the headers and raw text of the 72 files. The raw data are the monthly CIG files 2018 to 2023 from the ANAC open data portal (https://dati.anticorruzione.it/opendata), file names `cig_csv_YYYY_MM.csv`. With the 72 files in one folder, type in `for_group`:

```
Rscript code/make_extract.R /path/to/the/folder/with/the/cig/files
```

This takes about one minute and reports whether the new extract is identical to the shipped one.
