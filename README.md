# The Effects of Raising the Direct-Award Threshold on Administrative Efficiency, Concentration, and Supplier Selection: Evidence from Italian Public Procurement

Group project for the course Foundations of Social Sciences (MSc, Bocconi University, 2026).

Decree-Law 77/2021 raised the value below which Italian public authorities may award service and supply contracts directly, without a tender. The limit went from €75,000 to €139,000 for procedures started from 1 June 2021. This repository studies what changed for contracts just below the new threshold:
- how quickly authorities adopted direct award, and where;
- whether they set lot values to fall under €139,000;
- how fast contracts were awarded;
- who won them, and whether supplier concentration changed.

All data are open data from ANAC, the Italian anti-corruption authority.

## Design

The main design is a **difference in discontinuities** at €139,000. Lots just below the cutoff are compared with lots just above it, after the reform (June 2021 – June 2023) and before it (September 2020 – May 2021, when the limit was €75,000). Details:
- local linear regression, triangular kernel, bandwidth €40,000;
- fixed effects for sector × period, region × period and year-month;
- standard errors clustered by contracting authority.

The intention-to-treat effect is the change in the discontinuity. The effect of direct award itself (LATE) is estimated by instrumenting direct award with eligibility × post.

Supporting analyses:
- bunching estimation of lot values;
- monthly adoption curves by region and sector;
- an authority-level panel for supplier concentration;
- a network extension that classifies each winner by its earlier relationship with the authority and the market.

## Main results

| Outcome | Estimate (ITT) | Reading |
|---|---|---|
| Direct award just below €139k | +0.435 (SE 0.022) | Adopted at once: about 55% of the long-run change in the first month |
| Excess mass of lots just below €139k | 12.3 (95% CI 9.0–15.6) | Authorities set lot values to qualify |
| Days from publication to award | −52.3 (10.7); LATE −119 | Faster award: about 30% shorter bid window, 70% faster evaluation |
| Winner new to the authority | +0.056 (0.025) | More contracts go to new suppliers |
| Winner new to public procurement (24 months) | +0.044 (0.017) | |
| Winner new to the market (network measure) | +0.050 (0.019) | Entry, not rotation among known firms |
| Single-bid award | +0.148 (0.022) | Largely mechanical under direct award |
| Log award/base value | +0.075 (0.030) | Fragile across specifications |

Robustness checks, placebos, a balance test of pre-determined characteristics and the results that were set aside are in `report_pdf/report.pdf`. A shorter summary is in `results/report.md`.

## Repository structure

```
code/
  00_master.do                 runs everything: 01_download.do, then the main file
  01_download.do               downloads the ANAC files into data/raw/ (skips files already there)
  full_analysis_commented.do   MAIN CODE, Parts 1–8 (see below)
  net_master.do                network build (Python, called from Part 7 when needed)
  net_py/                      Python scripts of the network build
  net_environment.txt          Python version and packages used for the network build
  logs/                        Stata logs, created when the code runs (not in the repository)
data/                          not included in the repository (see "Data")
results/
  report.md                    main results in Markdown
  tables/                      CSV outputs; coefficients_p1b.csv holds every reported estimate,
                               descriptives_p1b.csv every descriptive number quoted in the text
  tables/tex/                  LaTeX tables written by Part 8
  figures/                     figures
report_pdf/
  report.tex, report.pdf       full report: data, methods, tables, interpretation
```

Parts of `code/full_analysis_commented.do`:

| Part | Content |
|---|---|
| 1 | Data construction from the raw ANAC files (`lots_v2.dta`) |
| 2 | Design checks: discontinuities before the reform, award-record coverage |
| 3 | Bunching of lot values, including by group |
| 4 | Main difference in discontinuities: first stage, award times, bids, price, red flags, robustness, placebos, outcome cleaning, balance test |
| 5 | Who wins and authority-level concentration |
| 6 | Speed of adoption by region and sector |
| 7 | Network extension (runs `net_master.do` if the network measures are missing or out of date) |
| 8 | Export of all estimates and LaTeX tables |

Every section has comments explaining what it does and why, and a RESULTS block with the numbers of the last run.

## Data

The raw and intermediate data (about 16 GB) are not in the repository. All files are public.

**Downloaded by the code:**
- **`code/01_download.do`** downloads, from https://dati.anticorruzione.it/opendata:
  - the monthly CIG files for 2018–2023;
  - the award records (*aggiudicazioni*);
  - the winning firms (*aggiudicatari*).
- **`code/net_py/net_phase0_data.py`**, run through `net_master.do`, downloads:
  - the CIG files for 2015–2017 and 2024;
  - the participants file (*partecipanti*), used for the network histories.

**To download by hand:**
- The register of contracting authorities (*stazioni appaltanti*) from the ANAC portal, saved as `data/raw/stazioni-appaltanti_csv.zip`. The portal rejects scripted requests for this file.

**Documentation only**, in `data/raw/law/` (the code does not read these):
- consolidated texts from Normattiva of DL 76/2020 art. 1, DL 77/2021 art. 51, D.Lgs 50/2016 art. 36 and D.Lgs 36/2023 arts. 49, 50 and 229;
- ANAC's sheet of corruption-risk indicators.

If a download is blocked, the do-file prints the files that failed. Save those files by hand under the same names in `data/raw/`.

## How to run

Requirements:
- **Stata 19** (SE or MP). The required packages (`reghdfe`, `ftools`, `ivreghdfe`, `ivreg2`, `ranktest`, `estout`, `rdrobust`, `rddensity`, `lpdensity` and others) are installed automatically at the top of the main file if missing.
- **Python 3**, linked to Stata, for the network build only:
  - packages `pandas`, `numpy`, `scipy`, `pyreadstat`, `networkx` and `matplotlib`; the versions used are in `code/net_environment.txt`;
  - link it once in Stata with `set python_exec <path to python3>, permanently`.

Steps:
1. Open a terminal in the repository folder. The do-files use the folder Stata is started from as the project root. Alternatively, set `global ROOT "<path to the repository>"` in Stata before running them.
2. From the repository folder, run:
   ```
   stata-se -b do code/00_master.do
   ```
   The first run builds all intermediate data. The main file takes about 15–20 minutes once the data are built. The network build adds about 15 minutes when it has to run.
3. Outputs:
   - the log goes to `code/logs/`;
   - tables and figures go to `results/`.
   - To rebuild the report, compile `report_pdf/report.tex` with `pdflatex`, twice, from inside `report_pdf/`.

Robustness run with the pre-2020 period (P0) as control:
```
global CTRL "P0"
do code/full_analysis_commented.do
```
This run writes files without the `_p1b` suffix.

## Notes

- **Sign convention:** all discontinuities are reported as below minus above €139,000. Estimates from `rdrobust`, which reports above minus below, are reversed.
- **Lots at exactly €139,000:** the statute allows direct award "below" €139,000, but the main specification counts lots at exactly €139,000 as eligible, because 79.5% of them are direct awards after the reform. The strict definition is reported as a robustness check.
- **Specification choices:** listed in the report, in the section on data limitations and specification decisions.
