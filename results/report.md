# Project D — Main results

Decree-Law 77/2021 raised the limit for direct award of service and supply contracts from €75k to €139k, for procedures started from 1 June 2021.
This file lists the main results by part. The full explanation, with all tables, is in `results/report_pdf/report.pdf`.

- **Main code:** `code/full_analysis_commented.do`, Parts 1–8. Run everything with `code/00_master.do`.
- **Log:** `code/logs/full_analysis_commented_p1b.log`, written when the code runs.
- **Every estimate in one file:** `results/tables/coefficients_p1b.csv`. Columns: table, row, column, b, se, p, N, 95% CI, extra.
- **Design:** difference in discontinuities at €139k, P2 (Jun 2021–Jun 2023) against P1b (Sep 2020–May 2021). Details:
  - local linear regression, triangular kernel, h = €40k;
  - fixed effects for CPV2 × period, region × period and year-month;
  - standard errors clustered by authority;
  - non-PNRR lots only.
- **ITT** = coefficient on below × P2. **LATE** = direct award instrumented by below × P2 (Kleibergen–Paap F ≈ 456).
- All discontinuities read as **below minus above** €139k.
- Section numbers in brackets, e.g. [4.2], refer to the main code.
- Results that are inconclusive, or replaced by a better measure, are listed at the end, not in the main tables.

---

## Data

| | |
|---|---|
| Source | ANAC open data: CIG monthly files, awards (*aggiudicazioni*), winners (*aggiudicatari*), register of authorities |
| Population | services and supplies, ordinary sectors, 2018–2023, framework call-offs dropped: 1,454,116 lots |
| With an award record / with a winner | 622,506 / 622,401 |
| Main window (P1b + P2, non-PNRR, ±€40k) | 96,788 lots; 53,598 awarded; 53,352 with a winner |

| Period | Dates | Direct award below | Role |
|---|---|---|---|
| P0 | before 17 Jul 2020 | €40k | alternative control |
| P1a | 17 Jul – 14 Sep 2020 | EU threshold | excluded |
| **P1b** | 15 Sep 2020 – 31 May 2021 | €75k | **main control** |
| **P2** | 1 Jun 2021 – 30 Jun 2023 | €139k | **treated** |
| P3 | from 1 Jul 2023 | €140k | excluded |

**Legal texts** (checked on Normattiva, copies in `data/raw/law/`):
- **DL 77/2021, art. 51:** direct award for services and supplies "di importo **inferiore a** 139.000 euro", so strictly below €139,000.
  - In force 1 Jun 2021; applies to procedures started after that date (art. 51(3)).
  - Lots at exactly €139,000 are legally not eligible, but 79.5% of them are direct awards in P2. The main specification counts them as eligible; the strict version gives a first stage of 0.276.
- **Rotation principle:** applied below the EU thresholds in both P1b and P2 (art. 36(1) D.Lgs 50/2016). It was also written into the direct-award clause from 31 Jul 2021 (conversion law L. 108/2021). Above €139k, the negotiated procedure rotates invitations instead.
- **New Code (D.Lgs 36/2023):** in force 1 Apr 2023, effective 1 Jul 2023 (art. 229). Art. 50 sets direct award below €140,000; art. 49 bars awarding to the outgoing contractor in the same sector.

---

## Part I. The reform: adoption, lot sizing and the award process (code Parts 1–4, 6)

### I.1 Design checks [2.1–2.3]

| Check | Estimate | Reading |
|---|---|---|
| Jump in direct award at €139k in P1b | +0.009 (0.016) | €139k separated no procedures before the reform (P0: −0.019, under 2 points) |
| Same, central authorities, P1b | −0.077 (0.037) | fewer direct awards just below: possibly a pre-existing EU threshold for central government |
| Award-record coverage, difference in discontinuities vs P1b | +0.033 (p = 0.15) | little selection into the awarded sample |

### I.1b Sorting at the cutoff: balance test [4.10]

After the reform, lots just below €139k are partly a sorted group. The difference in discontinuities does not remove sorting that appears only after the reform. The test applies the main specification, with year-month FE only, to characteristics fixed before the award.

| Characteristic | Diff-in-disc | Without lots at €139,000 | P2 only |
|---|---|---|---|
| Central authority | −0.131 (0.048) | −0.114 | −0.004 (n.s.) |
| South and islands | −0.049 (0.024) | −0.061 | −0.082 |
| Services | +0.123 (0.027) | +0.123 | +0.129 |
| Medical supplies (CPV 33) | −0.105 (0.027) | −0.108 | −0.145 |
| Log lots of the authority, previous year | −0.297 (0.143) | −0.319 | −0.603 |
| Predicted days to award | −5.1 (2.9) | −5.9 | −9.5 |

- **Composition changes at the cutoff after the reform:** more services, fewer medical supplies, fewer southern authorities and smaller authorities.
- **Central authorities:** the change comes from P1b, when they already bunched below €139k. In P2 alone it is zero.
- **Sector and region** are absorbed by the main FE. The predicted-days index (−5.1) is small next to the −52.3 days effect.
- **Authority size** is not absorbed by the main FE, so two robustness rows are reported:
  - a control for authority size, which changes nothing;
  - **authority fixed effects** (a within-authority comparison):
    - first stage 0.315;
    - days −37.1 (7.0), single bid +0.114, price ratio +0.047;
    - the implied effect per switched lot is unchanged (about −118 days).

### I.2 First stage and speed of adoption [4.1, 4.5, 6.1–6.5]

- **First stage:** +0.435 (0.022), t² = 405. It is 0.419–0.439 at h = €20k–60k and 0.432 with P0 as control.
- **Timing:** the jump appears exactly in the first P2 semester and stays flat. There is no jump in any earlier semester.
- **Speed:** 55% of the long-run change happened in June 2021, and about 100% by month 2. The eligible band went from a direct-award share of 0.17 to 0.52 by month 2, then 0.60. The comparison band went from 0.14 to 0.18.
- **Regions and sectors:**
  - Regions differ in how much they adopted (SD of take-up 0.092 against a sampling error of 0.043), not detectably in how fast.
  - Sector explains more than region: R² 0.77 against 0.55.
  - Lowest take-up: medical supplies (CPV 33, 0.16), Sicily (0.12), Molise.
  - Highest: CPV 71/77/60, and Friuli-Venezia Giulia, Veneto, Lombardy (about 0.45).
- **Checks:**
  - fake reform date: −0.004 (0.011);
  - comparison band on its own: +0.015 (0.010);
  - reliability between two halves of the band: r = 0.79.

### I.3 Bunching [3.2–3.6]

| | b̂ | 95% CI |
|---|---|---|
| P2 (level after the reform) | 12.8 | [9.8, 16.1] |
| P1b (level before) | 0.5 | [−0.6, 1.8] |
| **P2 − P1b (effect attributed to the reform)** | **12.3** | **[9.0, 15.6]** |

- Across 8 specifications the difference is 8.3–15.5.
- Heaping: €140,000 fell from 14.4% to 3.9% of nearby lots; €139,000 rose from 3.2% to 11.0%.
- **Where the extra lots come from.** Two separate calculations, with different benchmarks; they should not be added together.
  - **Within P2:** missing mass 5–20k above the cutoff, relative to P2's own fitted curve, equals only 13–24% of the P2 excess.
  - **P2 against P1b,** scaled on lots in 220–300k:
    - +15.7k lots in (130k, 140k];
    - −5.5k lots in (140k, 220k];
    - +24.7k in (80k, 130k];
    - −12.8k in (70k, 80k], where the old €75k pile disappears.
  - "About one-third" is only the rough ratio 5.5k / 15.7k, over a wider window above the cutoff.
  - Both calculations say most extra lots did not come from just above the cutoff. The pattern is consistent with smaller purchases being regrouped into larger lots.
- **By group** (P2 − P1b, with the gap against the reference group):
  - services 14.0 vs supplies 9.8 (gap −4.2 [−9.6, −0.2]);
  - North 14.7, Centre 11.8, **South 8.9** (gap −5.8 [−9.0, −1.9]);
  - companies 16.3 vs public bodies 11.4 (gap +4.9, n.s.);
  - central authorities already bunched in P1b (4.9 [2.9, 8.1]).

### I.4 The award process [4.2–4.4, 4.8]

| Outcome | ITT | LATE | Reading |
|---|---|---|---|
| Days to award | **−52.3 (10.7)** | −119 | faster award |
| ↳ publication → bid deadline | −15.4 (2.8) | −35 | about 30% of the saving |
| ↳ bid deadline → award | −36.8 (10.3) | −84 | about 70% of the saving |
| Award within 90 / 180 days (all lots) | +0.098 (0.022) / +0.082 (0.023) | — | selection-free, agrees |
| Single bid | +0.148 (0.022) | +0.34 | mostly mechanical (87% of direct awards record one bid) |
| Log price ratio | +0.075 (0.030), p = 0.012 | +0.17 | **fragile**: n.s. with a 5k donut, a quadratic, or h = 20k; also jumps at the 160k placebo (−0.086) |
| MEAT criterion | −0.107 (0.027) | −0.26 | selected sample: criterion recorded −0.117 |

### I.5 Robustness and placebos [4.6, 4.7]

- **Days** hold in every row:
  - h = 20k / 60k: −59.1 / −44.6;
  - donuts 1k / 2.5k / 5k: −51.6 / −40.2 / −32.0;
  - quadratic: −55.2;
  - P0 control: −44.2;
  - without central authorities: −51.3;
  - rdrobust: −66.1;
  - value-band DiD: −14.0.
- **Authority fixed effects:** see I.1b. Days −37.1, with the first stage 0.315.
- **Outcome cleaning [4.9], robustness only.** Problems counted among awarded lots in the window:
  - 2,102 (3.9%) award dates before publication;
  - 5,720 (10.7%) awards before the bid deadline;
  - 570 (1.1%) zero-bid lots coded as single bid;
  - 2% of price ratios outside [−1.88, 0.16], the 1st and 99th percentiles.

  Cleaned estimates:
  - days −43.2 (6.6): the split is bid window −15.7, evaluation −31.4;
  - single bid 0.152;
  - price ratio trimmed 0.050 (0.018), winsorized 0.065 (0.020).
- **Placebo cutoffs in P2** (100k, 120k, 160k, 200k): direct award jumps by ≤ 0.035 at each. Days jump at some of them because lots at exact round values are faster. The same pattern exists before and after the reform, so the difference in discontinuities removes it.
- **Value-band event study (days):** pre-reform coefficients are between −8.5 and +8.2, none significant.

**Part I in short:** take-up was immediate and only at €139k. Authorities sized lots to qualify. Awards came about 52 days earlier. The South and medical supplies used the rule least. The price effect is fragile.

---

## Part II. Competition and concentration: who wins (code Part 5)

### II.1 Who wins [5.2–5.3]

| Outcome | ITT | p | LATE | P0 control |
|---|---|---|---|---|
| New to the authority (24m) | **+0.056 (0.025)** | 0.025 | +0.128 | +0.060 |
| New to public procurement, 12m | **+0.045 (0.018)** | 0.011 | +0.103 | +0.031 |
| New to public procurement, 24m | **+0.044 (0.017)** | 0.009 | +0.099 | +0.040 |
| Repeat winner, 24m | −0.042 (0.025) | 0.092 | −0.096 | −0.046 |
| Repeat winner, same CPV3 | −0.043 (0.024) | 0.071 | −0.098 | −0.053 |
| Number of earlier contracts with the authority | −2.02 (0.70) | 0.004 | −4.58 | — |

- **Bandwidths:**
  - new to the authority: +0.065 / +0.063 / +0.048;
  - new to public procurement, 24m: +0.043 / +0.044 / +0.048.
- **Placebos** at €139k in P1b and P0: all |coef| ≤ 0.02, none significant.
- **Authority fixed effects:**
  - new to the authority +0.052 (0.025);
  - new to public procurement +0.041 / +0.035, both p < 0.05;
  - repeat winner −0.038 / −0.038.
- The repeat-winner rows are borderline. They are kept because they rule out the opposite story, that direct award is used to keep the same suppliers.

### II.2 Concentration at the authority level [5.4, 5.4b]

| Outcome (exposure × post) | Estimate |
|---|---|
| HHI by value, all cells | −0.071 (0.026) |
| HHI by count, all cells / cells with 2+ contracts | −0.113 (0.028) / −0.050 (0.019) |
| **S = P(two contracts, same firm)** | **−0.038 (0.018), p = 0.040** |
| Share of firms new to the authority | +0.096 (0.025) |

- Exposed authorities awarded about 25% more lots, which lowers the HHI mechanically. S does not depend on the number of contracts.
- At the mean exposure, S falls by about 0.006, which is 17% of its mean.
- S has no pre-reform gap. The fall is concentrated in the first post-reform semester.

**Part II in short:** eligible contracts go more often to firms new to the authority and new to public procurement. Authorities do not keep their usual suppliers. Concentration falls only slightly once the number of contracts is accounted for.

---

## Part III. Network extension: where do the new winners come from? (code Part 7; build in `code/net_master.do`)

The classes use awards in the previous 24 months (strictly earlier days), within the same CPV2 market, from 2015 onwards. Each winner falls into exactly one class:
- **incumbent:** won the authority's latest award in the lot's CPV3;
- **prior supplier:** won an earlier award from the authority anywhere in the CPV2 market, but is not the incumbent;
- **indirect:** never supplied the authority, but linked to it through another authority that bought from both;
- **outsider:** won awards elsewhere in the market, with no such link;
- **new to the market:** no award in this market in the window.

**Return after a gap** is not a class. It is the subset of prior suppliers whose earlier award from the authority was in the **same CPV3** as the current lot. Control means are 0.296 against 0.319 for prior suppliers, which is why the coefficients differ.

| Outcome | ITT | p | LATE | P0 control |
|---|---|---|---|---|
| **New to the market** | **+0.050 (0.019)** | 0.007 | +0.114 | +0.045 (p < 0.001) |
| Prior supplier (not last winner) | −0.050 (0.021) | 0.018 | −0.114 | −0.055 |
| Incumbent (last winner) | −0.012 (0.014) | 0.38 | −0.027 | −0.022 |
| Return after a gap | −0.036 (0.021) | 0.089 | −0.082 | −0.053 |

- **Authority fixed effects:** new to the market +0.038 (p < 0.05), prior supplier −0.056 (p < 0.01).
- **New to the market** is significant at h = 30k/60k, with donuts, without the €139,000 lots, without multiples of 5k (+0.047), with the network fixed before the reform (+0.058), with CPV3 markets (+0.049), and in the value-band DiD (+0.034). It is weaker at h = 20k (p = 0.09) and with a 12-month window (+0.028, p = 0.14).
- **Placebos:** at €139k in P1b and P0, all p ≥ 0.13. The 120k placebo fails as first estimated (−0.049) because of the lots at exactly €120,000. Without them it is −0.009 (p = 0.55).

**Part III in short:** the new winners are firms new to the market, not firms reached through the authority's network. Former suppliers do not come back more often. This fits an opening of the market, not rotation.

---

## Results not shown in the main tables

| Result | Estimate | Why dropped |
|---|---|---|
| Number of bids | −1.01 (0.42) | replaced by single bid; mechanical |
| Number of firms invited | −61 (38), p = 0.11 | not significant, driven by extreme values |
| S, cells with 5+ contracts | −0.018 (0.016) | not significant (shows S is fragile) |
| Indirect class (Part 7) | +0.026 (0.018) | not significant; sign changes with the control and the controls used |
| Outsider class (Part 7) | −0.014 (0.017) | not significant; same |
| Winner's log degree (Part 7) | −0.135 (0.058) | mechanical (firms new to the market have degree 0) |
| Market-level HHI (5.5) | descriptive | no power (median market has 2 lots/year) |
| Price-ratio event study (4.7) | pre-reform drift | no clean test |

## Open items

- **Strict eligibility:** the statute excludes lots at exactly €139,000. The main specification still counts them as eligible, following observed practice. The strict version stays as a robustness row.
- **Outcome cleaning:** done as robustness only (see I.5); the main specification uses the raw outcomes.
- **Nominal values:** fine for the design, because the cutoff is nominal and the price ratio has no unit. They matter only for the distribution comparison and the value-weighted HHI.
- **Authority register:** a 2026 snapshot with one record per authority and no history of legal type.
- **P0 robustness run** of the whole file: not done.
