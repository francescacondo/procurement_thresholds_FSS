* ==============================================================================
* PROJECT D — FULL ANALYSIS IN ONE FILE
* Direct-award thresholds in Italian public procurement
*
* Design: Difference-in-discontinuities at the €139,000 cutoff
* Data:   ANAC open data (CIG lots, aggiudicazioni, aggiudicatari), 2018–2023
*
* PREREQUISITE: run 01_download.do first if data/raw/ is empty.
*              That script downloads 72 CIG monthly zips, aggiudicazioni_csv.zip,
*              aggiudicatari_csv.zip, and bandi_cig_tipo_scelta_contraente.csv
*              from https://dati.anticorruzione.it/opendata.
*
* This file is the FINAL pipeline: Part 1–2 data and coverage (R), Part 3
* bunching (B), Part 4 main diff-in-disc (M), Part 5 competition (C), Part 6
* speed of adjustment (S), Part 7 network extension (N; its histories use
* awards from 2015, built by code/net_master.do), Part 8 export of all
* estimates and LaTeX tables for the reports. All results in the reports
* come from this file.
*
* HOW TO RUN: code/00_master.do (download if needed, then this file), or
* directly from the project root: stata-se -b do code/full_analysis_commented.do
* Log: code/logs/full_analysis_commented${SFX}.log.
*
* WHERE EACH PART OF THE REPORT COMES FROM (results/report.md,
* results/report_pdf/report.pdf):
*   I.  Reform, adoption and procurement process: Parts 1–4 and 6
*   II. Competition and concentration (who wins, authority-level HHI): Part 5
*   III. Network extension (where new winners come from): Part 7
*
* CONTROL PERIOD: the main contrast is P1b (15 Sep 2020 – 31 May 2021) vs P2.
* P0 vs P2 is kept as a robustness run.
*   Main run:        do code/full_analysis_commented.do        (CTRL = P1B)
*   Robustness run:  global CTRL "P0"
*                    do code/full_analysis_commented.do
* Outputs of the P1b run carry the suffix _p1b (log, Part 4 figures/tables);
* the P0 run writes the same names without the suffix.
*
* PART 7 (network extension) needs data/intermediate/net_lot_measures.dta,
* built in Python by code/net_master.do (Phases 0–3). Part 7 runs that build
* itself when the file is missing or does not match lots_winners.dta lot by
* lot (after any change to Parts 1 or 5); set global NET_REBUILD 1 to force it.
* ==============================================================================

clear all
set more off
set maxvar 10000

* Project root: the folder Stata is started from (run from the repository
* root, e.g. stata-se -b do code/00_master.do), or set the global ROOT to the
* project folder before calling this file. All paths below are relative to it.
if `"$ROOT"' == "" global ROOT `"`c(pwd)'"'
cd `"$ROOT"'
capture confirm file "code/full_analysis_commented.do"
if _rc {
    di as error `"ROOT = "$ROOT" is not the project folder (no code/full_analysis_commented.do)."'
    di as error "cd to the project root first, or set: global ROOT <path to project root>"
    exit 601
}

* ---- Control-period switch ----
* WHY P1b as main control? P1b is the regime just before P2 and sits under the
* same legal article (art. 1 DL 76/2020, a temporary derogation from the Code);
* only the direct-award threshold differs (€75k in P1b, €139k in P2). Being
* closer in time, it leaves less room for other changes (reporting practice,
* market conditions) between control and treatment period. The cost is a
* smaller sample (0.32 of P0 within ±40k; 1.13), so standard errors are larger.
if "$CTRL" == "" global CTRL "P1B"

* Period groups, used in loops below as ${g_<name>}
global GROUPS "P0 P1a P1b P2 P3"
global g_P0  "period == 0"
global g_P1a "p1a == 1"
global g_P1b "p1b == 1"
global g_P2  "period == 2"
global g_P3  "period == 3"

if "$CTRL" == "P1B" {
    global CTRL_G  "P1b"          // control group name (main)
    global ALT_G   "P0"           // alternative control (robustness)
    global g_CTRL  "p1b == 1"
    global g_ALT   "period == 0"
    global SFX     "_p1b"
    global BAND_LO 75000          // in P1b, lots below 75k were already direct-eligible
    global ES_REF  -1             // event-study reference: Dec 2020 – May 2021 (all P1b)
}
else if "$CTRL" == "P0" {
    global CTRL_G  "P0"
    global ALT_G   "P1b"
    global g_CTRL  "period == 0"
    global g_ALT   "p1b == 1"
    global SFX     ""
    global BAND_LO 40000          // in P0, lots below 40k were already direct-eligible
    global ES_REF  -3             // event-study reference: Dec 2019 – May 2020 (all P0)
}
else {
    di as error "CTRL must be P1B or P0"
    exit 198
}

* ---- Install required packages (skip if already installed) ----
foreach p in reghdfe ftools ppmlhdfe boottest ritest csdid drdid ///
    eventstudyinteract avar sdid ivreg2 ranktest ivreghdfe estout coefplot {
    capture which `p'
    if _rc ssc install `p', replace
}
capture which rdrobust
if _rc {
    net install rdrobust, from("https://raw.githubusercontent.com/rdpackages/rdrobust/master/stata") replace
}
capture which rddensity
if _rc {
    net install rddensity, from("https://raw.githubusercontent.com/rdpackages/rddensity/master/stata") replace
}
capture which lpdensity
if _rc {
    net install lpdensity, from("https://raw.githubusercontent.com/nppackages/lpdensity/master/stata") replace
}


capture mkdir "code/logs"     // logs are not in the repository
log using "code/logs/full_analysis_commented${SFX}.log", replace
di as text "Control period: $CTRL_G (alternative: $ALT_G)"

* ---- Results collector and table writers ------------------------------------
* WHAT: four small programs that write results to files. They change no
* estimate; they only record and format what the code already estimates.
* WHY: every estimate shown in the report (report_pdf/) is written to
* results/tables/coefficients${SFX}.csv as it is computed, and
* Part 8 builds the LaTeX tables from that file (and from the stored
* estimates, with esttab), so no number in the report is copied by hand.
*
* rpost <table> <row> <col> [, options]   one estimate -> one row of the file
*   (default)  reghdfe / ivreghdfe: coefficient 1.below#1.post
*   coef(name) another coefficient (e.g. direct for the LATE)
*   rd         rdrobust: stores BELOW minus ABOVE (= −e(tau_cl)), the same
*              sign as below×post, so every table reads the same way
*   manual     b(#) se(#) [n(#) lo(#) hi(#)]: numbers computed by hand
*              (bootstrap, differences of two rdrobust estimates)
*   extra(#)   one more number (e.g. Kleibergen–Paap F, number of clusters)
* p: t distribution with e(df_r) when the command reports it, else normal.
* lo, hi: 95% CI, b ± 1.96·se unless given (bootstrap percentiles).
capture program drop rpost
program define rpost
    syntax namelist(min=3 max=3) [, Coef(string) RD MANual B(real 0) SE(real 0) ///
        N(real -1) LO(real -999) HI(real -999) Extra(real -999)]
    tokenize `namelist'
    if "`manual'" != "" {
        local bb = `b'
        local ss = `se'
        local nn = cond(`n' < 0, ., `n')
        local pp = 2*normal(-abs(`bb'/`ss'))
    }
    else if "`rd'" != "" {
        local bb = -e(tau_cl)
        local ss = e(se_tau_cl)
        local nn = e(N_h_l) + e(N_h_r)
        local pp = 2*normal(-abs(`bb'/`ss'))
    }
    else {
        if "`coef'" == "" local coef "1.below#1.post"
        local bb = _b[`coef']
        local ss = _se[`coef']
        local nn = e(N)
        if missing(e(df_r)) local pp = 2*normal(-abs(`bb'/`ss'))
        else                local pp = 2*ttail(e(df_r), abs(`bb'/`ss'))
    }
    local ll = cond(`lo' == -999, `bb' - 1.96*`ss', `lo')
    local hh = cond(`hi' == -999, `bb' + 1.96*`ss', `hi')
    local xx = cond(`extra' == -999, ., `extra')
    post RES ("`1'") ("`2'") ("`3'") (`bb') (`ss') (`pp') (`nn') (`ll') (`hh') (`xx')
end

* cstore <name> <outcome>: adds the mean of the outcome among control-period
* lots below 139k in the estimation sample (cmean) and stores the estimates
* under <name> for the esttab tables of Part 8.
capture program drop cstore
program define cstore
    args name var
    quietly summarize `var' if e(sample) & ${g_CTRL} & below == 1, meanonly
    quietly estadd scalar cmean = r(mean)
    estimates store `name'
end

* textab: writes the body of a LaTeX table (rows only; the report file holds
* the header) from the collector data IN MEMORY. One line per row id: the
* label, then for each column id the coefficient with stars, and a second
* line with the SE in parentheses (or the 95% CI in brackets with ci).
*   rows(): row ids; rowlab(): labels, quoted, same order; cols(): column ids
*   fmt(): one display format per row (default %12.3f); cfmt(): one per
*   column instead (used when columns hold outcomes in different units)
*   p-value stars: * < 0.10, ** < 0.05, *** < 0.01
capture program drop textab
program define textab
    syntax using/, Tbl(string) Rows(string) Cols(string) ROWLab(string asis) ///
        [Fmt(string) CFmt(string) CI]
    tempname fh
    file open `fh' using `"`using'"', write replace
    local labs `"`rowlab'"'
    local i 0
    foreach r of local rows {
        local ++i
        gettoken lab labs : labs
        local f : word `i' of `fmt'
        if "`f'" == "" local f "%12.3f"
        local l1 `"`lab'"'
        local l2 ""
        local j 0
        foreach c of local cols {
            local ++j
            if "`cfmt'" != "" local f : word `j' of `cfmt'
            quietly count if tbl == "`tbl'" & row == "`r'" & col == "`c'"
            if r(N) == 0 {
                local l1 `"`l1' & "'
                local l2 `"`l2' & "'
                continue
            }
            quietly summarize b if tbl == "`tbl'" & row == "`r'" & col == "`c'", meanonly
            local bb = r(mean)
            quietly summarize se if tbl == "`tbl'" & row == "`r'" & col == "`c'", meanonly
            local ss = r(mean)
            quietly summarize p if tbl == "`tbl'" & row == "`r'" & col == "`c'", meanonly
            local pp = r(mean)
            local st ""
            if `pp' < 0.10 local st "*"
            if `pp' < 0.05 local st "**"
            if `pp' < 0.01 local st "***"
            local bs : display `f' `bb'
            local bs = strtrim("`bs'")
            local l1 `"`l1' & `bs'`st'"'
            if "`ci'" != "" {
                quietly summarize lo if tbl == "`tbl'" & row == "`r'" & col == "`c'", meanonly
                local a : display `f' r(mean)
                quietly summarize hi if tbl == "`tbl'" & row == "`r'" & col == "`c'", meanonly
                local z : display `f' r(mean)
                local l2 `"`l2' & {\footnotesize [`=strtrim("`a'")', `=strtrim("`z'")']}"'
            }
            else if !missing(`ss') {
                local sd : display `f' `ss'
                local l2 `"`l2' & {\footnotesize (`=strtrim("`sd'")')}"'
            }
            else local l2 `"`l2' & "'
        }
        file write `fh' `"`l1' \\"' _n
        file write `fh' `"`l2' \\[2pt]"' _n
    }
    file close `fh'
end

* tab_main: two-panel esttab table, one column per outcome.
* Panel A: ITT (below×post) with N and the control mean; Panel B: LATE
* (direct award instrumented by below×post) with the Kleibergen–Paap F.
capture program drop tab_main
program define tab_main
    syntax using/, ITT(namelist) IV(namelist) TItles(string asis)
    local k : word count `itt'
    esttab `itt' using `"`using'"', replace booktabs nonumbers ///
        mtitles(`titles') keep(1.below#1.post) ///
        coeflabels(1.below#1.post "Below 139k \texttimes{} P2") ///
        b(a3) se(a3) star(* 0.10 ** 0.05 *** 0.01) ///
        stats(N cmean, labels("Observations" "Control mean below 139k") fmt(%9.0fc a3)) ///
        prehead("\begin{tabular}{l*{`k'}{c}}" "\toprule") ///
        posthead("\midrule" "\multicolumn{`=`k'+1'}{l}{\textit{A. Reduced form (ITT)}}\\") ///
        prefoot("\addlinespace") postfoot("\midrule") nonotes
    esttab `iv' using `"`using'"', append booktabs nonumbers nomtitles ///
        keep(direct) coeflabels(direct "Direct award (LATE)") ///
        b(a3) se(a3) star(* 0.10 ** 0.05 *** 0.01) ///
        stats(widstat, labels("Kleibergen--Paap F") fmt(%9.0f)) ///
        prehead("\multicolumn{`=`k'+1'}{l}{\textit{B. Effect of direct award (LATE)}}\\") ///
        posthead("\addlinespace[1pt]") prefoot("\addlinespace") postfoot("\bottomrule" "\end{tabular}") nonotes
end

* Open the collector (closed and exported in Part 8)
capture postclose RES
postfile RES str24 tbl str32 row str24 col double(b se p N lo hi extra) ///
    using "data/intermediate/_coefficients${SFX}.dta", replace

* dpost <name> <value>: one descriptive number quoted in a comment or in the
* reports (a count, a share, a mean). Written to
* results/tables/descriptives${SFX}.csv in Part 8, so every such number is
* produced by this file.
capture program drop dpost
program define dpost
    args name value
    post DESC ("`name'") (`value')
    di as text "  [descriptive] `name' = " %12.4f `value'
end
capture postclose DESC
postfile DESC str40 name double value ///
    using "data/intermediate/_descriptives${SFX}.dta", replace


* ##############################################################################
* ##############################################################################
* ##                                                                          ##
* ##   PART 1: DATA CONSTRUCTION (Module R)                                   ##
* ##                                                                          ##
* ##   Reads raw ANAC CSVs → builds the main analysis dataset lots_v2.dta     ##
* ##                                                                          ##
* ##############################################################################
* ##############################################################################


* ==============================================================================
* 1.1  IMPORT AND APPEND 72 MONTHLY CIG FILES
* ==============================================================================
* Each CIG file is one month of lot publications from ANAC. A "lot" (CIG) is a
* single procurement contract. The file has ~80 columns; we keep the ones we need.
*
* WHY monthly files? ANAC publishes data in monthly batches. We use 2018–2023
* (72 months = 72 files). 2016–2017 are blocked on the ANAC API.

di as text _n "========================================"
di as text    "  1.1: IMPORTING CIG FILES"
di as text    "========================================"

tempfile combined
local first 1

forvalues y = 2018/2023 {
    forvalues m = 1/12 {
        local mm : display %02.0f `m'
        local csvfile "data/raw/cig_csv_`y'_`mm'.csv"

        capture confirm file "`csvfile'"
        if _rc {
            di as error "  Missing: `csvfile' — skipping"
            continue
        }

        di as text "  Importing `csvfile' ..."

        * Import as all-string to avoid type mismatches across months
        import delimited using "`csvfile'", delimiter(";") stringcols(_all) clear
        rename *, lower

        * Keep relevant columns. The full CIG file has ~80 columns; we only
        * need: identifiers (cig, cig_accordo_quadro), contract descriptors
        * (oggetto_principale_contratto = SERVIZI/FORNITURE/LAVORI, settore,
        * importo_lotto = base value), dates, procedure type, geography,
        * and the ESITO (outcome) columns.
        capture {
            keep cig cig_accordo_quadro oggetto_principale_contratto settore ///
                importo_lotto data_pubblicazione data_scadenza_offerta ///
                cod_tipo_scelta_contraente tipo_scelta_contraente ///
                sezione_regionale cod_cpv codice_ausa ///
                cf_amministrazione_appaltante ///
                denominazione_amministrazione_ap ///
                anno_pubblicazione mese_pubblicazione ///
                stato luogo_istat provincia ///
                durata_prevista n_lotti_componenti ///
                flag_urgenza flag_delega ///
                flag_pnrr_pnc ///
                cod_esito esito data_comunicazione_esito ///
                cod_modalita_realizzazione modalita_realizzazione
        }
        * WHY "denominazione_amministrazione_ap"? The raw column
        * DENOMINAZIONE_AMMINISTRAZIONE_APPALTANTE has 40 characters; Stata
        * truncates variable names to 32, so after import it is called
        * denominazione_amministrazione_ap (the keep below fails, and the log
        * says so, if a header differs).
        * The bid deadline (data_scadenza_offerta -> deadline_date, 1.5) is
        * needed for the deadline-to-award outcomes.
        * Fall back to a minimal set if the full keep fails (should not happen;
        * the log prints "Column mismatch" if it does).
        if _rc {
            di as error "  Column mismatch in `csvfile' — trying minimal set"
            describe, short
            capture {
                keep cig cig_accordo_quadro oggetto_principale_contratto settore ///
                    importo_lotto data_pubblicazione ///
                    cod_tipo_scelta_contraente tipo_scelta_contraente ///
                    sezione_regionale cod_cpv codice_ausa ///
                    cf_amministrazione_appaltante ///
                    anno_pubblicazione mese_pubblicazione ///
                    stato luogo_istat provincia ///
                    flag_urgenza flag_pnrr_pnc ///
                    cod_esito esito data_comunicazione_esito
            }
            if _rc {
                di as error "  Still can't keep required columns — skipping"
                continue
            }
        }

        * Short name for the authority's name. WHY rename? Later Parts merge in
        * the firm name (`denominazione`, 5.1); a distinct name avoids any
        * confusion with Stata's variable-name abbreviations.
        capture rename denominazione_amministrazione_ap authority_name

        * FILTER 1: Keep only SERVICES and SUPPLIES (our population of interest).
        * WHY? The €139k threshold applies specifically to services/supplies.
        * Works (LAVORI) have a different threshold (€150k). Mixing them would
        * contaminate the design.
        keep if inlist(oggetto_principale_contratto, "SERVIZI", "FORNITURE")

        * FILTER 2: Keep only ORDINARY sectors.
        * WHY? Special sectors (utilities: water, energy, transport, postal)
        * have their own EU directives and different thresholds.
        keep if settore == "SETTORI ORDINARI" | settore == "ORDINARI"

        gen int source_year = `y'
        gen byte source_month = `m'

        if `first' {
            save `combined', replace
            local first 0
        }
        else {
            append using `combined'
            save `combined', replace
        }

        di as text "    Kept " _N " cumulative rows"
    }
}

use `combined', clear
di as text _n "  Total CIG rows (services/supplies, ordinary): " _N


* ==============================================================================
* 1.2  CLEAN LOT-LEVEL VARIABLES
* ==============================================================================

di as text _n "========================================"
di as text    "  1.2: CLEANING LOT VARIABLES"
di as text    "========================================"

* ---- Base value (importo_lotto) ----
* This is the authority's estimated contract value BEFORE the tender, excluding
* VAT. It determines which procurement procedure is legally required. It is our
* RUNNING VARIABLE (after centring at €139k).
destring importo_lotto, replace force
label var importo_lotto "Lot base value (EUR, VAT excl.)"
drop if missing(importo_lotto) | importo_lotto <= 0

* ---- Publication date ----
* This is when the CIG was published on ANAC's system. We use it to assign lots
* to regulatory periods (P0, P1, P2, P3) because the applicable rules depend on
* when the procurement was initiated, not when it was awarded.
gen pub_date = date(data_pubblicazione, "YMD")
replace pub_date = date(data_pubblicazione, "DMY") if missing(pub_date)
format pub_date %td
label var pub_date "CIG publication date"
drop if missing(pub_date)

* Restrict to 2018–2023 (our analysis window)
keep if year(pub_date) >= 2018 & year(pub_date) <= 2023

* ---- Cancelled lots: this line drops NOTHING ----
* The line below was meant to drop cancelled/withdrawn lots, but in the CIG
* files stato is "ATTIVO" for every lot (0 rows dropped).
* Cancellation is recorded in the CIG outcome field instead (esito_cig, section
* 1.5: "ANNULLATA ..." codes 2, 6, 7; 16,819 lots, 1.13), and those lots STAY
* in the sample. That is the safer choice for the design: whether a lot gets
* cancelled can itself respond to the reform (it is a post-treatment outcome),
* so dropping cancelled lots would condition the sample on an outcome.
* The line is kept only so the file reproduces lots_v2.dta exactly.
drop if inlist(stato, "Annullato", "ANNULLATO", "Ritirato", "RITIRATO")

* ---- Drop framework-agreement call-offs ----
* WHY? Call-offs under existing framework agreements are not new procurement
* decisions — the supplier was already chosen in the original framework tender.
* Including them would bias the competition outcomes.
drop if cig_accordo_quadro != ""
drop if strpos(lower(tipo_scelta_contraente), "adesione") > 0
drop if strpos(lower(tipo_scelta_contraente), "accordo quadro") > 0
drop if strpos(lower(tipo_scelta_contraente), "convenzione") > 0


* ==============================================================================
* 1.3  DEFINE REGULATORY PERIODS
* ==============================================================================
* The Italian direct-award threshold for services/supplies changed as follows:
*
*   P0  (before 17 Jul 2020):  €40,000   [D.Lgs. 50/2016, art. 36]
*   P1a (17 Jul – 14 Sep 2020): up to the EU threshold [DL 76/2020, original
*       text: "affidamento diretto per lavori, servizi e forniture di importo
*       inferiore a 150.000 euro e, comunque, per servizi e forniture nei limiti
*       delle soglie di cui al citato articolo 35"]. So for services/supplies
*       the direct-award limit was the EU threshold of art. 35, NOT €150,000
*       (€150k was the limit for works). Verified on the Normattiva text in
*       force on 1 Aug 2020 (data/raw/law/DL_76_2020_art1_vigente_2020-08-01.html).
*       L. 120/2020 (conversion, in force 15 Sep 2020) lowered services/supplies
*       to €75,000, so this lasted only ~2 months.
*   P1b (15 Sep 2020 – 31 May 2021): €75,000  [L. 120/2020; verified on the text
*       in force on 1 Oct 2020: direct award below €75k, negotiated procedure
*       with >= 5 operators from €75k to the EU threshold]
*   P2  (1 Jun 2021 – 30 Jun 2023):  €139,000 [DL 77/2021] ← OUR TREATMENT
*   P3  (from 1 Jul 2023):           €140,000 [D.Lgs. 36/2023, new Code]
*
* KEY POINT: €139,000 was not a NATIONAL direct-award threshold before P2. In
* P0 the threshold was €40k (far below), in P1b €75k. So any discontinuity at
* €139k in P0 should be ZERO — this is what makes the difference-in-
* discontinuities design work. P1 is excluded anyway (P1a: limit = EU threshold).
* NOTE: the EU thresholds of art. 35 in 2020-2021 are set by Delegated
* Regulation (EU) 2019/1828. A possible explanation for a pre-reform
* discontinuity for central authorities: if the threshold for CENTRAL
* government authorities was €139,000 from 1 Jan 2020, then €139k separated
* procedure types for central authorities in late P0 and in P1 (and in P1a
* it was their direct-award limit).

gen byte period = .
replace period = 0 if pub_date < date("17jul2020", "DMY")
replace period = 1 if pub_date >= date("17jul2020", "DMY") & pub_date < date("01jun2021", "DMY")
replace period = 2 if pub_date >= date("01jun2021", "DMY") & pub_date < date("01jul2023", "DMY")
replace period = 3 if pub_date >= date("01jul2023", "DMY")

label define period_lbl 0 "P0: pre-reform" 1 "P1: DL76/2020" 2 "P2: DL77/2021" 3 "P3: new Code"
label values period period_lbl
tab period, m

* ---- Split P1 into P1a and P1b ----
* WHY? The main comparison is P1b vs P2. P1 as
* coded above mixes two legal regimes:
*   P1a (17 Jul – 14 Sep 2020): direct award up to the EU threshold
*   P1b (15 Sep 2020 – 31 May 2021): direct award below €75k
* Only P1b is a clean comparison period: €139k separated no national procedure
* types for services/supplies (subject to the note above on the EU
* threshold for central authorities). P1b is also closer in time to P2 than P0,
* so slow-moving trends in procurement practice matter less.
* `period` is left unchanged (codes 0-3) so that Parts 2-5 still run; p1a and
* p1b are new flags. 15 Sep 2020 = entry into force of L. 120/2020 (verified
* on the Normattiva text in force on 1 Oct 2020,
* data/raw/law/DL_76_2020_art1_vigente_2020-10-01.html).
gen byte p1a = (period == 1 & pub_date <  date("15sep2020", "DMY"))
gen byte p1b = (period == 1 & pub_date >= date("15sep2020", "DMY"))
label var p1a "P1a: 17 Jul - 14 Sep 2020 (DL 76/2020, original text)"
label var p1b "P1b: 15 Sep 2020 - 31 May 2021 (L. 120/2020, direct < 75k)"
tab period p1b, m

* ---- Semesters aligned to the reform date ----
* WHY not calendar half-years? Calendar 2021h1 (Jan–Jun 2021) contains June
* 2021, which is already P2, so it mixes control and treatment. rel_sem counts
* 6-month blocks from 1 Jun 2021: rel_sem = 0 is Jun–Nov 2021 (first P2
* semester), rel_sem = -1 is Dec 2020 – May 2021 (entirely P1b), rel_sem = -3
* is Dec 2019 – May 2020 (entirely P0).
gen int rel_sem = floor((mofd(pub_date) - ym(2021, 6)) / 6)
label var rel_sem "Semester relative to 1 Jun 2021 (0 = Jun-Nov 2021)"


* ==============================================================================
* 1.4  CPV CODES, GEOGRAPHY, AND AUTHORITY IDENTIFIERS
* ==============================================================================

* CPV (Common Procurement Vocabulary) classifies what is being procured.
* cod_cpv looks like "33100000-1" (string). We extract the first 2 digits
* as the CPV "division" (e.g. 33 = medical equipment, 72 = IT services).
* This is used as a fixed effect to control for sector-specific trends.
gen cpv2 = substr(cod_cpv, 1, 2)
destring cpv2, replace force
label var cpv2 "CPV division (first 2 digits)"

* Region = ANAC regional section (20 regions). Used as a fixed effect.
gen region = sezione_regionale
label var region "ANAC regional section"

* Central authorities have their own ANAC section ("CENTRALE", 22% of lots; 1.13).
* WHY flag them? For central government the EU threshold may have been €139k
* in 2020-21 (note in section 1.3), so €139k may have separated procedure
* types for them before P2. Part 2 finds a small jump in direct award at 139k
* for central authorities in P1b; Part 4 shows results without them.
gen byte central = (region == "SEZIONE REGIONALE CENTRALE")
label var central "Central authority (ANAC section CENTRALE)"

* Authority ID = the contracting authority's tax code. If missing, fall back
* to the AUSA code. This is our CLUSTERING variable — we cluster SEs at the
* authority level because lots from the same authority are correlated.
gen authority_id = cf_amministrazione_appaltante
replace authority_id = codice_ausa if authority_id == ""

* Parse contract duration (if available)
capture destring durata_prevista, replace force


* ==============================================================================
* 1.5  ESITO (OUTCOME) FROM CIG FILES
* ==============================================================================
* The CIG files contain outcome information:
*   cod_esito_cig = "1" means the lot was AWARDED (AGGIUDICATA)
* This lets us identify awarded lots even when they don't have a match in
* the separate aggiudicazioni file.

rename cod_esito cod_esito_cig
rename esito esito_cig
rename data_comunicazione_esito data_esito_cig
label var cod_esito_cig "Outcome code from CIG file"
label var esito_cig "Outcome text from CIG file"

di as text _n "=== CIG ESITO decomposition ==="
tab esito_cig, m sort

* ---- Bid deadline date ----
capture {
    gen deadline_date = date(data_scadenza_offerta, "YMD")
    replace deadline_date = date(data_scadenza_offerta, "DMY") if missing(deadline_date)
    format deadline_date %td
    label var deadline_date "Bid submission deadline"
}


* ==============================================================================
* 1.6  TREATMENT VARIABLE: DIRECT AWARD
* ==============================================================================
* This is the FIRST STAGE dependent variable. A lot is classified as "direct
* award" if the procedure type field contains "affidamento diretto" (direct
* award) or "affidamento in economia" (simplified procurement, functionally
* equivalent to direct award for our purposes).
*
* WHY text matching? The procedure type is stored as a text string in Italian.
* The code field (cod_tipo_scelta_contraente) has inconsistent coding across
* years. Text matching on the lowercase string is more reliable.

gen byte direct = 0
replace direct = 1 if strpos(lower(tipo_scelta_contraente), "affidamento diretto") > 0
replace direct = 1 if strpos(lower(tipo_scelta_contraente), "affidamento in economia") > 0
label var direct "Direct award (from procedure type)"


* ==============================================================================
* 1.7  RUNNING VARIABLE AND RD SETUP
* ==============================================================================
* The running variable x = lot value − 139,000. A lot with x ≤ 0 is on the
* eligible side (direct award allowed in P2); x > 0 is above.
*
* WHY "≤ 139,000" and not "< 139,000"? In P2, 79.5% of the 2,298 lots at
* EXACTLY €139,000 are direct awards — more than just below (75.7% of lots at
* €134,000–138,999) and far more than just above (23.8% of lots at
* €139,001–144,000) — across 1,009 different authorities (1.13). In practice authorities treat
* €139,000 as eligible, although the DL 77/2021 text says "inferiore a"
* (strictly below). Counting these lots as above put ~2,300 mostly-
* direct lots right at the cutoff on the wrong side, with full kernel weight,
* which pulled every estimate toward zero. Counting them as below gives the
* same estimates as dropping them. below_strict keeps the strict definition
* for robustness (4.6g).

gen float x = importo_lotto - 139000
label var x "Lot value - 139,000"

gen byte below = (importo_lotto <= 139000) if !missing(importo_lotto)
label var below "At or below 139k (eligible side)"

gen byte below_strict = (importo_lotto < 139000) if !missing(importo_lotto)
label var below_strict "Strictly below 139k (robustness)"

* rdrobust puts x >= c on the right (treated) side. To keep lots at exactly
* €139,000 on the LEFT (eligible) side, rdrobust uses xr = x − 0.5 with the
* default cutoff 0: identical ordering, and lots at 139,000 have xr = −0.5.
gen float xr = x - 0.5
label var xr "Lot value - 139,000.5 (running variable for rdrobust)"

gen byte post = (period == 2)
label var post "Post-reform (P2: Jun 2021 - Jun 2023)"


* ---- Save CIG-only dataset (before merging awards) ----
compress
save "data/intermediate/cig_services_supplies_v2.dta", replace
di as text "  Saved cig_services_supplies_v2.dta: " _N " rows"


* ==============================================================================
* 1.8  IMPORT AND PREPARE AGGIUDICAZIONI (AWARD OUTCOMES)
* ==============================================================================
* The aggiudicazioni file contains AWARD-LEVEL information: when the contract
* was awarded, how much the winning bid was, how many firms bid, the rebate, etc.
* It is a SEPARATE file from the CIG file and must be merged on the CIG code.
*
* Not every CIG has an award record — some contracts are still pending, some
* were not reported. This creates the "coverage" issue discussed throughout.

di as text _n "=== Importing aggiudicazioni ==="

import delimited using "data/raw/aggiudicazioni_csv.csv", delimiter(";") ///
    stringcols(_all) clear
rename *, lower
di as text "  Aggiudicazioni imported: " _N " rows"

keep cig data_aggiudicazione_definitiva importo_aggiudicazione ///
    ribasso_aggiudicazione numero_offerte_ammesse ///
    num_imprese_offerenti num_imprese_invitate ///
    cod_esito esito data_comunicazione_esito ///
    flag_proc_accelerata flag_subappalto ///
    id_aggiudicazione criterio_aggiudicazione

* criterio_aggiudicazione = award criterion as text (lowest price vs most
* economically advantageous tender, MEAT); used for the MEAT outcome (4.8).
* Blank for many awards, especially direct awards.
label var criterio_aggiudicazione "Award criterion (text, aggiudicazioni)"

* Rename ESITO columns to avoid clash with CIG's ESITO columns
rename cod_esito cod_esito_agg
rename esito esito_agg
rename data_comunicazione_esito data_esito_agg

* Destring numeric fields
foreach v in importo_aggiudicazione ribasso_aggiudicazione ///
    numero_offerte_ammesse num_imprese_offerenti num_imprese_invitate {
    destring `v', replace force
}

* Parse award date
gen award_date = date(data_aggiudicazione_definitiva, "YMD")
replace award_date = date(data_aggiudicazione_definitiva, "DMY") if missing(award_date)
format award_date %td
label var award_date "Award date"

* Deduplicate: some CIGs have multiple award records (e.g. corrections).
* Keep the most recent one.
gsort cig -award_date -id_aggiudicazione
by cig: keep if _n == 1
di as text "  After dedup: " _N " unique CIG awards"

save "data/intermediate/aggiudicazioni_v2.dta", replace


* ==============================================================================
* 1.9  MERGE CIG + AGGIUDICAZIONI
* ==============================================================================
* This is a 1:1 merge on the CIG code. A lot either has an award record or not.
* has_award = 1 means we have outcome data for this lot.

use "data/intermediate/cig_services_supplies_v2.dta", clear
sort cig
merge 1:1 cig using "data/intermediate/aggiudicazioni_v2.dta", keep(master match) gen(_merge_agg)

gen byte has_award = (_merge_agg == 3)
label var has_award "Has matching award record"
drop _merge_agg


* ==============================================================================
* 1.10  AWARD_ANY: BROADER AWARD DEFINITION
* ==============================================================================
* Combine the aggiudicazioni merge with the CIG's own ESITO field.
* award_any = 1 if the lot has an award record OR the CIG ESITO says "awarded".
* This captures 40,431 additional lots (4.9% of non-matched; 1.13) that are AGGIUDICATA
* per the CIG file but lack an aggiudicazioni record.

gen byte esito_awarded = (cod_esito_cig == "1" | cod_esito_cig == "1.0")
label var esito_awarded "CIG ESITO = AGGIUDICATA"

gen byte award_any = (has_award == 1 | esito_awarded == 1)
label var award_any "Has award record OR ESITO = awarded"

di as text _n "  Coverage comparison:"
tab has_award, m
tab award_any, m
tab has_award esito_awarded, m

di as text _n "  Coverage by period:"
table period, stat(mean has_award) stat(mean award_any) stat(freq) nformat(%5.3f)


* ==============================================================================
* 1.11  CONSTRUCT OUTCOME VARIABLES
* ==============================================================================

* ---- DAYS TO AWARD (speed) ----
* How many days from CIG publication to award. This measures procurement speed.
* Faster = fewer days. We expect direct awards to be faster (no tender process).
gen int days_award = award_date - pub_date if has_award == 1
label var days_award "Days from publication to award"

* ---- REBATE (dropped as primary outcome) ----
* ribasso_aggiudicazione is the percentage discount the winner offered.
* PROBLEM: 61% of direct awards with an award record have rebate = 0 (1.13). This is likely a reporting
* convention (direct awards don't have a formal bidding process, so the "rebate"
* field is left at zero). We keep it but don't use it as a primary outcome.
gen float rebate = ribasso_aggiudicazione if has_award == 1
label var rebate "Award rebate (%)"

* ---- AWARD/BASE RATIO (price) ----
* ratio = award value / base value. A ratio < 1 means savings; > 1 means cost
* overrun. lratio = log of this, which is better behaved for regression.
gen float ratio = importo_aggiudicazione / importo_lotto if has_award == 1 & importo_lotto > 0
label var ratio "Award/base value ratio"

gen float lratio = ln(importo_aggiudicazione / importo_lotto) if has_award == 1 ///
    & importo_aggiudicazione > 0 & importo_lotto > 0
label var lratio "Log(award/base value)"

* Trimmed ratio: exclude extreme outliers (framework-like lots)
gen float ratio_tr = ratio
replace ratio_tr = . if ratio < 0.3 | ratio > 1.5
label var ratio_tr "Award/base ratio, trimmed [0.3, 1.5]"

gen byte framework_like = (ratio > 1.5 | ratio < 0.3) if !missing(ratio)
label var framework_like "Outlier ratio (framework-like)"

* ---- NUMBER OF BIDS (competition) ----
* Primary source: numero_offerte_ammesse (admitted bids). If missing, fall back
* to num_imprese_offerenti (firms that submitted offers).
gen int nbids = numero_offerte_ammesse if has_award == 1
replace nbids = num_imprese_offerenti if missing(nbids) & has_award == 1
label var nbids "Number of bids"

* ---- SINGLE BID (competition proxy) ----
* = 1 if only one firm bid. A key competition indicator: single-bid contracts
* suggest limited competition (the authority may have tailored the spec to one
* supplier, or the market is thin).
gen byte single_bid = (nbids <= 1) if !missing(nbids)
label var single_bid "Single bidder"

* ---- NUMBER OF FIRMS INVITED ----
gen int n_invited = num_imprese_invitate if has_award == 1
label var n_invited "Number of firms invited"


* ==============================================================================
* 1.12  SAVE FINAL DATASET
* ==============================================================================

sort cig
compress
save "data/intermediate/lots_v2.dta", replace
di as text _n "  Saved lots_v2.dta: " _N " rows, " c(k) " variables"

di as text _n "=== Summary statistics (within ±60k of cutoff) ==="
summarize importo_lotto if abs(x) <= 60000, detail
summarize lratio if abs(x) <= 60000 & has_award == 1, detail
summarize days_award if abs(x) <= 60000 & has_award == 1, detail


* ==============================================================================
* 1.13  DESCRIPTIVE FACTS QUOTED IN THE COMMENTS (written by dpost)
* ==============================================================================
di as text _n "=== 1.13: Descriptive facts ==="
* (a) Cancelled lots: CIG outcome codes 2, 6, 7 ("ANNULLATA ..."), kept (1.2)
count if inlist(cod_esito_cig, "2", "2.0", "6", "6.0", "7", "7.0")
dpost n_cancelled `r(N)'
* (b) Share of lots from central authorities (1.4)
summarize central, meanonly
dpost share_central `r(mean)'
* (c) Lots at exactly 139,000 in P2 (1.7, 2.1): number, share direct, share
*     with an award record, number of authorities; direct share among lots
*     just below (134,000–138,999) and just above (139,001–144,000)
count if period == 2 & importo_lotto == 139000
dpost p2_n_at139 `r(N)'
summarize direct if period == 2 & importo_lotto == 139000, meanonly
dpost p2_direct_at139 `r(mean)'
summarize has_award if period == 2 & importo_lotto == 139000, meanonly
dpost p2_coverage_at139 `r(mean)'
summarize direct if period == 2 & importo_lotto >= 134000 & importo_lotto < 139000, meanonly
dpost p2_direct_134_139 `r(mean)'
summarize direct if period == 2 & importo_lotto > 139000 & importo_lotto <= 144000, meanonly
dpost p2_direct_139_144 `r(mean)'
preserve
keep if period == 2 & importo_lotto == 139000
contract authority_id
dpost p2_authorities_at139 `=_N'
restore
* (d) Lots awarded per the CIG outcome field but without an award record (1.10)
count if award_any == 1 & has_award == 0
local n_extra = r(N)
count if has_award == 0
dpost n_awardany_extra `n_extra'
dpost share_awardany_extra_of_unmatched `=`n_extra'/r(N)'
* (e) Direct awards with a recorded rebate of 0 (1.11)
gen byte _reb0 = (rebate == 0) if direct == 1 & has_award == 1 & !missing(rebate)
summarize _reb0, meanonly
dpost share_direct_rebate0 `r(mean)'
drop _reb0
* (f) Lots within ±40k of 139k in P1b and in P0 (control-period choice)
count if p1b == 1 & abs(x) <= 40000
local n1 = r(N)
count if period == 0 & abs(x) <= 40000
dpost n_window_p1b `n1'
dpost n_window_p0 `r(N)'
dpost ratio_window_p1b_p0 `=`n1'/r(N)'


* ##############################################################################
* ##############################################################################
* ##                                                                          ##
* ##   PART 2: COVERAGE DIAGNOSTICS (Module R, continued)                     ##
* ##                                                                          ##
* ##   Checks whether the coverage discontinuity at 139k biases outcomes      ##
* ##                                                                          ##
* ##############################################################################
* ##############################################################################

use "data/intermediate/lots_v2.dta", clear

* ==============================================================================
* 2.1  RD ON COVERAGE AT 139k, BY PERIOD
* ==============================================================================
* WHY? Outcomes (days, price, bids) exist only for lots with an award record.
* If COVERAGE (having an award record) jumps at 139k, outcome regressions on
* awarded lots compare different kinds of lots on the two sides: SELECTION BIAS.
* We test with rdrobust (local linear, h=20k, triangular kernel).
*
* SIGN CONVENTION: rdrobust reports (value just ABOVE 139k) − (value just
* BELOW). A negative coefficient means coverage is HIGHER just below 139k.
*
* WHAT WE NEED: the coverage jump in the control period should be small and
* STABLE over time (the diff-in-disc subtracts it; it need not be exactly zero).
* Read the confidence interval, not only the p-value: a non-significant jump
* with a wide CI does not rule out a sizeable one.
*
* RESULTS (main run, lots at €139,000 counted as eligible):
* P0 +0.022, CI [−0.003, 0.046]; P1b +0.008, CI [−0.034, 0.050];
* P2 −0.070, CI [−0.090, −0.050] (−0.095 without lots at exactly €139k,
* whose award coverage is low: 45.5%; 1.13). In P2 lots just below 139k are more
* often awarded/reported: direct awards finish faster. This is caused by the
* reform, so no choice of control period removes it; outcome estimates on
* awarded lots need a selection check (4.4). Diff-in-disc on coverage:
* +0.033 (p=0.15) vs P1b, +0.049 (p=0.003) vs P0.
* Rows "excl. 139000" drop lots at exactly €139k (mass point, see Part 3).

di as text _n "========================================"
di as text    "  2.1: RD ON COVERAGE AT 139k"
di as text    "========================================"

foreach v in has_award award_any {
    di as text _n "--- `v' ---"
    foreach g of global GROUPS {
        foreach mp in 0 1 {
            local extra ""
            local lab ""
            if `mp' local extra "& importo_lotto != 139000"
            if `mp' local lab " excl. 139000"
            capture rdrobust `v' xr if ${g_`g'} `extra', h(20000) kernel(triangular) masspoints(off)
            if !_rc {
                di as text "  `g'`lab': coef = " %7.4f e(tau_cl) "  SE = " %7.4f e(se_tau_cl) ///
                    "  95% CI [" %7.4f e(tau_cl) - 1.96*e(se_tau_cl) ", " %7.4f e(tau_cl) + 1.96*e(se_tau_cl) "]" ///
                    "  N = " e(N_h_l) + e(N_h_r)
                rpost design cov_`v'`=cond(`mp', "_no139", "")' `g', rd
            }
        }
    }
}


* ==============================================================================
* 2.2  DIFF-IN-DISC ON COVERAGE (control period vs P2)
* ==============================================================================
* Same local-linear diff-in-disc as the main specification (Part 4), with
* coverage as the outcome. A positive below×post coefficient means that, after
* the reform, lots just below 139k became MORE likely to have an award record
* than lots just above, relative to the control period. Both controls shown.

* Create FE group variables (needed by reghdfe)
egen cpv2_post = group(cpv2 post)
egen region_post = group(region post)
gen ym = ym(year(pub_date), month(pub_date))

* Triangular kernel weight, h=40k
gen float kw = max(0, 1 - abs(x)/40000) if abs(x) <= 40000

foreach c in CTRL ALT {
    local cg = cond("`c'" == "CTRL", "$CTRL_G", "$ALT_G")
    di as text _n "--- DiD-RD on coverage (`cg' vs P2, h=40k) ---"
    foreach var in has_award award_any {
        capture reghdfe `var' i.below##i.post##c.x [aw=kw] ///
            if (${g_`c'} | period == 2) & abs(x) <= 40000, ///
            absorb(cpv2_post region_post ym) vce(cluster authority_id)
        if !_rc {
            di as text "  `var': below × post = " %7.4f _b[1.below#1.post] ///
                "  SE = " %7.4f _se[1.below#1.post] ///
                "  p = " %6.4f 2*ttail(e(df_r), abs(_b[1.below#1.post]/_se[1.below#1.post])) ///
                "  N = " e(N)
            rpost design covdid_`var' `c'
        }
    }
}


* ==============================================================================
* 2.3  PLACEBO FIRST STAGE: NO JUMP IN DIRECT AWARD AT 139k BEFORE P2
* ==============================================================================
* WHY? The design assumes €139k separated no procedure types before P2. If the
* direct-award share already jumped at 139k in the control period, the
* diff-in-disc would mix the reform with a pre-existing discontinuity.
*
* RESULTS (main run): P1b overall −0.009, CI [−0.040, 0.022]; but
* central authorities +0.077 (CI [0.005, 0.149], N≈1,900; more direct awards
* ABOVE 139k) and, less clearly, also in P0 (+0.047, CI [0.000, 0.093]) — see
* the note on the EU threshold for central government (section 1.3).
* Non-central P1b: −0.036, CI [−0.072, 0.000]. By semester the jump is small
* and stable from Jun 2018 on (−0.006 to +0.012); only the Jan–May 2018 block is
* positive (+0.066, SE 0.029).

di as text _n "========================================"
di as text    "  2.3: PLACEBO FIRST STAGE AT 139k"
di as text    "========================================"

foreach g in P0 P1a P1b {
    foreach s in all central other {
        local cs ""
        if "`s'" == "central" local cs "& central == 1"
        if "`s'" == "other"   local cs "& central == 0"
        capture rdrobust direct xr if ${g_`g'} `cs', h(20000) kernel(triangular) masspoints(off)
        if !_rc {
            di as text "  `g' `s': coef = " %7.4f e(tau_cl) "  SE = " %7.4f e(se_tau_cl) ///
                "  95% CI [" %7.4f e(tau_cl) - 1.96*e(se_tau_cl) ", " %7.4f e(tau_cl) + 1.96*e(se_tau_cl) "]" ///
                "  N = " e(N_h_l) + e(N_h_r)
            rpost design fsplac_`s' `g', rd
        }
    }
}

* Stability within the pre-reform years, by reform-aligned semester.
* rel_sem = -1 is Dec 2020 – May 2021 (all P1b); rel_sem = -2 (Jun–Nov 2020)
* mixes P0, P1a and P1b, so read it with care.
di as text _n "--- RD on direct at 139k by semester (pre-reform) ---"
forvalues s = -7/-1 {
    capture rdrobust direct xr if rel_sem == `s', h(20000) kernel(triangular) masspoints(off)
    if !_rc {
        di as text "  rel_sem `s': coef = " %7.4f e(tau_cl) "  SE = " %7.4f e(se_tau_cl) ///
            "  N = " e(N_h_l) + e(N_h_r)
    }
}

* Lots published in P1b but awarded after 1 Jun 2021: could P2 rules have
* leaked into them? The procedure is chosen when the lot is started, so it
* should not; we check that the (null) jump holds in both groups.
gen byte awarded_post_jun2021 = (award_date >= date("01jun2021", "DMY")) if has_award == 1
foreach a in 0 1 {
    capture rdrobust direct xr if p1b == 1 & awarded_post_jun2021 == `a', ///
        h(20000) kernel(triangular) masspoints(off)
    if !_rc {
        di as text "  P1b, awarded after 1 Jun 2021 = `a': coef = " %7.4f e(tau_cl) ///
            "  SE = " %7.4f e(se_tau_cl) "  p = " %6.4f 2*normal(-abs(e(tau_cl)/e(se_tau_cl)))
    }
}


* ==============================================================================
* 2.4  FIRST STAGE ON THE REPAIRED DATA (both control periods)
* ==============================================================================
* Quick check that the first stage is similar with either control period.
* The F reported is t² of below×post (the excluded instrument), NOT e(F) of
* reghdfe, which is the joint F of all regressors.
* Outcome regressions are in Part 4.

di as text _n "========================================"
di as text    "  2.4: FIRST STAGE, BOTH CONTROLS"
di as text    "========================================"

foreach c in CTRL ALT {
    local cg = cond("`c'" == "CTRL", "$CTRL_G", "$ALT_G")
    capture reghdfe direct i.below##i.post##c.x [aw=kw] ///
        if (${g_`c'} | period == 2) & abs(x) <= 40000, ///
        absorb(cpv2_post region_post ym) vce(cluster authority_id)
    if !_rc {
        di as text "  `cg' vs P2: below × post = " %7.4f _b[1.below#1.post] ///
            "  SE = " %7.4f _se[1.below#1.post] ///
            "  t² = " %6.1f (_b[1.below#1.post]/_se[1.below#1.post])^2 "  N = " e(N)
    }
}

* Clean up temporary variables from Part 2
drop cpv2_post region_post ym kw awarded_post_jun2021


* ##############################################################################
* ##############################################################################
* ##                                                                          ##
* ##   PART 3: BUNCHING ANALYSIS (Module B)                                   ##
* ##                                                                          ##
* ##   Tests whether authorities strategically set lot values just below 139k ##
* ##                                                                          ##
* ##############################################################################
* ##############################################################################

* ==============================================================================
* 3.1  HISTOGRAMS
* ==============================================================================
* Simple lot-count histograms in €1k bins, €20k–€250k, for each period.
* Vertical lines at €40k (old threshold), €75k (P1b), €139k (P2), €140k (P3).
*
* EXPECTED: Massive spike just below €139k in P2 (strategic lot-value
* manipulation to stay below the direct-award threshold). Nothing at 139k in
* P0 or P1b; in P1b a spike just below €75k (its own direct-award threshold).
* Periods: P0, P1a, P1b, P2, P3 (P1 is split, see section 1.3).

di as text _n "========================================"
di as text    "  3.1: HISTOGRAMS"
di as text    "========================================"

gen bin1k = floor(importo_lotto / 1000) * 1000 + 500 ///
    if importo_lotto >= 20000 & importo_lotto <= 250000

foreach p of global GROUPS {
    preserve
    keep if ${g_`p'} & !missing(bin1k)
    gen byte one = 1
    collapse (sum) n=one, by(bin1k)

    * Export CSV for external plotting
    export delimited using "results/tables/B1_histogram_`p'.csv", replace

    * Stata figure
    twoway bar n bin1k, barwidth(900) color(navy%60) ///
        xline(40000, lcolor(red) lpattern(dash)) ///
        xline(75000, lcolor(orange) lpattern(dash)) ///
        xline(139000, lcolor(cranberry) lpattern(solid) lwidth(medthick)) ///
        xline(140000, lcolor(cranberry) lpattern(dash)) ///
        xline(214000, lcolor(green) lpattern(dash)) ///
        xtitle("Lot value (EUR)") ytitle("Number of lots") ///
        title("Services/supplies lot distribution — `p'") ///
        xlabel(20000 "20k" 40000 "40k" 75000 "75k" 100000 "100k" ///
            139000 "139k" 150000 "150k" 200000 "200k" 250000 "250k") ///
        graphregion(color(white))
    graph export "results/figures/B1_histogram_`p'.png", width(2000) replace
    restore
}


* ==============================================================================
* 3.2  POLYNOMIAL BUNCHING ESTIMATOR AT €139k
* ==============================================================================
* METHOD (Kleven 2016):
* 1. Create €1k bins in a wider window (€100k–€200k).
* 2. Exclude bins in a "manipulation window" around the cutoff, (134k, 144k].
* 3. Fit an order-7 polynomial to the bin counts OUTSIDE the excluded window.
*    This gives a "counterfactual" density: what the distribution would look
*    like without bunching.
* 4. Compare actual vs counterfactual counts in the excluded window at or below 139k.
* 5. "Excess mass" = actual − counterfactual. Normalise by average counterfactual
*    bin count to get b_hat.
*
* b_hat tells us HOW MUCH extra mass there is below the cutoff, relative to
* what we'd expect if authorities didn't manipulate lot values.

di as text _n "========================================"
di as text    "  3.2: BUNCHING ESTIMATOR"
di as text    "========================================"

local cutoff = 139000
local bin_width = 1000
local poly_order = 7
local window_lo = 100000
local window_hi = 200000
local excl_lo = 5000
local excl_hi = 5000

* Bins are (k−1000, k] — right-closed — so that a lot at exactly €139,000 falls
* in the last bin BELOW the cutoff, (138k, 139k], consistent with the "≤ 139k
* is eligible" definition (section 1.7). Round values (e.g. €140,000) then sit
* at the TOP edge of their bin, hence the round-number dummies use bin_bunch + 500.
* The window is (100k, 200k]: with right-closed bins, ">= 100k" would create a
* first "bin" holding only lots at exactly €100,000 (a heap).
gen bin_bunch = ceil(importo_lotto / `bin_width') * `bin_width' - `bin_width'/2 ///
    if importo_lotto > `window_lo' & importo_lotto <= `window_hi'
gen float bin_norm = (bin_bunch - `cutoff') / `bin_width'

foreach p of global GROUPS {
    di as text _n "--- Bunching estimator: Period `p' ---"

    preserve
    keep if ${g_`p'} & !missing(bin_bunch)
    gen byte one = 1
    collapse (sum) count=one, by(bin_bunch bin_norm)

    * Mark the excluded window (±5k around cutoff)
    gen byte excluded = (bin_bunch >= (`cutoff' - `excl_lo') & bin_bunch < (`cutoff' + `excl_hi'))

    * Generate polynomial terms
    forvalues j = 2/7 {
        gen float bin_norm`j' = bin_norm^`j'
    }

    * Round-number dummies (Chetty et al. 2011): multiples of 10k, and of 5k
    * that are not multiples of 10k. WHY the 5k dummy? Lots heap at €105k,
    * €115k, … and the €135k heap sits inside the excluded window just below
    * the cutoff; without the dummy it is counted as bunching.
    gen byte round10k = (mod(bin_bunch + 500, 10000) == 0)
    gen byte round5k  = (mod(bin_bunch + 500, 5000) == 0) & !round10k

    * Fit polynomial on bins OUTSIDE the excluded window, with round-number dummies
    reg count bin_norm bin_norm2 bin_norm3 bin_norm4 bin_norm5 ///
        bin_norm6 bin_norm7 round10k round5k if excluded == 0
    predict counterfactual

    * Excess mass below cutoff
    summarize count if bin_bunch >= (`cutoff' - `excl_lo') & bin_bunch < `cutoff'
    local actual_below = r(sum)
    summarize counterfactual if bin_bunch >= (`cutoff' - `excl_lo') & bin_bunch < `cutoff'
    local cf_below = r(sum)

    * Normalise by avg counterfactual at threshold (Kleven 2016 standard)
    summarize counterfactual if bin_bunch >= (`cutoff' - `excl_lo') & bin_bunch < `cutoff'
    local avg_cf_threshold = r(mean)

    * Missing mass above cutoff
    summarize count if bin_bunch >= `cutoff' & bin_bunch < (`cutoff' + `excl_hi')
    local actual_above = r(sum)
    summarize counterfactual if bin_bunch >= `cutoff' & bin_bunch < (`cutoff' + `excl_hi')
    local cf_above = r(sum)
    local missing_above = `cf_above' - `actual_above'

    local excess_mass = `actual_below' - `cf_below'
    local b_hat = `excess_mass' / `avg_cf_threshold'

    di as text "  Actual below (excl window): " %10.0f `actual_below'
    di as text "  Counterfactual below:       " %10.0f `cf_below'
    di as text "  Excess mass:                " %10.0f `excess_mass'
    di as text "  Missing mass above:         " %10.0f `missing_above'
    di as text "  Avg cf at threshold:        " %10.0f `avg_cf_threshold'
    di as text "  >>> b_hat (`p'):           " %10.3f `b_hat'

    * Store b_hat for the P2 − control difference (3.4)
    local b_hat_`p' = `b_hat'

    * Export and plot
    export delimited using "results/tables/B2_bunching_`p'.csv", replace

    twoway (bar count bin_bunch if excluded == 0, barwidth(900) color(navy%60)) ///
        (bar count bin_bunch if excluded == 1, barwidth(900) color(cranberry%60)) ///
        (line counterfactual bin_bunch, lcolor(red) lwidth(medthick) lpattern(dash)), ///
        xline(`cutoff', lcolor(black) lpattern(solid)) ///
        legend(order(1 "Outside window" 2 "Excluded window" 3 "Counterfactual") ///
            rows(1) position(6)) ///
        xtitle("Lot value (EUR)") ytitle("Number of lots per 1k bin") ///
        title("Bunching at 139k — `p'") ///
        graphregion(color(white))
    graph export "results/figures/B2_bunching_`p'.png", width(2000) replace

    restore
}


* ==============================================================================
* 3.3  BOOTSTRAP: P2, CONTROL PERIOD, AND THEIR DIFFERENCE
* ==============================================================================
* WHY bootstrap? The bunching estimator is nonlinear (polynomial + bin counts),
* so we can't get analytical SEs easily. We use residual resampling:
* resample the polynomial residuals, add them to the fitted values, re-estimate.
* 200 replications per period.
*
* WHY also the control period? The headline is the DIFFERENCE b_hat(P2) −
* b_hat(control): bunching at 139k created by the reform, net of any heaping
* at 139k that existed anyway. P2 and the control period are different lots,
* so their bootstrap draws are independent; replication r of the difference is
* draw r of P2 minus draw r of the control. P2 is bootstrapped first with the
* same seed as before, so its draws reproduce the earlier P2-only results.

di as text _n "--- Bootstrap: P2 and $CTRL_G bunching ---"

save "data/intermediate/_lots_temp.dta", replace

local B = 200
tempname ph
postfile `ph' str4 grp int rep float b_rep using "data/intermediate/_boot_b.dta", replace
set seed 20261104

foreach g in P2 $CTRL_G {
    use "data/intermediate/_lots_temp.dta", clear
    keep if ${g_`g'} & !missing(bin_bunch)
    gen byte one = 1
    collapse (sum) count=one, by(bin_bunch bin_norm)

    gen byte excluded = (bin_bunch >= (`cutoff' - `excl_lo') & bin_bunch < (`cutoff' + `excl_hi'))
    forvalues j = 2/7 {
        gen float bin_norm`j' = bin_norm^`j'
    }

    * Round-number dummies (as in 3.2)
    gen byte round10k = (mod(bin_bunch + 500, 10000) == 0)
    gen byte round5k  = (mod(bin_bunch + 500, 5000) == 0) & !round10k

    reg count bin_norm bin_norm2 bin_norm3 bin_norm4 bin_norm5 ///
        bin_norm6 bin_norm7 round10k round5k if excluded == 0
    predict resid, residuals
    predict fitted

    * Sort so excluded==0 rows come first (for clean bootstrap draws)
    sort excluded bin_bunch
    count if excluded == 0
    local n_fit = r(N)

    forvalues b = 1/`B' {
        quietly {
            * Resample residuals from NON-EXCLUDED rows only
            gen float resid_boot = resid
            replace resid_boot = resid[ceil(runiform() * `n_fit')] if excluded == 0
            gen float count_boot = fitted + resid_boot
            replace count_boot = count if excluded == 1
            replace count_boot = max(0, count_boot)

            reg count_boot bin_norm bin_norm2 bin_norm3 bin_norm4 bin_norm5 ///
                bin_norm6 bin_norm7 round10k round5k if excluded == 0
            predict cf_boot

            summarize count_boot if bin_bunch >= (`cutoff' - `excl_lo') & bin_bunch < `cutoff'
            local actual_b = r(sum)
            summarize cf_boot if bin_bunch >= (`cutoff' - `excl_lo') & bin_bunch < `cutoff'
            local cf_b = r(sum)
            * Normalise by avg counterfactual at threshold
            local avg_cf_b = r(mean)
            local b_rep = (`actual_b' - `cf_b') / `avg_cf_b'

            post `ph' ("`g'") (`b') (`b_rep')
            drop resid_boot count_boot cf_boot
        }
    }
}
postclose `ph'

use "data/intermediate/_boot_b.dta", clear
foreach g in P2 $CTRL_G {
    quietly summarize b_rep if grp == "`g'"
    di as text "  `g': bootstrap SE of b_hat = " %6.3f r(sd) "  mean = " %6.3f r(mean)
    * Percentile CIs (not normal approximation)
    local bsd = r(sd)
    _pctile b_rep if grp == "`g'", percentiles(2.5 97.5)
    di as text "      95% CI (percentile): [" %6.3f r(r1) ", " %6.3f r(r2) "]"
    rpost bunch main `g', manual b(`b_hat_`g'') se(`bsd') lo(`r(r1)') hi(`r(r2)')
}
reshape wide b_rep, i(rep) j(grp) string
gen float b_diff = b_repP2 - b_rep${CTRL_G}
quietly summarize b_diff
di as text "  P2 − $CTRL_G: bootstrap SE of difference = " %6.3f r(sd)
local bsd = r(sd)
_pctile b_diff, percentiles(2.5 97.5)
di as text "      95% CI (percentile): [" %6.3f r(r1) ", " %6.3f r(r2) "]"
rpost bunch main diff, manual b(`=`b_hat_P2' - `b_hat_${CTRL_G}'') se(`bsd') lo(`r(r1)') hi(`r(r2)')
erase "data/intermediate/_boot_b.dta"

use "data/intermediate/_lots_temp.dta", clear
erase "data/intermediate/_lots_temp.dta"


* ==============================================================================
* 3.4  ROUND-NUMBER HEAPING
* ==============================================================================
* Check how many lots are priced at EXACTLY €139,000 (the threshold), €139,999
* (just under), and €140,000 (just above). In P0 the round-number heaping point
* should be €140k; in P2 it should shift to €139k.

di as text _n "========================================"
di as text    "  3.4: ROUND-NUMBER HEAPING"
di as text    "========================================"

foreach p of global GROUPS {
    di as text _n "  Period `p':"
    count if importo_lotto == 139000 & ${g_`p'}
    local n139 = r(N)
    count if importo_lotto == 139999 & ${g_`p'}
    local n139999 = r(N)
    count if importo_lotto == 140000 & ${g_`p'}
    local n140 = r(N)
    count if abs(x) <= 5000 & ${g_`p'}
    local ntot = r(N)

    di as text "    €139,000 exact: " %8.0f `n139' " (" %5.2f 100*`n139'/`ntot' "%)"
    di as text "    €139,999 exact: " %8.0f `n139999' " (" %5.2f 100*`n139999'/`ntot' "%)"
    di as text "    €140,000 exact: " %8.0f `n140' " (" %5.2f 100*`n140'/`ntot' "%)"
}

di as text _n ">>> Bunching difference (P2 - $CTRL_G): " %10.3f `b_hat_P2' - `b_hat_${CTRL_G}'
di as text    ">>> Bunching difference (P2 - $ALT_G):  " %10.3f `b_hat_P2' - `b_hat_${ALT_G}'
di as text    "    (bootstrap CI of the main difference: section 3.3)"


* ==============================================================================
* 3.5  SENSITIVITY, MISSING MASS, AND WHERE THE BUNCHED LOTS COME FROM
* ==============================================================================
* (a) SPECIFICATION GRID. b_hat depends on choices with no single right answer
*     (polynomial order, width of the excluded window, round-number dummies).
*     The bootstrap CI (3.3) covers only fitting noise for ONE choice, so we
*     report b_hat across a grid, for P2 and both control periods.
* (b) MISSING MASS. If bunchers only shaded their value down from just above
*     139k, the excess below the cutoff should equal the missing mass above it
*     (the "integration constraint"). We report how much of the P2 excess is
*     matched by missing mass within 5k, 10k and 20k above the cutoff.
* (c) WHOLE-DISTRIBUTION COMPARISON. Lots per €10k band, P2 vs the control
*     period, each scaled by its own count in (220k, 300k] — a range the 139k
*     reform should not move. Ratio > 1 = relatively more lots in P2.
*     This shows where the extra lots below 139k come from: from above 139k
*     (shading down), or from below (e.g. purchases that in P1b were kept
*     under €75k and can now be one lot up to €139k).
*
* RESULTS (main run, control P1b; main spec with 5k dummies):
*   b_hat P2 12.8 [9.8, 16.1], P1b 0.50 [−0.55, 1.80], P2 − P1b 12.3
*   [9.0, 15.6]. (a) Across the grid P2 − P1b ranges 8.3–15.6; the narrow
*   window below (3k) gives the low end, wide windows make P1b/P0 unstable.
*   (b) Only 13–24% of the P2 excess is matched by missing mass within
*   5–20k above the cutoff: most bunched lots did NOT come from just above.
*   (c) Relative to P1b, P2 has +15.7k lots in (130k,140k], −5.5k in
*   (140k,220k], +24.7k in (80k,130k] and −12.8k in (70k,80k] (P1b's own
*   bunching at €75k dissolves). The reform reshaped the whole distribution:
*   shading down from above explains about a third of the pile at 139k, the
*   rest is mass moving up from below / new lots. So b_hat measures the SIZE
*   of the local pile; the usual reading "bunchers came from up to b_hat×€1k
*   above the cutoff" does not apply. Caveat: (c) assumes the reform did not
*   change lots above €220k, and values are nominal (2022 inflation shifts
*   lots upward, against the observed pattern).

di as text _n "========================================"
di as text    "  3.5: SENSITIVITY AND MISSING MASS"
di as text    "========================================"

preserve
keep if (${g_CTRL} | ${g_ALT} | period == 2) & importo_lotto > 40000 & importo_lotto <= 300000
gen str4 grp = cond(period == 2, "P2", cond(${g_CTRL}, "$CTRL_G", "$ALT_G"))
gen bin = ceil(importo_lotto / 1000) * 1000 - 500
gen byte one = 1
collapse (sum) n = one, by(grp bin)
tempfile bins
save `bins'

capture program drop bunch_spec
program define bunch_spec, rclass
    * args: bins file, group, poly order, excl. window below, above, round-5k dummies (0/1)
    args file g K el eh r5
    use "`file'", clear
    keep if grp == "`g'" & bin > 100000 & bin < 200000
    gen float z = (bin - 139000) / 1000
    forvalues j = 1/`K' {
        gen double z`j' = z^`j'
    }
    gen byte r10 = mod(bin + 500, 10000) == 0
    gen byte r5  = mod(bin + 500, 5000) == 0 & !r10
    gen byte ex  = bin > 139000 - `el' & bin < 139000 + `eh'
    local rr "r10"
    if `r5' local rr "r10 r5"
    quietly regress n z1-z`K' `rr' if !ex
    predict double cf
    quietly summarize n if ex & bin < 139000
    local a = r(sum)
    quietly summarize cf if ex & bin < 139000
    local c = r(sum)
    local m = r(mean)
    quietly summarize n if ex & bin > 139000
    local aa = r(sum)
    quietly summarize cf if ex & bin > 139000
    return scalar missing = r(sum) - `aa'
    return scalar excess  = `a' - `c'
    return scalar b       = (`a' - `c') / `m'
end

* (a)+(b) Specification grid
tempfile grid
tempname gp
postfile `gp' int spec str40 label str4 grp b excess missing using `grid'
local s1 "main: poly 7, excl 5k/5k, 10k+5k dummies"
local s2 "poly 5"
local s3 "poly 9"
local s4 "excl. below 3k"
local s5 "excl. below 10k"
local s6 "excl. above 10k"
local s7 "excl. above 20k"
local s8 "no 5k dummies"
foreach g in P2 $CTRL_G $ALT_G {
    forvalues k = 1/8 {
        local K = cond(`k' == 2, 5, cond(`k' == 3, 9, 7))
        local el = cond(`k' == 4, 3000, cond(`k' == 5, 10000, 5000))
        local eh = cond(`k' == 6, 10000, cond(`k' == 7, 20000, 5000))
        local r5 = (`k' != 8)
        quietly bunch_spec "`bins'" `g' `K' `el' `eh' `r5'
        post `gp' (`k') ("`s`k''") ("`g'") (r(b)) (r(excess)) (r(missing))
    }
}
postclose `gp'

use `grid', clear
format b %6.2f
format excess missing %8.0f
reshape wide b excess missing, i(spec label) j(grp) string
gen float b_diff = bP2 - b${CTRL_G}
format b_diff %6.2f
di as text _n "  (a) b_hat by specification (P2, $CTRL_G, $ALT_G; diff = P2 − $CTRL_G):"
list label bP2 b${CTRL_G} b${ALT_G} b_diff, noobs clean abbreviate(12)
quietly summarize b_diff
di as text "      Range of P2 − $CTRL_G across specifications: " %5.2f r(min) " to " %5.2f r(max)
di as text _n "  (b) P2 excess vs missing mass above the cutoff:"
foreach k in 1 6 7 {
    quietly summarize excessP2 if spec == `k'
    local ex = r(mean)
    quietly summarize missingP2 if spec == `k'
    local w = cond(`k' == 1, "5k", cond(`k' == 6, "10k", "20k"))
    di as text "      within `w' above: excess " %7.0f `ex' ", missing " %7.0f r(mean) ///
        "  → matched share " %4.2f r(mean)/`ex'
}
export delimited using "results/tables/B3_bunching_sensitivity${SFX}.csv", replace

* (c) Whole-distribution comparison by €10k band
use `bins', clear
keep if inlist(grp, "P2", "$CTRL_G")
gen int band10 = (ceil((bin + 500) / 10000) - 1) * 10
label var band10 "Band (k EUR): (band10, band10 + 10]"
collapse (sum) n, by(grp band10)
bysort grp: egen ref = total(n * (band10 >= 220))
gen float rel = n / ref
replace grp = "C" if grp != "P2"
reshape wide n ref rel, i(band10) j(grp) string
gen float ratio = relP2 / relC
* implied lots in P2 relative to the control-period shape
gen float extra_lots = (relP2 - relC) * refP2
format relC relP2 ratio %6.3f
format extra_lots %8.0f
di as text _n "  (c) Lots per €10k band, scaled by each period's count in (220k, 300k];"
di as text    "      C = $CTRL_G, ratio = P2 / C, extra_lots = P2 lots above the C shape:"
list band10 nC nP2 relC relP2 ratio extra_lots, noobs clean
quietly summarize extra_lots if band10 == 130
local ex130 = r(sum)
quietly summarize extra_lots if inrange(band10, 140, 210)
local def_above = r(sum)
quietly summarize extra_lots if inrange(band10, 80, 120)
local ex_mid = r(sum)
quietly summarize extra_lots if band10 == 70
di as text _n "      Extra P2 lots in (130k,140k]: " %7.0f `ex130' ///
    ";  change (140k,220k]: " %7.0f `def_above' ///
    ";  change (80k,130k]: " %7.0f `ex_mid' ";  change (70k,80k]: " %7.0f r(sum)
export delimited using "results/tables/B4_band_ratios${SFX}.csv", replace
restore

drop bin1k bin_bunch bin_norm


* ==============================================================================
* 3.6  WHO BUNCHES? BUNCHING AT €139k BY GROUP
* ==============================================================================
* WHY? 3.2–3.3 give one b_hat for all lots. If some kinds of authority or
* contract pile up below €139k much more than others, that says who uses the
* room the reform created.
*
* GROUPINGS (each lot belongs to one level of each):
* - contract: services vs supplies (oggetto_principale_contratto);
* - central: central authorities (ANAC section CENTRALE) vs all others;
* - macro: North / Centre / South and islands (ISTAT macro areas, from the
*   ANAC regional section; central authorities and "NON CLASSIFICATO" are left
*   out of this grouping, they have no region);
* - auth: legal type from ANAC's register of contracting authorities
*   (data/raw/stazioni-appaltanti_csv.zip, downloaded by hand because the
*   portal rejects scripted requests; one row per tax code; a current
*   snapshot, so the legal type is today's, not 2020–23's):
*     Public  = natura giuridica 55 amministrazioni pubbliche, 15 enti
*               pubblici non economici, 14 enti pubblici economici, 18 enti
*               ospedalieri;
*     Company = any "società" (SpA, Srl, cooperatives, consortium companies);
*     Other   = everything else (foundations, consortia, associations,
*               local-government agencies (code 21), not classified, …).
*   WHY only 3 groups? The legal-type code is a legal FORM, not a kind of
*   authority: lots of municipalities are registered under code 15 (70%) or
*   55 (22%), and lots of health bodies under 15 (42%) or other codes
*   (computed below), so finer groups would mostly reflect how an authority
*   registered.
*
* ESTIMATOR: the 3.2 estimator on each period × group cell (bins (k−1000, k]
* in (100k, 200k], order-7 polynomial, excluded window (134k, 144k], round
* 10k / 5k dummies, b_hat = excess mass below 139k / mean counterfactual
* bin count, so it is comparable across groups of different size), and the
* 3.3 residual bootstrap (200 draws per cell). Population as in 3.2 (all
* lots of the period, PNRR included). One change needed for small groups:
* bins with no lots are kept as zeros (3.2 never has empty bins).
* REPORTED per group: b_hat in P2 and in $CTRL_G, the difference with a
* percentile CI, and the gap in that difference relative to a reference
* level (Services, Other authorities, North, Public), with a percentile CI
* (cells are disjoint sets of lots, so their draws are independent).

di as text _n "========================================"
di as text    "  3.6: BUNCHING BY GROUP"
di as text    "========================================"

capture program drop bunch_grp
program define bunch_grp, rclass
    * args: postfile handle, grouping, level, period, bootstrap draws
    * Data in memory: the lots of one period × group cell.
    args ph grouping level per B
    gen double bin = ceil(importo_lotto / 1000) * 1000 - 500
    quietly keep if bin > 100000 & bin < 200000
    local nl = _N
    gen byte one = 1
    collapse (sum) n = one, by(bin)
    * Keep all 100 bins, with zero lots where a bin is empty
    tempfile have
    quietly save `have'
    clear
    quietly set obs 100
    gen double bin = 100000 + _n * 1000 - 500
    quietly merge 1:1 bin using `have', nogen
    quietly replace n = 0 if missing(n)
    gen double z = (bin - 139000) / 1000
    forvalues j = 2/7 {
        gen double z`j' = z^`j'
    }
    gen byte r10 = mod(bin + 500, 10000) == 0
    gen byte r5  = mod(bin + 500, 5000) == 0 & !r10
    gen byte ex  = bin > 134000 & bin < 144000
    quietly regress n z z2-z7 r10 r5 if !ex
    quietly predict double cf
    quietly predict double res, residuals
    quietly summarize n if ex & bin < 139000
    local a = r(sum)
    quietly summarize cf if ex & bin < 139000
    local b_hat = (`a' - r(sum)) / r(mean)
    * Residual bootstrap, as in 3.3 (fit rows first, resample their residuals)
    sort ex bin
    quietly count if !ex
    local nf = r(N)
    forvalues r = 1/`B' {
        quietly {
            gen double nb = cf + res[ceil(runiform() * `nf')] if !ex
            replace nb = n if ex
            replace nb = max(0, nb)
            regress nb z z2-z7 r10 r5 if !ex
            predict double cfb
            summarize nb if ex & bin < 139000
            local ab = r(sum)
            summarize cfb if ex & bin < 139000
            post `ph' ("`grouping'") ("`level'") ("`per'") (`r') ((`ab' - r(sum)) / r(mean))
            drop nb cfb
        }
    }
    return scalar b = `b_hat'
    return scalar n_lots = `nl'
end

* ---- Grouping variables ----
gen str8 g_contract = cond(oggetto_principale_contratto == "SERVIZI", "Services", "Supplies")
gen str8 g_central  = cond(central == 1, "Central", "Other")

gen regname = subinstr(region, "SEZIONE REGIONALE ", "", .)
gen str8 g_macro = ""
replace g_macro = "North" if inlist(regname, "PIEMONTE", "VALLE D'AOSTA", "LOMBARDIA", ///
    "LIGURIA", "VENETO", "FRIULI VENEZIA GIULIA", "EMILIA ROMAGNA") ///
    | inlist(regname, "PROVINCIA AUTONOMA DI TRENTO", "PROVINCIA AUTONOMA DI BOLZANO")
replace g_macro = "Centre" if inlist(regname, "TOSCANA", "UMBRIA", "MARCHE", "LAZIO")
replace g_macro = "South" if inlist(regname, "ABRUZZO", "MOLISE", "CAMPANIA", "PUGLIA", ///
    "BASILICATA", "CALABRIA", "SICILIA", "SARDEGNA")
* Check: only central and unclassified authorities are left without an area
count if g_macro == "" & !inlist(regname, "CENTRALE", "NON CLASSIFICATO")
assert r(N) == 0

* ANAC register of contracting authorities (legal type)
preserve
local here = c(pwd)
cd "data/intermediate"
unzipfile "../raw/stazioni-appaltanti_csv.zip", replace
cd "`here'"
import delimited using "data/intermediate/stazioni-appaltanti_csv.csv", ///
    delimiter(";") stringcols(_all) clear
erase "data/intermediate/stazioni-appaltanti_csv.csv"
keep codice_fiscale natura_giuridica_codice natura_giuridica_descrizione
isid codice_fiscale
rename codice_fiscale authority_id
tempfile register
save `register'
restore

merge m:1 authority_id using `register', keep(master match) gen(_mreg)
di as text "  Lots matched to the ANAC register (tax code), P2 and $CTRL_G, (100k, 200k]:"
tab _mreg if (period == 2 | ${g_CTRL}) & importo_lotto > 100000 & importo_lotto <= 200000
gen str8 g_auth = ""
replace g_auth = "Public" if inlist(natura_giuridica_codice, "55", "15", "14", "18")
replace g_auth = "Company" if g_auth == "" & _mreg == 3 ///
    & strpos(ustrupper(natura_giuridica_descrizione), "SOCIET") == 1
replace g_auth = "Other" if g_auth == "" & _mreg == 3
* Municipalities and health bodies by legal-type code (why only 3 groups):
* share of their P1b + P2 lots registered under code 55 and under code 15
gen _nm = ustrupper(authority_name)
gen byte _muni   = strpos(_nm, "COMUNE DI ") == 1
gen byte _health = regexm(_nm, "AZIENDA SANITARIA|AZIENDA OSPEDALIERA|AZIENDA UNITA SANITARIA|^ASL |^A\.S\.L\.")
foreach g in muni health {
    di as text "  Legal-type codes of `g' (P1b + P2 lots):"
    tab natura_giuridica_codice if _`g' == 1 & _mreg == 3 & (period == 2 | ${g_CTRL}), sort
    gen byte _c55 = natura_giuridica_codice == "55" if _`g' == 1 & _mreg == 3 & (period == 2 | ${g_CTRL})
    gen byte _c15 = natura_giuridica_codice == "15" if _`g' == 1 & _mreg == 3 & (period == 2 | ${g_CTRL})
    summarize _c55, meanonly
    dpost `g'_share_code55 `r(mean)'
    summarize _c15, meanonly
    dpost `g'_share_code15 `r(mean)'
    drop _c55 _c15
}
drop _nm _muni _health
tab natura_giuridica_descrizione g_auth if (period == 2 | ${g_CTRL}) ///
    & importo_lotto > 100000 & importo_lotto <= 200000 & g_auth != "Public", m

* ---- Estimates: every group × period cell ----
tempname bp pt
tempfile bdraws pts
postfile `bp' str10 grouping str8 level str4 per int rep double b using `bdraws'
postfile `pt' str10 grouping str8 level str4 per double b n_lots using `pts'
set seed 20261113
foreach gv in contract central macro auth {
    quietly levelsof g_`gv' if g_`gv' != "", local(levs)
    foreach l of local levs {
        foreach p in P2 $CTRL_G {
            preserve
            quietly keep if ${g_`p'} & g_`gv' == "`l'"
            bunch_grp `bp' `gv' `l' `p' 200
            post `pt' ("`gv'") ("`l'") ("`p'") (r(b)) (r(n_lots))
            restore
        }
    }
}
postclose `bp'
postclose `pt'

* ---- Confidence intervals ----
preserve
use `bdraws', clear
reshape wide b, i(grouping level rep) j(per) string
gen double d = bP2 - b${CTRL_G}
* Gap relative to the reference level of each grouping (same draw number;
* the cells hold different lots, so the draws are independent)
gen byte ref = (grouping == "contract" & level == "Services") ///
    | (grouping == "central" & level == "Other") ///
    | (grouping == "macro" & level == "North") ///
    | (grouping == "auth" & level == "Public")
bysort grouping rep: egen double d_ref = max(cond(ref, d, .))
gen double gap = d - d_ref
foreach v in bP2 b$CTRL_G d gap {
    bysort grouping level: egen double `v'_lo = pctile(`v'), p(2.5)
    bysort grouping level: egen double `v'_hi = pctile(`v'), p(97.5)
}
bysort grouping level: keep if _n == 1
keep grouping level *_lo *_hi
tempfile cis
save `cis'

use `pts', clear
reshape wide b n_lots, i(grouping level) j(per) string
gen double d = bP2 - b${CTRL_G}
gen byte ref = (grouping == "contract" & level == "Services") ///
    | (grouping == "central" & level == "Other") ///
    | (grouping == "macro" & level == "North") ///
    | (grouping == "auth" & level == "Public")
bysort grouping: egen double d_ref = max(cond(ref, d, .))
gen double gap = d - d_ref
merge 1:1 grouping level using `cis', nogen
gen int order = cond(grouping == "contract", 1, cond(grouping == "central", 2, ///
    cond(grouping == "macro", 3, 4)))
sort order level
format b* d* gap* %6.2f
di as text _n "  b_hat by group: P2, $CTRL_G, difference (95% CI), gap vs reference (95% CI)"
list grouping level n_lotsP2 n_lots${CTRL_G} bP2 b${CTRL_G} d d_lo d_hi gap gap_lo gap_hi, ///
    noobs clean abbreviate(10)
drop order ref d_ref
export delimited using "results/tables/B5_bunching_by_group${SFX}.csv", replace
restore

* ---- Lots at exactly €139,000 in P2: how many, and how many direct ----
foreach gv in contract central macro auth {
    di as text _n "  Lots at exactly 139,000 in P2, by `gv' (frequency, share direct):"
    table g_`gv' if period == 2 & importo_lotto == 139000 & g_`gv' != "", ///
        stat(freq) stat(mean direct) nformat(%5.3f)
}

* RESULTS 3.6 (main run; b_hat, 95% bootstrap CI of P2 − P1b; the
* gap is the P2 − P1b difference minus that of the reference level):
*                    P2      P1b    P2 − P1b [CI]          gap vs ref [CI]
*   Services        14.4     0.4    14.0 [10.7, 18.7]      (ref)
*   Supplies        10.4     0.6     9.8 [ 7.4, 12.7]      −4.2 [−9.6, −0.2]
*   Other auth.     12.4    −0.4    12.8 [10.2, 15.4]      (ref)
*   Central         14.6     4.9     9.7 [ 5.2, 14.2]      −3.2 [−8.5,  2.6]
*   North           13.8    −0.9    14.7 [12.2, 17.4]      (ref)
*   Centre          12.3     0.5    11.8 [ 9.1, 15.5]      −2.9 [−6.5,  0.7]
*   South           8.7     −0.2     8.9 [ 7.0, 11.6]      −5.8 [−9.0, −1.9]
*   Public          12.1     0.7    11.4 [ 9.0, 14.3]      (ref)
*   Company         15.6    −0.7    16.3 [11.8, 20.8]      +4.9 [−0.7,  9.5]
*   Other entity    14.1     0.8    13.4 [ 9.8, 17.2]      +2.0 [−3.1,  6.1]
* Lots at exactly €139,000 in P2, share direct: services 0.83, supplies
* 0.73; central 0.64, others 0.84; North 0.83, Centre 0.83, South 0.79;
* companies 0.91, public bodies 0.76, other entities 0.85.
* HOW TO READ IT:
* - Every group bunches after the reform; none bunched before, except
*   central authorities (P1b b_hat 4.9 [2.9, 8.1]). That fits the
*   note in 1.3: €139k may already have been an EU threshold for central
*   government, and it matches their pre-reform jump in direct award (Part 2).
* - Bunching is weaker in the South (gap −5.8) and for supplies (−4.2, CI
*   just below 0); companies bunch somewhat more than public bodies (+4.9,
*   CI includes 0). The South result matches Part 6 (lower take-up of
*   direct award in the South, e.g. Sicily 0.12).
* - Ten levels and six gaps are compared without a multiple-testing
*   correction; read the gaps as descriptive.

drop g_contract g_central g_macro g_auth regname natura_giuridica_codice ///
    natura_giuridica_descrizione _mreg


* ##############################################################################
* ##############################################################################
* ##                                                                          ##
* ##   PART 4: MAIN DIFFERENCE-IN-DISCONTINUITIES (Module M)                 ##
* ##                                                                          ##
* ##   First stage, ITT outcomes, IV/LATE, selection-free award outcomes,     ##
* ##   time series, robustness, value-band DiD                                ##
* ##                                                                          ##
* ##############################################################################
* ##############################################################################

use "data/intermediate/lots_v2.dta", clear

* ==============================================================================
* 4.0  SAMPLE DEFINITION
* ==============================================================================
* Main sample: control period ($CTRL_G) + P2, non-PNRR. Main control = P1b.
* WHY exclude PNRR? PNRR (EU Recovery Fund) lots face deadline pressure and
* different rules. They could confound the effect of the threshold change.
* Robustness 4.6f includes them. NOTE: the PNRR flag is almost always blank
* before 2021 (it did not exist), so in the control period pnrr = 0 by
* construction; the exclusion only bites in P2.
*
* WHY is P1b a valid control at 139k? In P1b direct award was allowed below
* €75k only, so in the estimation windows (h ≤ 60k → lots ≥ €79k) no lot was
* direct-eligible on either side of 139k. alt_sample uses the other control
* period (P0) for robustness 4.6i.

gen byte pnrr = (flag_pnrr_pnc == "1" | flag_pnrr_pnc == "SI")
gen byte main_sample = (${g_CTRL} | period == 2) & pnrr == 0
gen byte alt_sample  = (${g_ALT}  | period == 2) & pnrr == 0

* Create FE group variables
egen cpv2_post = group(cpv2 post)
egen region_post = group(region post)
gen ym = ym(year(pub_date), month(pub_date))

* Pre-compute triangular kernel weights for all bandwidths
* TRIANGULAR KERNEL: w = max(0, 1 − |x|/h). Gives more weight to lots closer
* to the cutoff, less weight further away, zero beyond h. This is standard in
* RD designs to reduce bias from observations far from the cutoff.
gen float kw40 = max(0, 1 - abs(x)/40000) if abs(x) <= 40000
gen float kw20 = max(0, 1 - abs(x)/20000) if abs(x) <= 20000
gen float kw30 = max(0, 1 - abs(x)/30000) if abs(x) <= 30000
gen float kw60 = max(0, 1 - abs(x)/60000) if abs(x) <= 60000

* Time series (4.5, 4.7) use rel_sem, the semester aligned to 1 Jun 2021
* (built in section 1.3), instead of calendar half-years.

di as text "  Main sample: " %12.0fc _N " total lots"
count if main_sample == 1
di as text "  Main sample ($CTRL_G + P2, non-PNRR): " %12.0fc r(N)
count if main_sample == 1 & abs(x) <= 40000
di as text "  Main sample, |x| <= 40k: " %12.0fc r(N)
count if main_sample == 1 & abs(x) <= 40000 & has_award == 1
di as text "  Main sample, |x| <= 40k, awarded: " %12.0fc r(N)


* ==============================================================================
* 4.1  FIRST STAGE
* ==============================================================================
* The "first stage" tests whether the reform actually CHANGED the probability
* of direct award at the €139k cutoff.
*
* SPECIFICATION: regress direct on below×post (the interaction), controlling
* for below, post, and absorbed FEs. The coefficient on below×post tells us:
* "How much did the probability of direct award BELOW 139k change from the
* control period (P1b) to P2, RELATIVE to the change ABOVE 139k?"
*
* We expect a LARGE POSITIVE coefficient: the reform made direct award legal
* below 139k in P2, but not above 139k, and it was legal neither below nor
* above 139k in P1b (limit €75k) or P0 (limit €40k). So the DiD should capture
* the reform's causal effect on procedure choice.
*
* The F reported is t² of below×post (one excluded instrument), not reghdfe's
* e(F), which is the joint F of all regressors.

di as text _n "========================================"
di as text    "  4.1: FIRST STAGE"
di as text    "========================================"

* Main specification: h=40k
di as text _n "--- All lots, h=40k ---"
reghdfe direct i.below##i.post##c.x [aw=kw40] ///
    if main_sample == 1 & abs(x) <= 40000, ///
    absorb(cpv2_post region_post ym) vce(cluster authority_id)

local fs_coef = _b[1.below#1.post]
local fs_se = _se[1.below#1.post]
local fs_t = `fs_coef' / `fs_se'
local fs_F = `fs_t'^2
di as text "  FS: " %7.4f `fs_coef' " (" %7.4f `fs_se' ")  t²=" %6.1f `fs_F' "  N=" %9.0f e(N)
rpost Mrob main direct, extra(`fs_F')
estimates store fs_all_40

* Bandwidth robustness: check stability at h=20k, 30k, 60k
foreach h in 20000 30000 60000 {
    local hk = `h'/1000
    di as text _n "--- All lots, h=`hk'k ---"
    capture drop kw_h
    gen float kw_h = max(0, 1 - abs(x)/`h') if abs(x) <= `h'
    reghdfe direct i.below##i.post##c.x [aw=kw_h] ///
        if main_sample == 1 & abs(x) <= `h', ///
        absorb(cpv2_post region_post ym) vce(cluster authority_id)
    di as text "  FS: " %7.4f _b[1.below#1.post] " (" %7.4f _se[1.below#1.post] ")  N=" %9.0f e(N)
    rpost Mrob h`hk' direct
    drop kw_h
}

* Data-driven (MSE-optimal) bandwidths in P2, selected within the ±40k
* estimation window, for comparison with h = 40k
foreach v in direct days_award lratio {
    local cond "has_award == 1"
    if "`v'" == "direct" local cond "1"
    quietly rdbwselect `v' xr if period == 2 & pnrr == 0 & abs(x) <= 40000 & `cond', ///
        kernel(triangular) bwselect(mserd) masspoints(off)
    dpost bw_mserd_p2_`v' `e(h_mserd)'
}

* RESULTS (P1b control, main run):
* FS = 0.435 (SE 0.022), t² = 405, N = 96,788. Stable across bandwidths:
* h=20k 0.435, h=30k 0.439, h=60k 0.419. The reform raised the share of
* direct awards just below 139k by about 44 pp relative to just above.
* Data-driven (MSE-optimal) bandwidths in P2, selected within ±40k (computed
* above): 8k for direct, 10k for days, 15k for lratio, so h=40k trades
* some bias for precision; the h=20k rows are the check on that.


* ==============================================================================
* 4.2  ITT OUTCOMES
* ==============================================================================
* The ITT (intent-to-treat) estimates are REDUCED-FORM effects of being just
* below 139k in P2 (eligible for direct award) vs just above. They combine
* the effect of the reform on procedure choice (first stage) with the effect
* of the procedure on outcomes.
*
* WHY ITT and not just the LATE? ITT is cleaner because it doesn't require
* the exclusion restriction. It answers: "What happens to lots near the cutoff
* when the law makes direct award available?" The LATE asks: "What is the
* effect of actually using direct award?" — which requires the instrument
* (below×post) to affect outcomes ONLY through procedure choice.
*
* SAMPLE: awarded lots only (has_award == 1). This is necessary because
* outcomes are only observed for awarded lots. But it can introduce selection
* bias if the reform changed which lots get an award record (coverage DiD in
* 2.2; selection-free outcomes in 4.4).

di as text _n "========================================"
di as text    "  4.2: ITT OUTCOMES"
di as text    "========================================"

foreach var in days_award lratio single_bid nbids n_invited {
    di as text _n "--- ITT: `var' (h=40k, awarded lots) ---"

    capture reghdfe `var' i.below##i.post##c.x [aw=kw40] ///
        if main_sample == 1 & abs(x) <= 40000 & has_award == 1, ///
        absorb(cpv2_post region_post ym) vce(cluster authority_id)
    if !_rc {
        di as text "  below×post: " %8.4f _b[1.below#1.post] ///
            "  SE=" %7.4f _se[1.below#1.post] ///
            "  p=" %6.4f 2*ttail(e(df_r), abs(_b[1.below#1.post]/_se[1.below#1.post])) ///
            "  N=" e(N)
        rpost Mrob main `var'
        cstore itt_`var' `var'
    }

    * Bandwidth robustness for the 3 main outcomes
    if inlist("`var'", "days_award", "lratio", "single_bid") {
        foreach h in 20000 30000 60000 {
            local hk = `h'/1000
            capture drop kw_h
            gen float kw_h = max(0, 1 - abs(x)/`h') if abs(x) <= `h'
            capture reghdfe `var' i.below##i.post##c.x [aw=kw_h] ///
                if main_sample == 1 & abs(x) <= `h' & has_award == 1, ///
                absorb(cpv2_post region_post ym) vce(cluster authority_id)
            if !_rc {
                di as text "    h=`hk'k: " %8.4f _b[1.below#1.post] ///
                    " (" %7.4f _se[1.below#1.post] ")  N=" e(N)
                rpost Mrob h`hk' `var'
            }
            drop kw_h
        }
    }
}

* Facts used in HOW TO READ THEM below (P2, non-PNRR, ±40k, awarded lots)
local W2 "period == 2 & pnrr == 0 & abs(x) <= 40000 & has_award == 1"
gen byte _onebid = (nbids == 1) if !missing(nbids)
summarize _onebid if `W2' & direct == 1, meanonly
dpost p2_direct_share_onebid `r(mean)'
gen byte _atbase = (abs(lratio) < 1e-9) if !missing(lratio)
summarize _atbase if `W2' & direct == 1, meanonly
dpost p2_direct_share_award_eq_base `r(mean)'
summarize _atbase if `W2' & direct == 0, meanonly
dpost p2_other_share_award_eq_base `r(mean)'
summarize lratio if main_sample == 1 & abs(x) <= 40000 & has_award == 1
dpost lratio_window_min `r(min)'
dpost lratio_window_max `r(max)'
count if main_sample == 1 & abs(x) <= 40000 & has_award == 1 & lratio < -1
dpost n_lratio_window_below_m1 `r(N)'
drop _onebid _atbase

* RESULTS (awarded lots, h=40k):
*   days_award  −52.3 (10.7)  p<0.001   [h=20k −59.1, 30k −54.3, 60k −44.6]
*   lratio      +0.075 (0.030) p=0.012  [h=20k +0.071 (0.042), 30k +0.067, 60k +0.077]
*   single_bid  +0.148 (0.022) p<0.001  [h=20k +0.156, 30k +0.149, 60k +0.134]
*   nbids       −1.01 (0.42)  p=0.017
*   n_invited   −61 (38)      p=0.11  (driven by extreme values; not used)
* HOW TO READ THEM:
* - single_bid and nbids are largely MECHANICAL: 87% of P2 direct awards in
*   the window record exactly one bid. They show that the procedure changed,
*   not separately that markets became less competitive.
* - lratio = log(award/base). 46% of P2 direct awards have award = base
*   exactly (lratio = 0) vs 27% of other procedures, so a higher lratio may
*   mean "no discount recorded" (base set at the agreed price) rather than
*   "paid more"; the data cannot separate the two. lratio also has extreme
*   tails (min −15, max 6.9; 2,584 lots below −1).


* ==============================================================================
* 4.3  FUZZY IV / LATE
* ==============================================================================
* The LATE (Local Average Treatment Effect) uses below×post as an INSTRUMENT
* for the endogenous variable "direct" (whether the lot was actually awarded
* via direct procedure). The LATE estimates the effect of actually USING
* direct award, for the "compliers" (lots that switched to direct award
* because of the reform).
*
* LATE ≈ ITT / first_stage, where the first stage is the one in the SAME
* sample (awarded lots, ≈ 0.44, close to the all-lots 0.435 of 4.1).
* Here: ITT on days = −52.3, so LATE ≈ −52.3/0.44 ≈ −119 days.
*
* We use ivreghdfe which handles high-dimensional FE + IV estimation.

di as text _n "========================================"
di as text    "  4.3: FUZZY IV (LATE)"
di as text    "========================================"

gen float below_post = below * post
gen float below_x = below * x
gen float post_x = post * x
gen float below_post_x = below * post * x

foreach var in days_award lratio single_bid nbids {
    di as text _n "--- IV: `var' (h=40k, awarded lots) ---"

    capture ivreghdfe `var' below post x below_x post_x below_post_x ///
        (direct = below_post) [aw=kw40] ///
        if main_sample == 1 & abs(x) <= 40000 & has_award == 1, ///
        absorb(cpv2_post region_post ym) cluster(authority_id)
    if !_rc {
        di as text "  LATE: " %8.2f _b[direct] ///
            "  SE=" %7.2f _se[direct] ///
            "  KP F=" %6.1f e(widstat) ///
            "  p=" %6.4f 2*ttail(e(df_r), abs(_b[direct]/_se[direct])) ///
            "  N=" e(N)
        rpost Mlate main `var', coef(direct) extra(`e(widstat)')
        estimates store iv_`var'
    }
}

* RESULTS (awarded lots, h=40k; KP F ≈ 456):
*   days_award −118.6 (24.3), lratio +0.17 (0.07, p=0.011),
*   single_bid +0.34 (0.05), nbids −2.29 (0.96, p=0.017).
* Check: ITT/LATE = −52.3/−118.6 = 0.44 = first stage in the awarded sample.
* The exclusion restriction matters most for lratio and single_bid, which
* direct award changes partly by construction (see 4.2).


* ==============================================================================
* 4.4  SELECTION-ROBUST OUTCOMES
* ==============================================================================
* PROBLEM: outcomes such as days to award exist only for lots with an award
* record. We define outcomes observable for ALL lots (no selection into
* having an award record):
*   awarded_90  = has award within 90 days of publication
*   awarded_180 = has award within 180 days
* These avoid the coverage selection problem entirely.

di as text _n "========================================"
di as text    "  4.4: SELECTION-ROBUST OUTCOMES"
di as text    "========================================"

* A logical expression is never missing, so lots without an award record
* (or with missing days_award) get 0 automatically.
gen byte awarded_90 = (has_award == 1 & days_award <= 90)
gen byte awarded_180 = (has_award == 1 & days_award <= 180)

foreach var in awarded_90 awarded_180 {
    di as text _n "--- `var' (h=40k, ALL lots, no selection) ---"
    capture reghdfe `var' i.below##i.post##c.x [aw=kw40] ///
        if main_sample == 1 & abs(x) <= 40000, ///
        absorb(cpv2_post region_post ym) vce(cluster authority_id)
    if !_rc {
        di as text "  below×post: " %8.4f _b[1.below#1.post] ///
            "  SE=" %7.4f _se[1.below#1.post] ///
            "  p=" %6.4f 2*ttail(e(df_r), abs(_b[1.below#1.post]/_se[1.below#1.post])) ///
            "  N=" e(N)
        quietly summarize `var' if e(sample) & ${g_CTRL} & below == 1, meanonly
        rpost Msel main `var', extra(`r(mean)')
    }
}

* Right-censoring check: awards dated after the end of P2 exist in the data,
* and the share of P2 lots with an award record by publication month,
* Jan–Jun 2023 (a drop in the last months would signal censoring)
forvalues y = 2024/2025 {
    count if has_award == 1 & year(award_date) == `y'
    dpost n_awards_dated_`y' `r(N)'
}
forvalues m = 1/6 {
    summarize has_award if period == 2 & pnrr == 0 & ym == ym(2023, `m'), meanonly
    dpost p2_coverage_2023m`m' `r(mean)'
}

* RESULTS (all lots, h=40k, N = 96,788):
*   awarded_90  +0.098 (0.022) p<0.001;  awarded_180 +0.082 (0.023) p<0.001.
* These are free of selection into the sample, but they MIX two things:
* having an award record at all (coverage DiD vs P1b: +0.033, p=0.15, 2.2)
* and being awarded faster. Read them as "more lots below 139k reach a
* recorded award within 3/6 months", not as a pure speed effect.
* No right-censoring worry: the data contain 28,369 awards dated 2024 and 2,129
* dated 2025, and the share of P2 lots with an award record does not fall
* for the latest publications (0.41 in Jan 2023, 0.48 in Jun 2023).


* ==============================================================================
* 4.5  DISCONTINUITY TIME SERIES
* ==============================================================================
* RD at 139k for each 6-month block, using rdrobust with h=20k.
* This produces a "time series of discontinuities" that visually confirms
* the reform's timing: the jump should appear only from 1 Jun 2021.
*
* WHY semesters aligned to 1 Jun 2021 (rel_sem, section 1.3) instead of
* calendar half-years? Calendar 2021h1 includes June 2021 (P2), so the last
* "pre" point would already be partly treated. With rel_sem, block −1 is
* Dec 2020 – May 2021 (all P1b) and block 0 is the first P2 semester.
*
* The series runs into P3 (as coded in 1.3: from 1 Jul 2023, D.Lgs 36/2023,
* new Code). Semester 4 is Jun 2023 (P2) + Jul–Nov 2023 (P3) and
* semester 5 is all P3. A smaller jump there reflects the change of regime,
* not the P2 effect fading out; the plots mark the boundary at 3.5.

di as text _n "========================================"
di as text    "  4.5: DISCONTINUITY TIME SERIES"
di as text    "========================================"

levelsof rel_sem if year(pub_date) >= 2018 & year(pub_date) <= 2023, local(hys)

tempfile rd_series
postfile rd_handle rel_sem rd_direct se_direct rd_lratio se_lratio using `rd_series'

foreach hy of local hys {
    quietly {
        capture rdrobust direct xr if rel_sem == `hy' & pnrr == 0, ///
            h(20000) kernel(triangular) masspoints(off)
        if !_rc {
            local rd_d = e(tau_cl)
            local se_d = e(se_tau_cl)
        }
        else {
            local rd_d = .
            local se_d = .
        }

        capture rdrobust lratio xr if rel_sem == `hy' & pnrr == 0 & has_award == 1, ///
            h(20000) kernel(triangular) masspoints(off)
        if !_rc {
            local rd_l = e(tau_cl)
            local se_l = e(se_tau_cl)
        }
        else {
            local rd_l = .
            local se_l = .
        }

        post rd_handle (`hy') (`rd_d') (`se_d') (`rd_l') (`se_l')
    }
    di as text "  sem " %3.0f `hy' ": direct=" %7.4f `rd_d' " (" %7.4f `se_d' ")" ///
        "  lratio=" %7.4f `rd_l' " (" %7.4f `se_l' ")"
}
postclose rd_handle

* Plot. Dashed line: start of block −1 (Dec 2020, all P1b). Solid: reform.
preserve
use `rd_series', clear
export delimited using "results/tables/M4_rd_series${SFX}.csv", replace

gen float ci_lo_d = rd_direct - 1.96 * se_direct
gen float ci_hi_d = rd_direct + 1.96 * se_direct

twoway (rcap ci_lo_d ci_hi_d rel_sem, lcolor(navy%50)) ///
    (scatter rd_direct rel_sem, mcolor(navy) msize(medium)), ///
    xline(-1.5, lcolor(red) lpattern(dash)) ///
    xline(-0.5, lcolor(cranberry) lpattern(solid) lwidth(medthick)) ///
    yline(0, lcolor(gs8) lpattern(dot)) ///
    xtitle("Semester relative to 1 Jun 2021 (0 = Jun-Nov 2021)") ytitle("RD estimate (direct)") ///
    title("Discontinuity at 139k over time — Direct award") ///
    xline(3.5, lcolor(gs8) lpattern(shortdash)) ///
    note("Dashed: start of last P1b semester (Dec 2020). Solid: DL77/2021 (1 Jun 2021)." "Grey: from semester 4 lots are mostly P3 (from 1 Jul 2023)") ///
    legend(off) graphregion(color(white))
graph export "results/figures/M4_rd_direct${SFX}.png", width(2000) replace

gen float ci_lo_l = rd_lratio - 1.96 * se_lratio
gen float ci_hi_l = rd_lratio + 1.96 * se_lratio

twoway (rcap ci_lo_l ci_hi_l rel_sem, lcolor(navy%50)) ///
    (scatter rd_lratio rel_sem, mcolor(navy) msize(medium)), ///
    xline(-1.5, lcolor(red) lpattern(dash)) ///
    xline(-0.5, lcolor(cranberry) lpattern(solid) lwidth(medthick)) ///
    yline(0, lcolor(gs8) lpattern(dot)) ///
    xtitle("Semester relative to 1 Jun 2021 (0 = Jun-Nov 2021)") ytitle("RD estimate (lratio)") ///
    title("Discontinuity at 139k over time — Price (lratio)") ///
    xline(3.5, lcolor(gs8) lpattern(shortdash)) ///
    note("Dashed: start of last P1b semester (Dec 2020). Solid: DL77/2021 (1 Jun 2021)." "Grey: from semester 4 lots are mostly P3 (from 1 Jul 2023)") ///
    legend(off) graphregion(color(white))
graph export "results/figures/M4_rd_lratio${SFX}.png", width(2000) replace
restore

* RESULTS (rdrobust, h=20k, sign = ABOVE − BELOW):
* direct: pre-reform semesters −6 to −1 between −0.006 and +0.011 (all n.s.);
* the earliest, −7 (Dec 2017–May 2018), is +0.066 (0.029). Semesters 0–3:
* −0.57, −0.50, −0.56, −0.54 — the jump appears exactly at the reform and
* stays flat. Semester 4: −0.066, semester 5: +0.003 (P3, see above).
* lratio: pre-reform between −0.080 and +0.048, none significant; post
* −0.15, −0.09, −0.06, −0.10 (below-139k lots have higher lratio).


* ==============================================================================
* 4.6  ROBUSTNESS
* ==============================================================================

di as text _n "========================================"
di as text    "  4.6: ROBUSTNESS"
di as text    "========================================"

* ---- 4.6a: Donut specifications ----
* WHY? Lots exactly at the cutoff are most likely to be manipulated (bunching).
* Dropping lots within d of the cutoff removes the most manipulated observations.
* If the effect SURVIVES (or strengthens), the results are not driven by bunching.

di as text _n "--- Donuts ---"
foreach d in 1000 2500 5000 {
    local dk = `d'/1000
    di as text _n "  Donut `dk'k:"
    foreach var in days_award lratio single_bid {
        capture reghdfe `var' i.below##i.post##c.x [aw=kw40] ///
            if main_sample == 1 & abs(x) <= 40000 & abs(x) >= `d' & has_award == 1, ///
            absorb(cpv2_post region_post ym) vce(cluster authority_id)
        if !_rc {
            di as text "    `var': " %8.4f _b[1.below#1.post] ///
                " (" %7.4f _se[1.below#1.post] ")"
            rpost Mrob donut`d' `var'
        }
    }
}

* ---- 4.6b: Local quadratic ----
* WHY? The main spec uses a local LINEAR function of x. If the true
* relationship is curved, the linear approximation could be biased. Adding x²
* tests whether a more flexible functional form changes the results.

di as text _n "--- Local quadratic ---"
gen float x2 = x^2
foreach var in days_award lratio single_bid {
    capture reghdfe `var' i.below##i.post##c.x i.below##i.post##c.x2 [aw=kw40] ///
        if main_sample == 1 & abs(x) <= 40000 & has_award == 1, ///
        absorb(cpv2_post region_post ym) vce(cluster authority_id)
    if !_rc {
        di as text "  `var': " %8.4f _b[1.below#1.post] ///
            " (" %7.4f _se[1.below#1.post] ")"
        rpost Mrob quad `var'
    }
}

* ---- 4.6c: Placebo cutoffs in P2 ----
* WHY? If our design is valid, we should find effects only at the TRUE cutoff
* (139k), not at arbitrary values (100k, 120k, 160k, 200k). Each placebo uses
* only lots on one side of 139k, so the real jump does not leak in.

di as text _n "--- Placebo cutoffs in P2 (one-sided, with slopes) ---"
* Below-139k placebos: only lots < 139k, h=15k
foreach c in 100000 120000 {
    local ck = `c'/1000
    local h = 15000
    gen float x_plac = importo_lotto - `c'
    gen byte below_plac = (importo_lotto < `c')
    gen float kw_plac = max(0, 1 - abs(x_plac)/`h') if abs(x_plac) <= `h'

    di as text "  Cutoff `ck'k (below 139k only, h=15k):"
    foreach var in direct days_award lratio {
        local cond "has_award == 1"
        if "`var'" == "direct" local cond "1"

        capture reghdfe `var' i.below_plac##c.x_plac [aw=kw_plac] ///
            if period == 2 & pnrr == 0 & abs(x_plac) <= `h' ///
            & importo_lotto < 139000 & `cond', ///
            absorb(cpv2 region ym) vce(cluster authority_id)
        if !_rc {
            di as text "    `var': " %8.4f _b[1.below_plac] " (" %7.4f _se[1.below_plac] ")"
            rpost Mplac c`ck' `var', coef(1.below_plac)
        }
    }
    drop x_plac below_plac kw_plac
}
* Above-139k placebos: only lots > 139k
foreach c in 160000 200000 {
    local ck = `c'/1000
    local h = 15000
    if `c' == 200000 local h = 10000
    gen float x_plac = importo_lotto - `c'
    gen byte below_plac = (importo_lotto < `c')
    gen float kw_plac = max(0, 1 - abs(x_plac)/`h') if abs(x_plac) <= `h'

    di as text "  Cutoff `ck'k (above 139k only, h=`=`h'/1000'k):"
    foreach var in direct days_award lratio {
        local cond "has_award == 1"
        if "`var'" == "direct" local cond "1"

        capture reghdfe `var' i.below_plac##c.x_plac [aw=kw_plac] ///
            if period == 2 & pnrr == 0 & abs(x_plac) <= `h' ///
            & importo_lotto > 139000 & `cond', ///
            absorb(cpv2 region ym) vce(cluster authority_id)
        if !_rc {
            di as text "    `var': " %8.4f _b[1.below_plac] " (" %7.4f _se[1.below_plac] ")"
            rpost Mplac c`ck' `var', coef(1.below_plac)
        }
    }
    drop x_plac below_plac kw_plac
}

* ---- 4.6d: Placebo — 139k in the pre-reform periods ----
* WHY? THE key placebo. If there's a discontinuity at 139k BEFORE the reform,
* the diff-in-disc mixes the reform with a pre-existing jump. There shouldn't
* be one because 139k was not a national threshold for services/supplies.
* Both candidate control periods are shown (P1b main, P0 alternative).

foreach g in P1b P0 {
    di as text _n "--- Placebo: 139k cutoff in `g' ---"
    foreach var in direct days_award lratio {
        local cond "has_award == 1"
        if "`var'" == "direct" local cond "1"

        capture reghdfe `var' i.below##c.x [aw=kw40] ///
            if ${g_`g'} & pnrr == 0 & abs(x) <= 40000 & `cond', ///
            absorb(cpv2 region ym) vce(cluster authority_id)
        if !_rc {
            di as text "  `var' (`g'): " %8.4f _b[1.below] " (" %7.4f _se[1.below] ")" ///
                "  N=" e(N)
            rpost Mplac p139_`g' `var', coef(1.below)
        }
    }
}

* ---- 4.6e: Cluster by province ----
* WHY? Our main spec clusters by authority. But authorities in the same province
* might be correlated (common local conditions). Province clustering is more
* conservative (fewer clusters → larger SEs).
*
* provincia is blank for about a third of the awarded lots in the window
* (17,818 of 53,598; computed below). reghdfe silently drops observations with a missing
* cluster variable, so clustering on provincia alone would run on a smaller,
* different sample. Lots with a blank province are clustered at the region level
* (central authorities form one cluster), which keeps the main sample and is
* if anything more conservative. N is printed to confirm it matches 4.2.

di as text _n "--- Cluster by province (region if province blank) ---"
count if main_sample == 1 & abs(x) <= 40000 & has_award == 1 & provincia == ""
dpost n_window_awarded_blank_province `r(N)'
count if main_sample == 1 & abs(x) <= 40000 & has_award == 1
dpost n_window_awarded `r(N)'
gen str80 prov_cl = provincia
replace prov_cl = "REGION: " + region if prov_cl == ""
encode prov_cl, gen(province_id)
foreach var in days_award lratio single_bid {
    capture reghdfe `var' i.below##i.post##c.x [aw=kw40] ///
        if main_sample == 1 & abs(x) <= 40000 & has_award == 1, ///
        absorb(cpv2_post region_post ym) vce(cluster province_id)
    if !_rc {
        di as text "  `var': " %8.4f _b[1.below#1.post] ///
            " (" %7.4f _se[1.below#1.post] ")  clusters=" e(N_clust) "  N=" e(N)
        rpost Mrob provcl `var', extra(`e(N_clust)')
    }
}

* ---- 4.6f: Including PNRR lots ----
* WHY? We excluded PNRR lots from the main sample. If results are the same
* with them, PNRR doesn't drive our findings.

di as text _n "--- Including PNRR lots ---"
foreach var in days_award lratio single_bid {
    capture reghdfe `var' i.below##i.post##c.x [aw=kw40] ///
        if (${g_CTRL} | period == 2) & abs(x) <= 40000 & has_award == 1, ///
        absorb(cpv2_post region_post ym) vce(cluster authority_id)
    if !_rc {
        di as text "  `var' (with PNRR): " %8.4f _b[1.below#1.post] ///
            " (" %7.4f _se[1.below#1.post] ")"
        rpost Mrob pnrr `var'
    }
}

* ---- 4.6g: Mass point at exact €139k ----
* About 11% of P2 lots within ±5k sit at exactly €139,000. The main
* specification counts them as eligible (below = importo_lotto <= 139000,
* section 1.7). Two checks:
*   (i)  exclude them — they are the most likely rounded/manipulated values;
*   (ii) the old strict definition (below_strict = importo_lotto < 139000),
*        which puts them on the above side.

di as text _n "--- Mass point at exact 139k ---"
di as text "  Lots at exactly 139k by period:"
foreach p of global GROUPS {
    count if importo_lotto == 139000 & ${g_`p'}
    local n_139 = r(N)
    count if abs(x) <= 5000 & ${g_`p'}
    local n_5k = r(N)
    if `n_5k' > 0 {
        di as text "    `p': " %6.0f `n_139' " of " %6.0f `n_5k' ///
            " within +/-5k (" %4.1f 100*`n_139'/`n_5k' "%)"
    }
}

di as text _n "  Main outcomes excluding mass point:"
foreach var in direct days_award lratio single_bid {
    local cond "has_award == 1"
    if "`var'" == "direct" local cond "1"
    capture reghdfe `var' i.below##i.post##c.x [aw=kw40] ///
        if main_sample == 1 & abs(x) <= 40000 & importo_lotto != 139000 & `cond', ///
        absorb(cpv2_post region_post ym) vce(cluster authority_id)
    if !_rc {
        di as text "    `var': " %8.4f _b[1.below#1.post] ///
            " (" %7.4f _se[1.below#1.post] ")"
        rpost Mrob no139 `var'
    }
}

di as text _n "  Main outcomes with the strict definition (139k counted as above):"
foreach var in direct days_award lratio single_bid nbids {
    local cond "has_award == 1"
    if "`var'" == "direct" local cond "1"
    capture reghdfe `var' i.below_strict##i.post##c.x [aw=kw40] ///
        if main_sample == 1 & abs(x) <= 40000 & `cond', ///
        absorb(cpv2_post region_post ym) vce(cluster authority_id)
    if !_rc {
        di as text "    `var': " %8.4f _b[1.below_strict#1.post] ///
            " (" %7.4f _se[1.below_strict#1.post] ")"
        rpost Mrob strict `var', coef(1.below_strict#1.post)
    }
}

* ---- 4.6h: rdrobust cross-check ----
* Non-parametric diff-in-disc: rdrobust in P2 minus rdrobust in the control
* period. Fixed h=20k (as in Part 2), triangular kernel, no FE. The SE of the
* difference treats the two periods as independent samples.
* SIGN: rdrobust reports ABOVE − BELOW, the opposite of below×post in reghdfe,
* so flip the sign to compare (e.g. DiD = −0.27 on direct ≈ FS of +0.27).

di as text _n "--- rdrobust cross-check (diff-in-disc, P2 − $CTRL_G) ---"
foreach var in direct days_award lratio {
    local cond "has_award == 1"
    if "`var'" == "direct" local cond "1"

    * RD in P2
    capture rdrobust `var' xr if period == 2 & pnrr == 0 & `cond', ///
        h(20000) kernel(triangular) masspoints(off)
    if !_rc {
        local rd_p2 = e(tau_cl)
        local se_p2 = e(se_tau_cl)
    }
    else {
        local rd_p2 = .
        local se_p2 = .
    }

    * RD in the control period
    capture rdrobust `var' xr if ${g_CTRL} & pnrr == 0 & `cond', ///
        h(20000) kernel(triangular) masspoints(off)
    if !_rc {
        local rd_c = e(tau_cl)
        local se_c = e(se_tau_cl)
    }
    else {
        local rd_c = .
        local se_c = .
    }

    local did = `rd_p2' - `rd_c'
    local se_did = sqrt(`se_p2'^2 + `se_c'^2)
    di as text "  `var': P2=" %7.4f `rd_p2' " $CTRL_G=" %7.4f `rd_c' ///
        " DiD=" %7.4f `did' " SE=" %7.4f `se_did'
    * stored as below − above (sign flipped), like below×post
    if !missing(`did') rpost Mrob rdrobust `var', manual b(`=-`did'') se(`se_did')
}

* ---- 4.6i: Alternative control period ----
* WHY? Showing the main estimates with the other control period lets the
* reader judge how much the choice of control period matters.
* P1b is closer in time (less room for other changes); P0 has ~3x more lots.

di as text _n "--- Alternative control period: $ALT_G vs P2 (h=40k) ---"
foreach var in direct days_award lratio single_bid nbids {
    local cond "has_award == 1"
    if "`var'" == "direct" local cond "1"
    capture reghdfe `var' i.below##i.post##c.x [aw=kw40] ///
        if alt_sample == 1 & abs(x) <= 40000 & `cond', ///
        absorb(cpv2_post region_post ym) vce(cluster authority_id)
    if !_rc {
        di as text "  `var' ($ALT_G control): " %8.4f _b[1.below#1.post] ///
            " (" %7.4f _se[1.below#1.post] ")" ///
            "  p=" %6.4f 2*ttail(e(df_r), abs(_b[1.below#1.post]/_se[1.below#1.post])) ///
            "  N=" e(N)
        rpost Mrob altctrl `var'
    }
}

* ---- 4.6j: Excluding central authorities ----
* WHY? Part 2 found a jump in direct award at 139k for central authorities in
* P1b (+7.7pp, 95% CI [0.5, 14.9], section 2.3), possibly because the EU
* threshold for central government was €139k (note in section 1.3). If so,
* 139k was already a procedural cutoff for them before P2. Dropping them
* removes that channel.
* (Chosen from the Part 2 diagnostics, before P1b outcomes were estimated.)

di as text _n "--- Excluding central authorities (h=40k) ---"
foreach var in direct days_award lratio single_bid nbids {
    local cond "has_award == 1"
    if "`var'" == "direct" local cond "1"
    capture reghdfe `var' i.below##i.post##c.x [aw=kw40] ///
        if main_sample == 1 & central == 0 & abs(x) <= 40000 & `cond', ///
        absorb(cpv2_post region_post ym) vce(cluster authority_id)
    if !_rc {
        di as text "  `var' (no central): " %8.4f _b[1.below#1.post] ///
            " (" %7.4f _se[1.below#1.post] ")" ///
            "  p=" %6.4f 2*ttail(e(df_r), abs(_b[1.below#1.post]/_se[1.below#1.post])) ///
            "  N=" e(N)
        rpost Mrob nocentral `var'
    }
}

* ---- 4.6k: Round values at the placebo cutoffs ----
* Lots at exactly a round value are a different kind of lot (faster to
* award). (i) Mean days at exactly c vs other lots within ±15k (P2, awarded);
* (ii) the placebo jumps in days without any lot at a multiple of €5,000.
gen byte _r5 = (mod(importo_lotto, 5000) == 0) if !missing(importo_lotto)
foreach c in 100000 160000 200000 {
    local ck = `c'/1000
    summarize days_award if period == 2 & pnrr == 0 & has_award == 1 & importo_lotto == `c', meanonly
    dpost p2_days_at_`ck'k `r(mean)'
    summarize days_award if period == 2 & pnrr == 0 & has_award == 1 & importo_lotto != `c' ///
        & abs(importo_lotto - `c') <= 15000, meanonly
    dpost p2_days_near_`ck'k `r(mean)'
}
foreach c in 100000 120000 160000 200000 {
    local ck = `c'/1000
    local h = 15000
    if `c' == 200000 local h = 10000
    local side "importo_lotto < 139000"
    if `c' > 139000 local side "importo_lotto > 139000"
    gen float x_plac = importo_lotto - `c'
    gen byte below_plac = (importo_lotto < `c')
    gen float kw_plac = max(0, 1 - abs(x_plac)/`h') if abs(x_plac) <= `h'
    quietly reghdfe days_award i.below_plac##c.x_plac [aw=kw_plac] ///
        if period == 2 & pnrr == 0 & abs(x_plac) <= `h' & `side' & has_award == 1 & _r5 == 0, ///
        absorb(cpv2 region ym) vce(cluster authority_id)
    rpost Mplac c`ck'_nor5 days_award, coef(1.below_plac)
    drop x_plac below_plac kw_plac
}
foreach g in P1b P0 {
    quietly reghdfe days_award i.below##c.x [aw=kw40] ///
        if ${g_`g'} & pnrr == 0 & abs(x) <= 40000 & has_award == 1 & _r5 == 0, ///
        absorb(cpv2 region ym) vce(cluster authority_id)
    rpost Mplac p139_`g'_nor5 days_award, coef(1.below)
}
drop _r5

* RESULTS 4.6 (h=40k unless stated; below×post coefficients):
*                       days      lratio          single_bid
*   main               −52.3     +0.075 (0.030)   +0.148
*   donut 1k           −51.6     +0.083 (0.029)   +0.138
*   donut 2.5k         −40.2     +0.074 (0.033)   +0.138
*   donut 5k           −32.0     +0.050 (0.040)   +0.107
*   local quadratic    −55.2     +0.052 (0.042)   +0.149
*   province cluster   −52.3 (11.0)  +0.075 (0.030)  +0.148 (0.025); 131 clusters
*   with PNRR          −51.8     +0.076 (0.029)   +0.151
*   no lots at 139,000 −51.2     +0.073 (0.030)   +0.145   (FS 0.434)
*   strict (<139k)     −37.9     +0.046 (0.028)   +0.098   (FS 0.276)
*   P0 control         −44.2     +0.043 (0.019)   +0.104   (FS 0.432)
*   no central auth.   −51.3     +0.068 (0.032)   +0.153   (FS 0.398)
*   rdrobust P2 − P1b (h=20k, no FE, sign flipped): direct +0.52 (0.02),
*   days −66.1 (16.4), lratio +0.069 (0.039).
* Placebos: in P2 at 100k/120k/160k/200k the jump in direct is ≤0.035, but
* days jumps at 100k (+10.3), 160k (+23.2) and 200k (+19.4); at 139k days
* jumps in P1b (+23.5, SE 9.9) and P0 (+15.5, SE 4.7); direct does not
* (−0.019, −0.016). Lots at exact round values are faster (39 vs 62
* days at €100,000; 4.6k) and all sit on one side of these cutoffs; without
* multiples of €5k (4.6k) the days jumps are +4.4 at 100k, +16.6 at 160k,
* +9.8 at 200k, +10.8 at 139k in P1b and +15.8 at 139k in P0. Because
* this round-number pattern is present before and after the reform, the
* diff-in-disc subtracts it.
* SUMMARY: the first stage and days are robust everywhere (days shrinks
* with wider donuts: the effect is concentrated in lots just below 139k,
* the ones Part 3 shows bunching). single_bid is robust but largely
* mechanical. lratio is the fragile outcome: it loses significance with a
* 5k donut, a local quadratic, and at h=20k.


* ==============================================================================
* 4.7  VALUE-BAND DiD
* ==============================================================================
* An entirely DIFFERENT design that doesn't rely on local polynomial fitting.
*
* IDEA: Compare lots in the 100–130k band (which became eligible for direct
* award in P2 but were not in the control period: P1b limit €75k, P0 limit
* €40k) with lots in the 150–180k band (which always required competitive
* procedures, both before and after the reform).
*
* This is a standard DiD: treat (100–130k) × post (P2 vs control period). If
* the results match the RD findings, two designs point the same way.
*
* The event study by semester tests PARALLEL TRENDS: the treat and control
* bands should behave identically before the reform and diverge after.
* Semesters are aligned to 1 Jun 2021 (rel_sem, section 1.3). Reference:
* rel_sem = $ES_REF (last semester entirely in the control period).
* P1a lots are dropped from the event study (in P1a the 100–130k band was
* direct-eligible up to the EU threshold, so it was partly "treated"), and P3
* lots too (different regime).
*
* CAVEAT: the bands do not hold the same lots before and after. Part 3 shows
* that the reform moved lots INTO the treated band (from below €75k and from
* above €139k): it has 958 lots/month in P1b vs 1,442 in P2 (+50%), while
* the control band goes from 546 to 496 (-9%; computed below). So this DiD compares
* changing populations; it is a supporting check, not the main estimate.

di as text _n "========================================"
di as text    "  4.7: VALUE-BAND DiD"
di as text    "========================================"

gen byte treat_band = .
replace treat_band = 1 if importo_lotto >= 100000 & importo_lotto < 130000
replace treat_band = 0 if importo_lotto >= 150000 & importo_lotto < 180000

di as text _n "--- Main DiD ($CTRL_G vs P2) ---"
foreach var in days_award lratio single_bid nbids direct {
    local cond "has_award == 1"
    if "`var'" == "direct" local cond "1"

    capture reghdfe `var' c.treat_band#c.post treat_band post ///
        if main_sample == 1 & !missing(treat_band) & `cond', ///
        absorb(cpv2 region ym) vce(cluster authority_id)
    if !_rc {
        di as text "  `var': " %8.4f _b[c.treat_band#c.post] ///
            " (" %7.4f _se[c.treat_band#c.post] ")" ///
            "  N=" e(N)
        rpost Mrob vband `var', coef(c.treat_band#c.post)
        estimates store vband_`var'
    }
}

* ---- Event study ----
di as text _n "--- Event study (value-band DiD by semester, ref = $ES_REF) ---"

local ref = $ES_REF

levelsof rel_sem if !missing(treat_band) & pnrr == 0 & p1a == 0 & period != 3 ///
    & year(pub_date) >= 2018, local(hys)

tempfile es_results
postfile es_handle rel_sem coef_days se_days coef_lratio se_lratio using `es_results'

foreach hy of local hys {
    if `hy' == `ref' {
        post es_handle (`hy') (0) (0) (0) (0)
        continue
    }

    gen byte hy_dum = (rel_sem == `hy')

    quietly {
        capture reghdfe days_award c.treat_band#c.hy_dum treat_band hy_dum ///
            if inlist(rel_sem, `hy', `ref') & !missing(treat_band) & pnrr == 0 ///
            & p1a == 0 & period != 3 & has_award == 1, ///
            absorb(cpv2 region) vce(cluster authority_id)
        if !_rc {
            local cd = _b[c.treat_band#c.hy_dum]
            local sd = _se[c.treat_band#c.hy_dum]
        }
        else {
            local cd = .
            local sd = .
        }

        capture reghdfe lratio c.treat_band#c.hy_dum treat_band hy_dum ///
            if inlist(rel_sem, `hy', `ref') & !missing(treat_band) & pnrr == 0 ///
            & p1a == 0 & period != 3 & has_award == 1, ///
            absorb(cpv2 region) vce(cluster authority_id)
        if !_rc {
            local cl = _b[c.treat_band#c.hy_dum]
            local sl = _se[c.treat_band#c.hy_dum]
        }
        else {
            local cl = .
            local sl = .
        }
    }

    post es_handle (`hy') (`cd') (`sd') (`cl') (`sl')
    di as text "  sem " %3.0f `hy' ": days=" %7.2f `cd' " (" %5.2f `sd' ")" ///
        "  lratio=" %7.4f `cl' " (" %5.4f `sl' ")"
    drop hy_dum
}
postclose es_handle

preserve
use `es_results', clear
export delimited using "results/tables/M6_event_study${SFX}.csv", replace

gen float ci_lo_d = coef_days - 1.96 * se_days
gen float ci_hi_d = coef_days + 1.96 * se_days

twoway (rcap ci_lo_d ci_hi_d rel_sem, lcolor(navy%50)) ///
    (scatter coef_days rel_sem, mcolor(navy) msize(medium)), ///
    xline(-0.5, lcolor(cranberry) lpattern(solid) lwidth(medthick)) ///
    yline(0, lcolor(gs8) lpattern(dot)) ///
    xtitle("Semester relative to 1 Jun 2021 (0 = Jun-Nov 2021)") ytitle("DiD estimate: days_award") ///
    title("Value-band DiD: speed") ///
    note("Treat: 100-130k, Control: 150-180k. Ref: semester $ES_REF. P1a and P3 lots excluded") ///
    legend(off) graphregion(color(white))
graph export "results/figures/M6_es_days${SFX}.png", width(2000) replace

* Same plot for price (lratio), which is estimated above but was not plotted.
gen float ci_lo_l = coef_lratio - 1.96 * se_lratio
gen float ci_hi_l = coef_lratio + 1.96 * se_lratio

twoway (rcap ci_lo_l ci_hi_l rel_sem, lcolor(navy%50)) ///
    (scatter coef_lratio rel_sem, mcolor(navy) msize(medium)), ///
    xline(-0.5, lcolor(cranberry) lpattern(solid) lwidth(medthick)) ///
    yline(0, lcolor(gs8) lpattern(dot)) ///
    xtitle("Semester relative to 1 Jun 2021 (0 = Jun-Nov 2021)") ytitle("DiD estimate: lratio") ///
    title("Value-band DiD: price") ///
    note("Treat: 100-130k, Control: 150-180k. Ref: semester $ES_REF. P1a and P3 lots excluded") ///
    legend(off) graphregion(color(white))
graph export "results/figures/M6_es_lratio${SFX}.png", width(2000) replace
restore

* Lots per month in each band, control period vs P2 (CAVEAT above)
foreach g in CTRL P2 {
    local cond = cond("`g'" == "CTRL", "${g_CTRL}", "period == 2")
    levelsof ym if main_sample == 1 & `cond', local(_months)
    local nm : word count `_months'
    foreach b in 1 0 {
        count if main_sample == 1 & `cond' & treat_band == `b'
        dpost lots_per_month_`g'_band`b' `=r(N)/`nm''
    }
}

* RESULTS 4.7 (P1b vs P2, bands 100–130k vs 150–180k):
*   direct +0.301 (0.011), days −14.0 (4.2), lratio +0.030 (0.015),
*   single_bid +0.050 (0.014), nbids +0.83 (0.84, n.s.).
* Same signs as the RD, smaller sizes (the bands cover lots far from the
* cutoff, and the band populations change; see CAVEAT above).
* Event study (ref = semester −1): days pre-reform between −8.5 and +8.2,
* none significant; post −21.6, −11.6, −8.7, −11.8, −15.7. lratio:
* pre-reform coefficients are all negative (−0.008 to −0.043) and drift up
* towards 0 before the reform; post ≈ 0 to +0.06, none significant. So the
* band design supports the days result but gives no clean evidence on price.

* Clean up Module M temporary variables (the IV helpers are rebuilt in Part 5)
drop x2 below_post below_x post_x below_post_x treat_band prov_cl province_id


* ==============================================================================
* 4.8  PROCESS RED FLAGS: AWARD CRITERION, BID WINDOW, EVALUATION TIME
* ==============================================================================
* WHY? ANAC's corruption-risk indicators for procurement ("Indicatori di
* rischio corruttivo negli appalti", ANAC 2022, 17 indicators; copy in
* data/raw/law/ANAC_indicatori_rischio_corruttivo_appalti.pdf) include three
* that our data can measure lot by lot:
*   ind. 1  MEAT criterion (offerta economicamente più vantaggiosa): more
*           discretion than lowest price, so a proxy for risk;
*   ind. 14 days from publication to the bid deadline (a very short window
*           makes it hard for firms without inside information to bid);
*   ind. 15 days from the bid deadline to the award (very fast evaluation may
*           hide decisions taken in advance).
* ANAC computes them PER PROVINCE (shares or average days) and flags provinces
* above the 75th percentile. It uses NO day cut-offs. Here we use the
* lot-level versions in the main diff-in-disc (same specification
* as 4.2: h = 40k, triangular kernel, CPV2×post, region×post and month FE,
* SEs clustered by authority, non-PNRR, awarded lots).
*
* HOW TO READ THEM:
* - Under direct award there is no public tender, so the "bid deadline" is a
*   date set in the request to the chosen firm and the criterion is a form
*   field. Differences at the cutoff partly describe the procedure itself
*   (like single_bid in 4.2), not necessarily more or less risk.
* - days_award (4.2) = bid_window + eval_days exactly, lot by lot. Estimated
*   on the same lots, the two ITTs add up to the days_award ITT, so they show
*   WHERE the faster award comes from (shorter window vs faster evaluation).
*   bid_window is reported for this split, not as a red flag on its own.

di as text _n "========================================"
di as text    "  4.8: PROCESS RED FLAGS"
di as text    "========================================"

* ---- Award criterion (ANAC indicator 1) ----
* criterio_aggiudicazione (from aggiudicazioni, kept in 1.8). Values in the
* data: "OFFERTA ECONOMICAMENTE PIÙ VANTAGGIOSA: MIGLIOR RAPPORTO QUALITÀ /
* PREZZO" and ": COMPETIZIONE SOLO IN BASE A CRITERI QUALITATIVI" (MEAT),
* ": CRITERIO DEL MINOR PREZZO" (= lowest price, despite the prefix), the
* older plain "OFFERTA ECONOMICAMENTE PIU' VANTAGGIOSA" (MEAT) and "PREZZO PIU'
* BASSO" (lowest price), or blank. Blank = missing: 18% of awarded lots in the
* ±40k window, 34% of direct awards (computed below). Because blanks are more common under
* direct award, crit_recorded (criterion filled in) is estimated too, as a
* selection check for meat.
gen str200 _crit = ustrupper(criterio_aggiudicazione)
gen byte crit_recorded = (_crit != "") if has_award == 1
label var crit_recorded "Award criterion recorded (awarded lots)"
summarize crit_recorded if main_sample == 1 & abs(x) <= 40000, meanonly
dpost window_share_criterion_blank `=1 - r(mean)'
summarize crit_recorded if main_sample == 1 & abs(x) <= 40000 & direct == 1, meanonly
dpost window_direct_share_criterion_blank `=1 - r(mean)'
gen byte meat = .
replace meat = 1 if strpos(_crit, "MIGLIOR RAPPORTO") > 0
replace meat = 1 if strpos(_crit, "CRITERI QUALITATIVI") > 0
replace meat = 1 if _crit == "OFFERTA ECONOMICAMENTE PIU' VANTAGGIOSA"
replace meat = 0 if strpos(_crit, "MINOR PREZZO") > 0
replace meat = 0 if strpos(_crit, "PREZZO PIU") > 0
replace meat = . if has_award != 1
label var meat "MEAT award criterion (ANAC ind. 1)"
di as text _n "  Coding check: every non-blank criterion must be coded 0/1"
tab _crit meat if has_award == 1, m
count if has_award == 1 & _crit != "" & missing(meat)
assert r(N) == 0
drop _crit

* ---- Bid window (ANAC ind. 14) and evaluation time (ANAC ind. 15) ----
* deadline_date comes from data_scadenza_offerta (1.5); missing for 0.2% of
* lots. NOT cleaned, like days_award: eval_days < 0 (award dated before the
* bid deadline) for 10.7% of awarded lots in the window (4.9), mostly direct
* awards; cleaned versions are estimated in 4.9.
gen int bid_window = deadline_date - pub_date if has_award == 1
gen int eval_days  = award_date - deadline_date if has_award == 1
label var bid_window "Days publication -> bid deadline (ANAC ind. 14)"
label var eval_days  "Days bid deadline -> award (ANAC ind. 15)"
gen byte _nodl = missing(deadline_date)
summarize _nodl, meanonly
dpost share_lots_no_deadline `r(mean)'
drop _nodl
* Identity check: the two parts add up to days_award
count if has_award == 1 & !missing(bid_window, eval_days) ///
    & days_award != bid_window + eval_days
assert r(N) == 0

* ---- Descriptives: means by period and side of 139k (±40k, awarded) ----
gen str4 _grp = cond(period == 2, "P2", "$CTRL_G") if main_sample == 1
table _grp below if main_sample == 1 & abs(x) <= 40000 & has_award == 1, ///
    stat(mean crit_recorded meat bid_window eval_days days_award) nformat(%7.3f)

* ---- ITT and LATE ----
* Same specification as 4.2 (ITT) and 4.3 (LATE). The split of days_award
* uses the lots where both parts are observed (sample flag split_ok), so
* ITT(bid_window) + ITT(eval_days) = ITT(days_award) on that sample exactly
* (same regressors, weights and sample; OLS is linear in the outcome).
gen byte split_ok = !missing(bid_window, eval_days)
gen float below_post = below * post
gen float below_x = below * x
gen float post_x = post * x
gen float below_post_x = below * post * x

tempname rf
tempfile rf_res
postfile `rf' str14 outcome str4 est int h double b se p N using `rf_res'

foreach var in crit_recorded meat days_award bid_window eval_days {
    local cond "has_award == 1"
    if inlist("`var'", "days_award", "bid_window", "eval_days") ///
        local cond "has_award == 1 & split_ok == 1"

    * ITT at h = 40k, and 20k / 60k for meat and eval_days
    local hs "40000"
    if inlist("`var'", "meat", "eval_days") local hs "20000 40000 60000"
    foreach h of local hs {
        capture drop kw_h
        gen float kw_h = max(0, 1 - abs(x)/`h') if abs(x) <= `h'
        capture reghdfe `var' i.below##i.post##c.x [aw=kw_h] ///
            if main_sample == 1 & abs(x) <= `h' & `cond', ///
            absorb(cpv2_post region_post ym) vce(cluster authority_id)
        if !_rc {
            local b = _b[1.below#1.post]
            local s = _se[1.below#1.post]
            local p = 2*ttail(e(df_r), abs(`b'/`s'))
            di as text "  ITT `var' (h=" `h'/1000 "k): " %8.4f `b' ///
                " (" %7.4f `s' ")  p=" %6.4f `p' "  N=" e(N)
            post `rf' ("`var'") ("ITT") (`h'/1000) (`b') (`s') (`p') (e(N))
            local hk = `h'/1000
            local rr = cond(`h' == 40000, "main", "h`hk'")
            rpost Mflag `rr' `var'
            if `h' == 40000 cstore rf_itt_`var' `var'
        }
        drop kw_h
    }

    * LATE at h = 40k (direct instrumented by below × post), as in 4.3
    capture ivreghdfe `var' below post x below_x post_x below_post_x ///
        (direct = below_post) [aw=kw40] ///
        if main_sample == 1 & abs(x) <= 40000 & `cond', ///
        absorb(cpv2_post region_post ym) cluster(authority_id)
    if !_rc {
        local b = _b[direct]
        local s = _se[direct]
        local p = 2*ttail(e(df_r), abs(`b'/`s'))
        di as text "  LATE `var': " %8.3f `b' " (" %7.3f `s' ")  p=" %6.4f `p' ///
            "  KP F=" %6.1f e(widstat) "  N=" e(N)
        post `rf' ("`var'") ("LATE") (40) (`b') (`s') (`p') (e(N))
        rpost Mflag late `var', coef(direct) extra(`e(widstat)')
        estimates store rf_iv_`var'
    }
}
postclose `rf'

preserve
use `rf_res', clear
list, noobs abbrev(14) sep(0)
export delimited using "results/tables/M8_red_flags${SFX}.csv", replace
restore

* RESULTS 4.8 (main run; P1b control, h = 40k, awarded lots):
*                    ITT                         LATE
*   crit_recorded   −0.117 (0.020)  p<0.001     −0.26
*   meat            −0.107 (0.027)  p<0.001     −0.26   [h=20k −0.076 (0.035),
*                                                         60k −0.119 (0.021)]
*   days_award      −52.3  (10.7)               −119    (same as 4.2)
*   = bid_window    −15.4  (2.8)    p<0.001     −35
*   + eval_days     −36.8  (10.3)   p<0.001     −84     [h=20k −40.7 (18.0),
*                                                         60k −31.5 (7.5)]
* Raw means, P2, ±40k: MEAT 0.27 below vs 0.40 above (P1b 0.39 vs 0.41);
* evaluation 36 vs 64 days (P1b 62 vs 65); window 17 vs 25 days (P1b 24 vs 23).
* HOW TO READ THEM:
* - Faster award: about 30% of the −52 days is a shorter bid window and 70%
*   faster evaluation. Both are what a direct award is (one firm, no tender
*   to assess), so read them as how the time is saved, not as evidence of
*   pre-arranged decisions.
* - MEAT falls by 11 pp: on ANAC's indicator 1 that is LOWER risk. But the
*   criterion is a form field under direct award, and it is recorded less
*   often below the cutoff (crit_recorded −0.117), so the meat sample is
*   selected. It is at most weak evidence about discretion.

drop below_post below_x post_x below_post_x _grp split_ok


* ==============================================================================
* 4.9  OUTCOME CLEANING: ROBUSTNESS ONLY
* ==============================================================================
* WHY? Some outcomes contain values that cannot be right or that are coded in
* a way that mixes two things:
*   (a) negative days to award (award dated before publication);
*   (b) negative bid window or evaluation time (deadline before publication,
*       award before the deadline), mostly under direct award, where the
*       "deadline" is a date in the request to the chosen firm;
*   (c) zero admitted bids coded as single bid (single_bid = nbids <= 1);
*   (d) extreme price ratios (log award/base from −15 to +6.9).
* WHAT: count each problem in the main window, then re-estimate the affected
* outcomes on cleaned versions. The main specification uses the outcomes as
* recorded; these are extra robustness rows. Cleaning rules:
*   days_award        drop lots with days_award < 0
*   bid_window, eval  drop lots where either part is < 0 (split sample of 4.8)
*   single_bid        missing when nbids == 0 (no admitted bid recorded)
*   lratio            (i) trim: drop lots outside the 1st–99th percentile of
*                     the awarded window sample; (ii) winsorize at the same
*                     percentiles.
* Nominal values: the cutoff itself is nominal (€139,000 in the law), so lot
* values stay nominal; the price ratio has no unit. No deflation is needed
* for these estimates.

di as text _n "========================================"
di as text    "  4.9: OUTCOME CLEANING (ROBUSTNESS)"
di as text    "========================================"

local W "main_sample == 1 & abs(x) <= 40000 & has_award == 1"

* ---- (1) How many lots are affected (main window, awarded lots) ----
* bid_window and eval_days were built in 4.8 (awarded lots)
gen int _bwin = bid_window
gen int _eval = eval_days
quietly count if `W'
global CL_N = r(N)
quietly count if `W' & days_award < 0
global CL_negdays = r(N)
quietly count if `W' & !missing(_bwin, _eval)
global CL_Nsplit = r(N)
quietly count if `W' & !missing(_bwin, _eval) & _bwin < 0
global CL_negbw = r(N)
quietly count if `W' & !missing(_bwin, _eval) & _eval < 0
global CL_negev = r(N)
quietly count if `W' & !missing(nbids)
global CL_Nbids = r(N)
quietly count if `W' & nbids == 0
global CL_zerobids = r(N)
quietly _pctile lratio if `W', percentiles(1 99)
local lr_p1 = r(r1)
local lr_p99 = r(r2)
global CL_lrp1 = `lr_p1'
global CL_lrp99 = `lr_p99'
quietly count if `W' & !missing(lratio)
global CL_Nlr = r(N)
quietly count if `W' & !missing(lratio) & (lratio < `lr_p1' | lratio > `lr_p99')
global CL_lrtrim = r(N)
di as text "  Awarded lots in the window: $CL_N"
di as text "  (a) days_award < 0: $CL_negdays"
di as text "  (b) of $CL_Nsplit with both parts: bid window < 0: $CL_negbw; evaluation < 0: $CL_negev"
di as text "  (c) of $CL_Nbids with nbids recorded: nbids == 0: $CL_zerobids"
di as text "  (d) lratio 1st / 99th percentile: " %6.3f `lr_p1' " / " %6.3f `lr_p99' ///
    "; outside: $CL_lrtrim of $CL_Nlr"
* The same counts by period and side, to see where the problems sit
gen str4 _grp = cond(period == 2, "P2", "$CTRL_G") if main_sample == 1
gen byte _negd = (days_award < 0) if `W' & !missing(days_award)
gen byte _negsplit = (_bwin < 0 | _eval < 0) if `W' & !missing(_bwin, _eval)
gen byte _zerob = (nbids == 0) if `W' & !missing(nbids)
table _grp below if `W', stat(mean _negd _negsplit _zerob) nformat(%6.4f)

* ---- (2) Cleaned outcomes ----
gen float days_c   = days_award if days_award >= 0
gen byte  split_c  = !missing(_bwin, _eval) & _bwin >= 0 & _eval >= 0
gen byte  single_c = single_bid if nbids != 0
gen float lratio_t = lratio if inrange(lratio, `lr_p1', `lr_p99')
gen float lratio_w = min(max(lratio, `lr_p1'), `lr_p99') if !missing(lratio)

* ---- (3) Main and cleaned estimates side by side (same specification) ----
local RD "i.below##i.post##c.x [aw=kw40]"
local A  "absorb(cpv2_post region_post ym) vce(cluster authority_id)"
* main rows (repeated here so that the table compares like with like)
quietly reghdfe days_award `RD' if `W', `A'
rpost Mclean main days_award
quietly reghdfe _bwin `RD' if `W' & !missing(_bwin, _eval), `A'
rpost Mclean main bid_window
quietly reghdfe _eval `RD' if `W' & !missing(_bwin, _eval), `A'
rpost Mclean main eval_days
quietly reghdfe single_bid `RD' if `W', `A'
rpost Mclean main single_bid
quietly reghdfe lratio `RD' if `W', `A'
rpost Mclean main lratio
* cleaned rows
quietly reghdfe days_c `RD' if `W', `A'
rpost Mclean clean days_award
quietly reghdfe _bwin `RD' if `W' & split_c == 1, `A'
rpost Mclean clean bid_window
quietly reghdfe _eval `RD' if `W' & split_c == 1, `A'
rpost Mclean clean eval_days
quietly reghdfe single_c `RD' if `W', `A'
rpost Mclean clean single_bid
quietly reghdfe lratio_t `RD' if `W', `A'
rpost Mclean clean lratio
quietly reghdfe lratio_w `RD' if `W', `A'
rpost Mclean wins lratio
di as text "  Main vs cleaned (below × post):"
foreach v in days_award bid_window eval_days single_bid lratio {
    di as text "    `v'  (see results/tables/coefficients${SFX}.csv, table Mclean)"
}

* counts table for the report
capture mkdir "results/tables/tex"
tempname cf
file open `cf' using "results/tables/tex/I_cleaning_counts${SFX}.tex", write replace
file write `cf' "Award dated before publication & " %9.0fc ($CL_negdays) " & " %9.0fc ($CL_N) ///
    " & " %5.1f (100*$CL_negdays/$CL_N) "\% \\" _n
file write `cf' "Bid deadline before publication & " %9.0fc ($CL_negbw) " & " %9.0fc ($CL_Nsplit) ///
    " & " %5.1f (100*$CL_negbw/$CL_Nsplit) "\% \\" _n
file write `cf' "Award before the bid deadline & " %9.0fc ($CL_negev) " & " %9.0fc ($CL_Nsplit) ///
    " & " %5.1f (100*$CL_negev/$CL_Nsplit) "\% \\" _n
file write `cf' "Zero admitted bids (coded as single bid) & " %9.0fc ($CL_zerobids) " & " %9.0fc ($CL_Nbids) ///
    " & " %5.1f (100*$CL_zerobids/$CL_Nbids) "\% \\" _n
file write `cf' "Log price ratio outside [" %5.2f ($CL_lrp1) ", " %4.2f ($CL_lrp99) "] & " ///
    %9.0fc ($CL_lrtrim) " & " %9.0fc ($CL_Nlr) " & " %5.1f (100*$CL_lrtrim/$CL_Nlr) "\% \\" _n
file close `cf'

drop _bwin _eval _grp _negd _negsplit _zerob days_c split_c single_c lratio_t lratio_w


* ==============================================================================
* 4.10  ARE LOTS ON THE TWO SIDES STILL COMPARABLE? BALANCE TEST
* ==============================================================================
* WHY? Part 3 shows that after the reform authorities moved lot values to
* just below €139k. So in P2 the lots just below are partly a SORTED group:
* the design assumes that, without the reform, outcomes would change smoothly
* at the cutoff, and sorting can break that if the lots (or authorities) that
* move below differ from those that stay above. The diff-in-disc removes
* differences that already existed in P1b, not sorting that appears only in
* P2. A direct check: estimate the same diff-in-disc on characteristics that
* are fixed before the award and cannot respond to the procedure. A jump in
* them means the two sides differ in composition after the reform.
* COVARIATES (all lots in the window, as for the first stage):
*   central     central authority
*   south       authority in the South and islands
*   services    services (vs supplies)
*   cpv33       medical equipment and supplies (CPV division 33)
*   lauth_prev  log(1 + lots the authority published in the previous
*               calendar year): size and experience of the buyer
*   pdays       predicted days to award: days_award regressed on the
*               covariates above plus CPV2 and region dummies in the control
*               period (awarded lots in the window), predicted for every lot.
*               One summary index of "lots that are usually fast".
* SPECIFICATION: as 4.1 but with year-month FE only (CPV2 × post and region
* × post FE would absorb the covariates themselves). Columns: diff-in-disc
* (P2 vs control) and the discontinuity in P2 alone (same weights).
* Rows "without lots at 139,000" repeat the test without the heap.
* It is a check, not a new specification.

di as text _n "========================================"
di as text    "  4.10: BALANCE TEST"
di as text    "========================================"

* Authority size: lots published in the previous calendar year
gen int _yr = year(pub_date)
preserve
keep authority_id _yr
contract authority_id _yr, freq(auth_lots_prev)
replace _yr = _yr + 1
tempfile alots
save `alots'
restore
merge m:1 authority_id _yr using `alots', keep(master match) nogen
replace auth_lots_prev = 0 if missing(auth_lots_prev)
gen float lauth_prev = ln(1 + auth_lots_prev)

gen _regname = subinstr(region, "SEZIONE REGIONALE ", "", .)
gen byte south = inlist(_regname, "ABRUZZO", "MOLISE", "CAMPANIA", "PUGLIA", ///
    "BASILICATA", "CALABRIA", "SICILIA", "SARDEGNA")
gen byte services = (oggetto_principale_contratto == "SERVIZI")
capture confirm numeric variable cpv2
if !_rc gen byte cpv33 = (cpv2 == 33)
else    gen byte cpv33 = (cpv2 == "33")
egen _cpvn = group(cpv2)
egen _regn = group(region)

* Predicted days (fit in the control period, awarded lots in the window)
quietly regress days_award central south services lauth_prev i._cpvn i._regn ///
    if ${g_CTRL} & main_sample == 1 & abs(x) <= 40000 & has_award == 1
di as text "  Prediction model for days: R2 = " %5.3f e(r2) "  N = " e(N)
predict float pdays if main_sample == 1 & abs(x) <= 40000, xb

local S "main_sample == 1 & abs(x) <= 40000"
foreach v in central south services cpv33 lauth_prev pdays {
    quietly reghdfe `v' i.below##i.post##c.x [aw=kw40] if `S', ///
        absorb(ym) vce(cluster authority_id)
    rpost Mbal `v' did
    local b1 = _b[1.below#1.post]
    local s1 = _se[1.below#1.post]
    quietly reghdfe `v' i.below##i.post##c.x [aw=kw40] if `S' & importo_lotto != 139000, ///
        absorb(ym) vce(cluster authority_id)
    rpost Mbal `v' did_no139
    quietly reghdfe `v' i.below##c.x [aw=kw40] if `S' & period == 2, ///
        absorb(ym) vce(cluster authority_id)
    rpost Mbal `v' p2, coef(1.below)
    di as text "  `v': diff-in-disc " %8.4f `b1' " (" %7.4f `s1' ")" ///
        "   P2 alone " %8.4f _b[1.below] " (" %7.4f _se[1.below] ")"
}
* Means in the control period below the cutoff, for scale
tabstat central south services cpv33 lauth_prev pdays ///
    if `S' & ${g_CTRL} & below == 1, stat(mean) format(%7.3f)

* FOLLOW-UP to the balance test: the
* sector and region covariates are already absorbed by the main FE
* (CPV2 × post, region × post); the authority's size is not. Two extra
* robustness rows for the main Part I outcomes: (i) adding lauth_prev as a
* control; (ii) adding AUTHORITY fixed effects, so each authority's lots
* below the cutoff are compared with its own lots above (removes any sorting
* of authorities across the cutoff; singletons are dropped by reghdfe).
foreach v in direct days_award lratio single_bid {
    local cond "has_award == 1"
    if "`v'" == "direct" local cond "1"
    quietly reghdfe `v' i.below##i.post##c.x lauth_prev [aw=kw40] if `S' & `cond', ///
        absorb(cpv2_post region_post ym) vce(cluster authority_id)
    rpost Mrob ctrlsize `v'
    quietly reghdfe `v' i.below##i.post##c.x [aw=kw40] if `S' & `cond', ///
        absorb(cpv2_post region_post ym authority_id) vce(cluster authority_id)
    rpost Mrob authfe `v'
    di as text "  `v' with authority FE: " %8.4f _b[1.below#1.post] " (" %7.4f _se[1.below#1.post] ")  N = " e(N)
}

drop _yr auth_lots_prev lauth_prev _regname south services cpv33 _cpvn _regn pdays

* RESULTS 4.9--4.10 (main run, P1b control):
* 4.9 awarded window N = 53,598: 2,102 negative days; 5,720 award before the
*   deadline; 570 zero bids; 1,070 lratio outside [-1.88, 0.16]. Cleaned: days
*   -43.2 (6.6), bid window -15.7, evaluation -31.4, single bid 0.152, lratio
*   trimmed 0.050 (0.018), winsorized 0.065 (0.020).
* 4.10 diff-in-disc on pre-determined characteristics: central -0.131 (P2 alone
*   -0.004: the gap comes from P1b), South -0.049, services +0.123, CPV 33
*   -0.105, log authority lots -0.297, predicted days -5.1 (p<0.10). Sorting on
*   observables after the reform; sector and region are absorbed by the main FE.
*   Authority FE: FS 0.315, days -37.1 (7.0), single bid 0.114, lratio 0.047;
*   implied effect per switched lot about -118 days, as in the main estimate.


* ##############################################################################
* ##############################################################################
* ##                                                                          ##
* ##   PART 5: COMPETITION AND SUPPLIER ROTATION (Module C)                   ##
* ##                                                                          ##
* ##   Tests whether direct award changes WHO wins the contract               ##
* ##                                                                          ##
* ##############################################################################
* ##############################################################################


* ==============================================================================
* 5.1  IMPORT AGGIUDICATARI (WINNING FIRMS)
* ==============================================================================
* The aggiudicatari file identifies WHO won each contract. We need this to
* build "repeat winner" and "new supplier" variables.

di as text _n "========================================"
di as text    "  5.1: IMPORTING AGGIUDICATARI"
di as text    "========================================"

* Check if already processed
capture confirm file "data/intermediate/aggiudicatari_v2.dta"
if _rc {
    preserve

    import delimited using "data/raw/aggiudicatari_csv.csv", ///
        delimiter(";") stringcols(_all) clear
    rename *, lower
    di as text "  Raw rows: " _N

    * Keep winners only. The "ruolo" field identifies the firm's role:
    *   "" (blank) = single supplier
    *   "MANDATARIA" = lead firm in a consortium
    *   "OPERATORE ECONOMICO MONOSOGGETTIVO" = single economic operator
    * We exclude "MANDANTE" (junior consortium member) and other roles.
    keep if inlist(ruolo, "", "MANDATARIA", "Mandataria", ///
        "OPERATORE ECONOMICO MONOSOGGETTIVO", ///
        "Operatore Economico monosoggettivo")
    di as text "  After role filter: " _N

    * A codice_fiscale of "" or "." is not a firm. Kept, all such lots would
    * look like one supplier in the history variables (8 awarded lots, 2018–
    * 2023). The network build (net_py/net_phase0_data.py) drops them too.
    drop if inlist(strtrim(codice_fiscale), "", ".")
    di as text "  After dropping blank/'.' codes: " _N

    keep cig codice_fiscale denominazione id_aggiudicazione

    * Deduplicate: one winner per CIG. Keep the award record with the highest
    * id_aggiudicazione. NOTE: section 1.8 picks the award record by the most
    * recent award_date first, then id; the two rules pick different records
    * for 187 of 4.8 million CIGs and for 2 lots in the estimation window
    * (computed in 5.2). Some award records list several winners (e.g.
    * framework agreements with several operators). We
    * keep one; ties are broken by codice_fiscale so the choice is the same on
    * every rebuild (before, it depended on the sort order of the import).
    destring id_aggiudicazione, replace force
    gsort cig -id_aggiudicazione codice_fiscale
    by cig: keep if _n == 1
    di as text "  Unique CIG-winner pairs: " _N

    save "data/intermediate/aggiudicatari_v2.dta", replace
    restore
}
else {
    di as text "  aggiudicatari_v2.dta already exists — skipping import"
}


* ==============================================================================
* 5.2  MERGE WINNERS TO LOTS AND BUILD HISTORY VARIABLES
* ==============================================================================
* We merge winners to lots_v2.dta, then for each lot, look BACKWARD in time
* to count prior contracts between the same authority and firm.

di as text _n "========================================"
di as text    "  5.2: BUILDING FIRM-AUTHORITY HISTORY"
di as text    "========================================"

use "data/intermediate/lots_v2.dta", clear

* Keep only awarded lots for the merge
keep if has_award == 1
capture drop id_aggiudicazione
sort cig
merge 1:1 cig using "data/intermediate/aggiudicatari_v2.dta", ///
    keep(master match) gen(_m_winners)
di as text "  Matched winners: " %12.0fc _N " awarded lots with aggiudicatari"
tab _m_winners
keep if _m_winners == 3
drop _m_winners

* WHAT COUNTS AS A "PRIOR" CONTRACT: only contracts published on an EARLIER
* day. When one firm wins several lots from the same authority on the same day
* (typically several lots of one tender), those lots are not prior contracts
* of each other. Counting same-day lots as "prior" would make 11.7% of the
* lots in the ±40k window look like repeat contracts, and that share changes
* at the cutoff (multi-lot awards are rarer among direct awards below 139k),
* so it would bias the diff-in-disc. The data have
* no tender identifier (numero_gara is not imported in 1.1), so "same day,
* same authority, same firm" is the closest proxy for "same tender".
*
* COVERAGE: the history contains only lots with an award record and a matched
* winner (55% of lots in the window; computed below). A pair can have earlier contracts that were never
* recorded, so new_supplier overstates how new the firm is; the diff-in-disc
* removes this only if coverage is the same just below and just above 139k
* (coverage DiD vs P1b +0.033, n.s., section 2.2).

* Sort chronologically for lookback calculations
sort authority_id codice_fiscale pub_date cig

* _first = position (within the pair) of the first lot published on this
* lot's day, so _first − 1 = number of the pair's lots on EARLIER days.
by authority_id codice_fiscale: gen long _idx = _n
by authority_id codice_fiscale pub_date: gen long _first = _idx[1]

* ---- CUMULATIVE CONTRACT COUNT (tie_strength) ----
* For each lot, count how many contracts the same authority–firm pair had on
* earlier days.
by authority_id codice_fiscale: gen tie_strength = _first - 1
label var tie_strength "Prior contracts, earlier days (auth × firm)"

* ---- NEW SUPPLIER ----
* = 1 if the pair has no contract on any earlier day (since Jan 2018).
gen byte new_supplier = (tie_strength == 0)
label var new_supplier "No earlier-day contract (auth × firm)"

* ---- REPEAT WINNER (24-month lookback) ----
* = 1 if the same authority–firm pair had at least one contract in the prior
* 24 months. This captures recent incumbency, not just any historical tie.
* LEFT-CENSORING: the lot history starts in Jan 2018. P1b lots (from Sep 2020)
* have a full 24-month lookback; P0 lots published before 2020 do not — one
* more reason to prefer P1b as control. new_supplier and tie_strength look
* back to Jan 2018 for every lot, so they are censored for all periods (less
* so for later lots); the diff-in-disc removes this only if the censoring is
* the same just below and just above 139k.
* _prevd = date of the pair's most recent contract on an earlier day: the lot
* just before the first lot of this day.
by authority_id codice_fiscale: gen double _prevd = pub_date[_first - 1] if _first > 1
gen byte repeat_winner_24m = !missing(_prevd) & (pub_date - _prevd) <= 730
label var repeat_winner_24m "Same auth-firm pair, earlier-day contract in prior 24m"
drop _idx _first _prevd

* ---- REPEAT WINNER (same CPV3 group) ----
* Same as above, but restricted to lots in the same broad product category
* (first 3 characters of CPV code, e.g. "331" = medical devices).
gen cpv3 = substr(cod_cpv, 1, 3)
sort authority_id codice_fiscale cpv3 pub_date cig
by authority_id codice_fiscale cpv3: gen long _idx = _n
by authority_id codice_fiscale cpv3 pub_date: gen long _first = _idx[1]
by authority_id codice_fiscale cpv3: gen double _prevd = pub_date[_first - 1] if _first > 1
gen byte repeat_winner_cpv = !missing(_prevd) & (pub_date - _prevd) <= 730
label var repeat_winner_cpv "Same auth-firm-CPV3, earlier-day contract in prior 24m"
drop _idx _first _prevd

* ---- NEW TO ALL PUBLIC PROCUREMENT (market-wide new firm) ----
* = 1 if the winning firm won NO contract from ANY authority, in any sector,
* on an earlier day within the prior 12 (24) months.
* It is broader than new_supplier (new to THIS authority) and than Part 7's
* "new to the market" (no award in the same CPV2 market in 24 months).
* Same earlier-day rule as above, so a firm's several lots on its first day
* all count as new. History = awarded lots with a matched winner since Jan
* 2018 (all lot values), so the 24-month version is left-censored for lots
* before Jan 2020 (all of P0; P1b starts Sep 2020, so it is complete).
sort codice_fiscale pub_date cig
by codice_fiscale: gen long _idx = _n
by codice_fiscale pub_date: gen long _first = _idx[1]
by codice_fiscale: gen double _prevd = pub_date[_first - 1] if _first > 1
gen byte new_firm_12m = missing(_prevd) | (pub_date - _prevd) > 365
gen byte new_firm_24m = missing(_prevd) | (pub_date - _prevd) > 730
label var new_firm_12m "Firm won no contract anywhere in prior 12m (earlier days)"
label var new_firm_24m "Firm won no contract anywhere in prior 24m (earlier days)"
drop _idx _first _prevd
* Back to the unique sort order used above, so the row order of the saved
* file does not depend on this block.
sort authority_id codice_fiscale cpv3 pub_date cig

* Save the lots-with-winners dataset
compress
save "data/intermediate/lots_winners.dta", replace

* Facts quoted in 5.1–5.2 (lots with a winner):
* (a) lots in the ±40k window (control + P2, non-PNRR) with a same-day lot of
*     the same authority–firm pair listed before them (multi-lot awards)
sort authority_id codice_fiscale pub_date cig
by authority_id codice_fiscale pub_date: gen byte _sameday_pred = (_n > 1)
gen byte _win = (${g_CTRL} | period == 2) & !(flag_pnrr_pnc == "1" | flag_pnrr_pnc == "SI") ///
    & abs(x) <= 40000
summarize _sameday_pred if _win, meanonly
dpost window_share_sameday_pred `r(mean)'
count if _win
local n_w = r(N)
drop _sameday_pred _win
sort authority_id codice_fiscale cpv3 pub_date cig
* (b) share of window lots that have a winner (history coverage)
preserve
use x period p1b flag_pnrr_pnc using "data/intermediate/lots_v2.dta", clear
count if (${g_CTRL} | period == 2) & !(flag_pnrr_pnc == "1" | flag_pnrr_pnc == "SI") & abs(x) <= 40000
dpost window_share_with_winner `=`n_w'/r(N)'
restore
* (c) award-record choice: 1.8 (latest award date, then id) vs 5.1 (highest id)
preserve
use cig id_aggiudicazione using "data/intermediate/aggiudicazioni_v2.dta", clear
capture destring id_aggiudicazione, replace force
rename id_aggiudicazione _id18
merge 1:1 cig using "data/intermediate/aggiudicatari_v2.dta", keepusing(id_aggiudicazione) keep(match) nogen
dpost n_cig_with_award_and_winner `=_N'
count if _id18 != id_aggiudicazione
dpost n_cig_award_rule_differs `r(N)'
keep if _id18 != id_aggiudicazione
keep cig
merge 1:1 cig using "data/intermediate/lots_v2.dta", keepusing(x period p1b flag_pnrr_pnc) keep(match) nogen
count if (${g_CTRL} | period == 2) & !(flag_pnrr_pnc == "1" | flag_pnrr_pnc == "SI") & abs(x) <= 40000
dpost n_window_award_rule_differs `r(N)'
restore

di as text "  lots_winners.dta: " _N " rows"
di as text _n "  Summary statistics of competition variables:"
summarize repeat_winner_24m repeat_winner_cpv new_supplier tie_strength new_firm_12m new_firm_24m

* RESULTS (main run): 622,401 awarded lots with a matched winner
* (99.98% of awarded lots). Means: repeat_winner_24m 0.37, repeat_winner_cpv
* 0.31, new_supplier 0.58, tie_strength 4.3 (max 428).


* ==============================================================================
* 5.3  LOT-LEVEL DiD-RD ON COMPETITION OUTCOMES
* ==============================================================================
* Same specification as Module M (section 4.2), but with competition outcomes.
* Sample: control period ($CTRL_G) vs P2, non-PNRR, awarded lots with matched
* winners, |x| ≤ 40k.

di as text _n "========================================"
di as text    "  5.3: LOT-LEVEL DiD-RD (COMPETITION)"
di as text    "========================================"

* Recreate the variables we need (they are in lots_v2, not in lots_winners)
capture drop pnrr
gen byte pnrr = (flag_pnrr_pnc == "1" | flag_pnrr_pnc == "SI")
capture drop main_sample
gen byte main_sample = (${g_CTRL} | period == 2) & pnrr == 0

capture drop kw40
gen float kw40 = max(0, 1 - abs(x)/40000) if abs(x) <= 40000

* FE group variables
capture drop cpv2_post
capture drop region_post
capture drop ym
capture drop post
capture drop below_post

gen byte post = (period == 2)
egen cpv2_post = group(cpv2 post)
egen region_post = group(region post)
gen ym = ym(year(pub_date), month(pub_date))
gen float below_post = below * post
gen float below_x = below * x
gen float post_x = post * x
gen float below_post_x = below * post * x

* ---- ITT ----
di as text _n "--- ITT (h=40k) ---"
foreach var in repeat_winner_24m repeat_winner_cpv new_supplier tie_strength new_firm_12m new_firm_24m {
    capture reghdfe `var' i.below##i.post##c.x [aw=kw40] ///
        if main_sample == 1 & abs(x) <= 40000, ///
        absorb(cpv2_post region_post ym) vce(cluster authority_id)
    if !_rc {
        di as text "  `var': " %8.4f _b[1.below#1.post] ///
            " (" %7.4f _se[1.below#1.post] ")" ///
            " p=" %6.4f 2*ttail(e(df_r), abs(_b[1.below#1.post]/_se[1.below#1.post]))
        rpost Crob main `var'
        cstore c_itt_`var' `var'
    }
}

* ---- Fuzzy IV / LATE ----
di as text _n "--- IV / LATE (h=40k) ---"
foreach var in repeat_winner_24m repeat_winner_cpv new_supplier tie_strength new_firm_12m new_firm_24m {
    capture ivreghdfe `var' below post x below_x post_x below_post_x ///
        (direct = below_post) [aw=kw40] ///
        if main_sample == 1 & abs(x) <= 40000, ///
        absorb(cpv2_post region_post ym) cluster(authority_id)
    if !_rc {
        di as text "  `var' LATE: " %8.4f _b[direct] ///
            " (" %7.4f _se[direct] ")" ///
            " KP F=" %6.1f e(widstat) ///
            " p=" %6.4f 2*ttail(e(df_r), abs(_b[direct]/_se[direct]))
        rpost Crob late `var', coef(direct) extra(`e(widstat)')
        estimates store c_iv_`var'
    }
}

* ---- Bandwidth robustness ----
di as text _n "--- Bandwidth robustness ---"
foreach var in repeat_winner_24m repeat_winner_cpv new_supplier new_firm_12m new_firm_24m {
    di as text "  `var':"
    foreach h in 20000 30000 60000 {
        local hk = `h'/1000
        capture drop kw_h
        gen float kw_h = max(0, 1 - abs(x)/`h') if abs(x) <= `h'
        capture reghdfe `var' i.below##i.post##c.x [aw=kw_h] ///
            if main_sample == 1 & abs(x) <= `h', ///
            absorb(cpv2_post region_post ym) vce(cluster authority_id)
        if !_rc {
            di as text "    h=`hk'k: " %8.4f _b[1.below#1.post] ///
                " (" %7.4f _se[1.below#1.post] ")"
            rpost Crob h`hk' `var'
        }
        drop kw_h
    }
}

* ---- Placebo: 139k in the pre-reform periods ----
* No pre-existing discontinuity at 139k for competition variables?
foreach g in P1b P0 {
    di as text _n "--- Placebo: 139k in `g' ---"
    foreach var in repeat_winner_24m repeat_winner_cpv new_supplier new_firm_12m new_firm_24m {
        capture reghdfe `var' i.below##c.x [aw=kw40] ///
            if ${g_`g'} & pnrr == 0 & abs(x) <= 40000, ///
            absorb(cpv2 region ym) vce(cluster authority_id)
        if !_rc {
            di as text "  `var' (`g'): " %8.4f _b[1.below] " (" %7.4f _se[1.below] ")"
            rpost Crob p139_`g' `var', coef(1.below)
        }
    }
}

* ---- Alternative control period ----
capture drop alt_sample
gen byte alt_sample = (${g_ALT} | period == 2) & pnrr == 0
di as text _n "--- ITT with $ALT_G as control (h=40k) ---"
foreach var in repeat_winner_24m repeat_winner_cpv new_supplier new_firm_12m new_firm_24m {
    capture reghdfe `var' i.below##i.post##c.x [aw=kw40] ///
        if alt_sample == 1 & abs(x) <= 40000, ///
        absorb(cpv2_post region_post ym) vce(cluster authority_id)
    if !_rc {
        di as text "  `var' ($ALT_G control): " %8.4f _b[1.below#1.post] ///
            " (" %7.4f _se[1.below#1.post] ")" ///
            " p=" %6.4f 2*ttail(e(df_r), abs(_b[1.below#1.post]/_se[1.below#1.post]))
        rpost Crob altctrl `var'
    }
}

* ---- Authority fixed effects (follow-up to the balance test of 4.10):
* compares each authority's lots below and above 139k,
* so sorting of authorities across the cutoff cannot drive the result ----
di as text _n "--- ITT with authority fixed effects (h=40k) ---"
foreach var in new_supplier new_firm_12m new_firm_24m repeat_winner_24m repeat_winner_cpv {
    capture reghdfe `var' i.below##i.post##c.x [aw=kw40] ///
        if main_sample == 1 & abs(x) <= 40000, ///
        absorb(cpv2_post region_post ym authority_id) vce(cluster authority_id)
    if !_rc {
        di as text "  `var' (authority FE): " %8.4f _b[1.below#1.post] ///
            " (" %7.4f _se[1.below#1.post] ")  N=" e(N)
        rpost Crob authfe `var'
    }
}

* RESULTS 5.3 (P1b control, h=40k, awarded lots with winner; FS 0.44, KP F 456):
*                       ITT                 p      LATE
*   repeat_winner_24m   −0.042 (0.025)    0.092   −0.096
*   repeat_winner_cpv   −0.043 (0.024)    0.071   −0.098
*   new_supplier        +0.056 (0.025)    0.025   +0.128
*   tie_strength        −2.02 (0.70)      0.004   −4.58
* Bandwidths 20/30/60k: repeat_24m −0.051/−0.048/−0.031; new_supplier
* +0.065/+0.063/+0.048. Placebos at 139k in P1b and P0: all |coef| ≤ 0.02,
* n.s. With P0 as control: repeat_24m −0.046 (0.017), repeat_cpv −0.053
* (0.017), new_supplier +0.060 (0.017), all p < 0.01.
* READING: lots that became direct-eligible are somewhat more often won by a
* firm with no earlier contract with that authority (about +6 pp, +13 pp for
* compliers). The repeat-winner effect has the same sign but is borderline
* with P1b as control.
* NEW TO ALL PUBLIC PROCUREMENT (see 5.2):
*                       ITT                 p      LATE    mean
*   new_firm_12m        +0.045 (0.018)    0.011   +0.103   0.26
*   new_firm_24m        +0.044 (0.017)    0.009   +0.099   0.21
* Bandwidths 20/30/60k: 12m +0.029 (0.025, n.s.)/+0.045/+0.045; 24m +0.043
* (0.023)/+0.044/+0.048. Placebos at 139k: P1b −0.020 (0.016), −0.013
* (0.014); P0 −0.006, −0.009; all n.s. With P0 as control: +0.031 (0.013,
* p = 0.020), +0.040 (0.013, p = 0.001).
* READING: lots that became direct-eligible go about 4.5 pp more often to a
* firm with no public contract anywhere in the past one or two years (+10 pp
* for compliers). Same size as Part 7's "new to the market" (+0.050), so the
* opening is not only toward firms new to one authority.
* Rotation principle: it applies below the EU thresholds on both sides of
* the cutoff (art. 36(1) D.Lgs 50/2016), to awards under direct award and to
* invitations under the negotiated procedure; this difference in form is a
* possible legal channel for this result.


* ==============================================================================
* 5.4  AUTHORITY-LEVEL CONCENTRATION (CONTINUOUS DiD)
* ==============================================================================
* This asks: does the reform change concentration at the AUTHORITY level?
* The lot-level results (5.3) show whether new suppliers win more often.
* But does this translate into lower supplier CONCENTRATION for the authority?
*
* DESIGN: Panel of authority × semester (rel_sem, aligned to 1 Jun 2021),
* control period + P2 only. Exposure = authority's share of control-period
* lots in the band that became direct-eligible in P2: €75k–139k when the
* control is P1b (below €75k was already direct), €40k–139k when it is P0.
* More-exposed authorities should see more of their lots shift to direct award.
* The panel is restricted to control + P2 so pre and post are the two
* compared regimes.
*
* NOTE: n_lots below counts FIRM cells (one row per firm per authority-
* semester after the dedup), not lots; new_share is the share of those firms
* that are new to the authority.
*
* HOW TO READ THE HHI RESULT (numbers computed below):
* (1) Lot-count mechanism. After the reform, more-exposed authorities publish
*     more lots (log lots × exposure × post +0.25, SE 0.07). With more lots
*     there are more firms, so HHI falls mechanically: holding log lots fixed
*     the HHI effect is -0.004 (0.015). The lot count is itself affected by
*     the reform, so that is not the right estimate either, but it shows the
*     HHI result means "more, smaller contracts", not necessarily a less
*     concentrated supplier base.
* (2) Pre-reform gap. Exposure × semester −2 (Sep–Nov 2020, before the
*     reform; reference = semester −1) is -0.065 (0.046), as large as the
*     post-reform coefficients (−0.06 to −0.12).
* (3) Exposure is measured on the SAME control-period lots that form the
*     pre-reform HHI, which can create such a gap. It is also noisy: half of
*     the authorities have ≤ 6 control-period lots.
* (4) Partial semesters: −2 has only 2.5 months of P1b and 4 only June 2023.

di as text _n "========================================"
di as text    "  5.4: AUTHORITY-LEVEL CONCENTRATION"
di as text    "========================================"

use "data/intermediate/lots_winners.dta", clear

capture drop pnrr
gen byte pnrr = (flag_pnrr_pnc == "1" | flag_pnrr_pnc == "SI")

* Exposure from control-period lots
preserve
keep if ${g_CTRL}
gen byte in_band = (importo_lotto >= $BAND_LO & importo_lotto <= 139000)
collapse (mean) exposure = in_band (count) n_ctrl_lots = in_band, by(authority_id)
tempfile exposure
save `exposure'
restore

* Build authority × semester panel (control period + P2)
gen float award_value = importo_aggiudicazione if has_award == 1

preserve
keep if (${g_CTRL} | period == 2) & pnrr == 0 & has_award == 1

* Compute supplier HHI per authority × semester
* HHI = sum of squared FIRM-level value shares (not lot-level)
bysort authority_id rel_sem codice_fiscale: egen firm_value = total(importo_aggiudicazione)
bysort authority_id rel_sem: egen total_value = total(importo_aggiudicazione)
gen float firm_share = firm_value / total_value if total_value > 0
gen float firm_share_sq = firm_share^2

* Keep one row per firm per authority-semester cell before collapsing.
* WHICH row? The firm's EARLIEST lot in the cell (by publication date, then
* CIG). So new_share = share of the cell's firms that were new to the
* authority at their first lot of the semester. Same-day lots of a pair share
* the same new_supplier value (5.2 counts only earlier days), so this equals
* "new at any lot of the semester".
* WHY sort by (pub_date cig)? Without a sort order inside the cell Stata
* keeps an arbitrary lot and new_share depends on row order. supplier_hhi is
* the same on every row of a firm, so it does not depend on this choice.
bysort authority_id rel_sem: gen long _nlots_cell = _N
bysort authority_id rel_sem codice_fiscale (pub_date cig): keep if _n == 1

gen byte _one = 1
collapse (sum) supplier_hhi=firm_share_sq ///
    (mean) new_share=new_supplier ///
    (sum) n_lots=_one (first) n_lots_all=_nlots_cell, ///
    by(authority_id rel_sem)

gen byte post = (rel_sem >= 0)

* Merge exposure
merge m:1 authority_id using `exposure', keep(match) nogen

* Keep authorities with ≥10 firm cells (for stable HHI estimates)
bysort authority_id: egen total_lots = total(n_lots)
keep if total_lots >= 10

di as text "  Panel size: " _N " authority × semester obs"

* Regression: exposure × post
* The interaction is built by hand. WHY? With c.exposure#i.post and no main
* effect, Stata keeps BOTH levels (exposure×0.post and exposure×1.post); they
* sum to exposure, which the authority FE absorbs, and reghdfe then drops the
* LAST level (1.post) — the coefficient of interest came out as 0 (0) in the
* 7 Nov run. exp_post = exposure × post has no such problem: exposure alone is
* absorbed by the authority FE, post by the semester FE.
gen float exp_post = exposure * post

capture reghdfe supplier_hhi exp_post, ///
    absorb(authority_id rel_sem) cluster(authority_id)
if !_rc {
    * The coefficient on exposure × post is the DiD estimate
    di as text "  HHI: exposure × post = " %7.4f _b[exp_post] ///
        " (" %7.4f _se[exp_post] ")  N = " e(N)
    rpost Cconc supplier_hhi all, coef(exp_post)
}

capture reghdfe new_share exp_post, ///
    absorb(authority_id rel_sem) cluster(authority_id)
if !_rc {
    di as text "  new_share: exposure × post = " %7.4f _b[exp_post] ///
        " (" %7.4f _se[exp_post] ")  N = " e(N)
    rpost Cconc new_share all, coef(exp_post)
}

* Facts used in HOW TO READ THE HHI RESULT:
* (0) panel size, authorities, exposure
dpost panel_cells `=_N'
egen byte _tagA = tag(authority_id)
count if _tagA
dpost panel_authorities `r(N)'
summarize exposure if _tagA, detail
dpost panel_exposure_mean `r(mean)'
dpost panel_exposure_median `r(p50)'
summarize n_ctrl_lots if _tagA, detail
dpost panel_median_ctrl_lots `r(p50)'
drop _tagA
* (1) lot-count mechanism: log lots per cell on exposure × post, and the HHI
*     effect holding log lots fixed
gen float ln_lots_all = ln(n_lots_all)
quietly reghdfe ln_lots_all exp_post, absorb(authority_id rel_sem) cluster(authority_id)
rpost Cconc ln_lots all, coef(exp_post)
quietly reghdfe supplier_hhi exp_post ln_lots_all, absorb(authority_id rel_sem) cluster(authority_id)
rpost Cconc supplier_hhi_given_lnlots all, coef(exp_post)
* (2) pre-reform gap: exposure × semester event study for the HHI
levelsof rel_sem, local(_sems)
local _es ""
foreach t of local _sems {
    if `t' == $ES_REF continue
    local nm = cond(`t' < 0, "m" + string(abs(`t')), "p" + string(`t'))
    gen float hes_`nm' = exposure * (rel_sem == `t')
    local _es "`_es' hes_`nm'"
}
quietly reghdfe supplier_hhi `_es', absorb(authority_id rel_sem) cluster(authority_id)
foreach v of local _es {
    rpost Cconc hhi_`v' all, coef(`v')
}
drop ln_lots_all hes_*

* RESULTS 5.4 (18,909 authority × semester cells, 18,907 in the regressions;
* 3,231 authorities; mean exposure 0.15, median 0.10): HHI exposure × post −0.071 (0.026);
* new_share +0.096 (0.025). Going from zero exposure to the mean exposure
* lowers HHI by about 0.011. See HOW TO READ THE HHI RESULT above: this is
* mostly "more, smaller contracts per exposed authority", and there is a
* pre-reform gap, so it is weak evidence of lower concentration.

restore


* ==============================================================================
* 5.4b  CONCENTRATION THAT DOES NOT DEPEND ON THE NUMBER OF LOTS
* ==============================================================================
* PROBLEM WITH 5.4: an HHI computed on all of a cell's contracts falls
* mechanically when the authority awards more contracts (more lots → more
* distinct firms), and exposed authorities did award more lots after the
* reform. So 5.4 cannot tell "less concentrated suppliers" from "more lots".
*
* IDEA: compare HHIs computed on the SAME number of contracts in every cell.
* Drawing k random contracts per cell is noisy; here we use the exact
* version of that idea instead:
*   S = probability that two DIFFERENT contracts of the cell, picked at
*       random, went to the same firm = Σ_j n_j(n_j − 1) / (n(n − 1)),
*   where n_j = contracts won by firm j in the cell, n = all contracts.
* WHY S? For any fixed k, the expected count-HHI of k contracts drawn at
* random (without replacement) from the cell is exactly 1/k + (1 − 1/k)·S
* (hypergeometric algebra). So S is the fixed-size HHI with no simulation
* noise, uses every contract, and does not move with n when contracts are
* drawn from the same supplier distribution. A coefficient on S times
* (1 − 1/k) is the coefficient for the HHI of k contracts (0.8 for k = 5).
* NOTE: S and hhi_count count CONTRACTS; supplier_hhi in 5.4 weights by
* award value. hhi_count (all contracts, by count) is reported to separate
* the count-vs-value difference from the fixed-size correction.
*
* Same panel as 5.4: control period + P2, non-PNRR, awarded lots, authority
* × semester cells, exposure from 5.4, authorities with ≥ 10 firm cells,
* FE authority and semester, SEs clustered by authority. S needs n ≥ 2.
* CHECK: random draws (k = 5 contracts per cell, cells with n ≥ 5), repeated
* 50 times; the average coefficient should be close to 0.8 × the S
* coefficient on the same cells.
* PRE-TREND: exposure × semester (reference $ES_REF), as for 5.4.

di as text _n "========================================"
di as text    "  5.4b: FIXED-SIZE CONCENTRATION"
di as text    "========================================"

preserve
keep if (${g_CTRL} | period == 2) & pnrr == 0 & has_award == 1
keep authority_id rel_sem codice_fiscale cig

* Lot-level copy for the random-draw check
tempfile lots_cells
save `lots_cells'

* Contracts per firm (n_j) and per cell (n), one row per firm in the cell
bysort authority_id rel_sem: gen long n_c = _N
bysort authority_id rel_sem codice_fiscale: gen long n_j = _N
bysort authority_id rel_sem codice_fiscale: keep if _n == 1
gen double _pairs = n_j * (n_j - 1)
gen double _sq    = n_j^2
gen byte _one = 1
collapse (sum) pairs=_pairs sq=_sq n_firms=_one (first) n_lots=n_c, ///
    by(authority_id rel_sem)
gen double hhi_count = sq / n_lots^2
gen double same_firm = pairs / (n_lots * (n_lots - 1)) if n_lots >= 2
label var hhi_count "Count HHI, all contracts of the cell"
label var same_firm "S: P(two different contracts, same firm)"

* Same authorities and cells as 5.4 (≥ 10 firm cells over the panel)
merge m:1 authority_id using `exposure', keep(match) nogen
bysort authority_id: egen total_fc = total(n_firms)
keep if total_fc >= 10
gen byte post = (rel_sem >= 0)
gen float exp_post = exposure * post
di as text "  Panel: " _N " authority × semester cells (5.4: 18,907); cells with n >= 2 and n >= 5:"
count if n_lots >= 2
count if n_lots >= 5
summarize hhi_count same_firm n_lots

tempname hb
tempfile hb_res
postfile `hb' str24 outcome str16 cells double b se p N using `hb_res'

* Rows: hhi_count on all cells (like 5.4, by count instead of value) and on
* cells with n >= 2; S on cells with n >= 2 (main) and n >= 5 (the cells of
* the random-draw check).
foreach var in hhi_count same_firm {
    foreach c in "1" "2" "5" {
        if "`var'" == "hhi_count" & "`c'" == "5" continue
        if "`var'" == "same_firm" & "`c'" == "1" continue
        capture reghdfe `var' exp_post if n_lots >= `c', ///
            absorb(authority_id rel_sem) cluster(authority_id)
        if !_rc {
            local b = _b[exp_post]
            local s = _se[exp_post]
            local p = 2*ttail(e(df_r), abs(`b'/`s'))
            di as text "  `var' (cells n>=`c'): exposure × post = " %7.4f `b' ///
                " (" %6.4f `s' ")  p=" %6.4f `p' "  N=" e(N)
            post `hb' ("`var'") ("n>=`c'") (`b') (`s') (`p') (e(N))
            rpost Cconc `var' n`c', coef(exp_post)
        }
    }
}

* ---- Pre-trend: exposure × semester, reference $ES_REF ----
levelsof rel_sem, local(sems)
local es_vars ""
foreach s of local sems {
    if `s' == $ES_REF continue
    local nm = cond(`s' < 0, "m" + string(abs(`s')), "p" + string(`s'))
    gen float es_`nm' = exposure * (rel_sem == `s')
    local es_vars "`es_vars' es_`nm'"
}
capture reghdfe same_firm `es_vars' if n_lots >= 2, ///
    absorb(authority_id rel_sem) cluster(authority_id)
if !_rc {
    di as text "  Event study, S (reference semester $ES_REF):"
    foreach v of local es_vars {
        di as text "    `v': " %7.4f _b[`v'] " (" %6.4f _se[`v'] ")"
        post `hb' ("same_firm ES `v'") ("n>=2") (_b[`v']) (_se[`v']) ///
            (2*ttail(e(df_r), abs(_b[`v']/_se[`v']))) (e(N))
        rpost Cconc S_`v' n2, coef(`v')
    }
}

* Cells kept for the random-draw check (n >= 5, same authorities)
keep if n_lots >= 5
keep authority_id rel_sem exposure exp_post
tempfile cells5
save `cells5'

* ---- Check: random draws, k = 5, 50 repetitions ----
tempname dr
tempfile dr_res
postfile `dr' int rep double b using `dr_res'
set seed 20261113
forvalues r = 1/50 {
    use `lots_cells', clear
    merge m:1 authority_id rel_sem using `cells5', keep(match) nogen
    * Fixed row order before drawing. WHY? merge sorts by cell and Stata
    * orders rows within a cell at random, so without this line the same seed
    * gives different draws in every run (−0.0172 and −0.0154 in two runs).
    sort authority_id rel_sem cig
    gen double _u = runiform()
    bysort authority_id rel_sem (_u): keep if _n <= 5
    bysort authority_id rel_sem codice_fiscale: gen double _s2 = (_N / 5)^2 if _n == 1
    collapse (sum) hhi5 = _s2 (first) exp_post, by(authority_id rel_sem)
    quietly reghdfe hhi5 exp_post, absorb(authority_id rel_sem) cluster(authority_id)
    post `dr' (`r') (_b[exp_post])
}
postclose `dr'
use `dr_res', clear
summarize b
di as text "  Random draws (k=5, 50 reps): mean " %7.4f r(mean) ///
    ", SD across draws " %6.4f r(sd) ", min " %7.4f r(min) ", max " %7.4f r(max)
* In the output table this row's "se" column holds the SD ACROSS DRAWS (how
* much a single draw can move the estimate) and
* "N" the number of draws.
post `hb' ("hhi5 random draws (mean)") ("n>=5") (r(mean)) (r(sd)) (.) (r(N))
postclose `hb'

use `hb_res', clear
list, noobs abbrev(24) sep(0)
export delimited using "results/tables/C4b_concentration_fixed_size${SFX}.csv", replace
restore

* RESULTS 5.4b (main run, P1b control; 18,909 cells as in 5.4,
* 15,601 with n >= 2, 8,911 with n >= 5; mean S 0.036, mean count HHI 0.38):
*   count HHI, all cells        −0.113 (0.028)   [5.4 value HHI: −0.071]
*   count HHI, cells n >= 2     −0.050 (0.019)
*   S (fixed size), n >= 2      −0.038 (0.018)  p = 0.040   ← main
*   S (fixed size), n >= 5      −0.018 (0.016)  p = 0.26
*   random draws k = 5 (n >= 5), mean of 50: −0.013 (SD across draws 0.008;
*     predicted 0.8 × −0.018 = −0.015)
*   event study for S (ref. semester −1): −2: +0.018 (0.041); 0: −0.063
*     (0.023); 1: −0.027; 2: −0.030; 3: −0.033 (all n.s.); 4 (June 2023
*     only): +0.035 (0.036).
* HOW TO READ IT:
* - Most of the 5.4 HHI fall is the number of lots: by count, −0.113 on all
*   cells shrinks to −0.038 once the measure no longer depends on n.
* - What remains is small: at the mean exposure (0.16), S falls by about
*   0.006, i.e. two contracts of an exposed authority are slightly less
*   often won by the same firm (about −16% of the mean 0.036). For the HHI of
*   5 contracts that is −0.030 × 0.15 ≈ −0.005.
* - It is fragile: not significant on cells with ≥ 5 contracts, and driven by
*   the first post-reform semester. Unlike 5.4, there is no pre-reform gap
*   (semester −2: +0.018, SE 0.041).
* - A single draw of 5 contracts would give anything between about −0.03
*   and 0 here (SD across draws 0.008), so it cannot be read on its own.


* ==============================================================================
* 5.5  MARKET-LEVEL CONCENTRATION (DESCRIPTIVE)
* ==============================================================================
* Markets = CPV3 × province × year. Most local procurement markets are very
* thin (median 2 lots/year), so DiD on market concentration has low power.
* We report descriptive statistics only.
*
* Lots with a blank provincia (34% of lots_winners; computed below) are dropped: kept, they
* formed pseudo-markets of 10,000+ lots per CPV3 × year (e.g. CPV 336,
* pharmaceuticals) that are not local markets. new_auth_share is the share of
* lots won by a firm with no earlier-day contract with THAT AUTHORITY; it is
* not entry into the market (the old name market_entry suggested that).

di as text _n "========================================"
di as text    "  5.5: MARKET-LEVEL DESCRIPTIVES"
di as text    "========================================"

use "data/intermediate/lots_winners.dta", clear

gen cpv3_mkt = substr(cod_cpv, 1, 3)
gen byte _noprov = (provincia == "")
summarize _noprov, meanonly
dpost lots_winners_share_blank_province `r(mean)'
drop _noprov

preserve
keep if has_award == 1 & provincia != ""

* Compute HHI per market cell
gen pub_year = year(pub_date)
bysort cpv3_mkt provincia pub_year: egen mkt_total = total(importo_aggiudicazione)
gen float mkt_share = importo_aggiudicazione / mkt_total if mkt_total > 0
gen float mkt_share_sq = mkt_share^2
gen byte _one = 1
collapse (sum) market_hhi=mkt_share_sq ///
    (mean) new_auth_share=new_supplier ///
    (sum) n_lots=_one, ///
    by(cpv3_mkt provincia pub_year)

di as text "  Market cells: " _N
summarize market_hhi n_lots new_auth_share, detail

* RESULTS 5.5 (all years, blank province dropped): 50,277 market cells
* (CPV3 × province × year). Lots per cell: median 2, 75th pct 5, 99th pct
* 102, max 2,486. HHI: median 0.62, mean 0.64; at least a quarter of cells
* have HHI = 1 (one winner). Share of lots won by a firm new to that
* authority: median 1, mean 0.76. Markets this thin give a market-level
* DiD little power, which is why it is descriptive only.

restore

* ##############################################################################
* ##############################################################################
* ##                                                                          ##
* ##   PART 6: SPEED OF ADJUSTMENT TO THE NEW REGIME (Module S)               ##
* ##                                                                          ##
* ##   How fast did authorities switch to direct award in the newly eligible  ##
* ##   band, overall, by region and by sector?                                ##
* ##                                                                          ##
* ##############################################################################
* ##############################################################################
*
* WHY? The first stage is not instantaneous. In the band that became direct-
* eligible in P2 (€75k–€139k when the control is P1b), the direct-award share
* went from ~15% to ~60%, but part of the move happened at once and part over
* the following year. Measuring that speed (i) shows how the first stage builds
* up over time, and (ii) gives a region/sector variable for later
* heterogeneity analysis.
*
* MEASURE. For each month we take the GAP in direct-award share between the
* newly eligible band (BAND_LO, 139k] and a comparison band (139k, 180k] that
* stayed competitive. Using the gap (not the raw share) removes general trends
* in direct-award use that hit both bands. The share of the adjustment
* completed at month m is
*     closed(m) = [gap(m) − gap(control period)] / [gap(long run) − gap(control period)]
* with the long run = months 12–21 after the reform (Jun 2022 – Mar 2023).
* Months 22–24 (Apr–Jun 2023) are dropped: the new Code (D.Lgs. 36/2023) was
* already published and took effect on 1 Jul 2023 (art. 229), so
* behaviour in those months may anticipate P3.
*
* This Part is DESCRIPTIVE of the first stage. It estimates no outcome effects
* and does not change the main specification.

di as text _n "========================================"
di as text    "  PART 6: SPEED OF ADJUSTMENT"
di as text    "========================================"

* ==============================================================================
* 6.0  SETUP
* ==============================================================================

use "data/intermediate/lots_v2.dta", clear

gen byte pnrr = (flag_pnrr_pnc == "1" | flag_pnrr_pnc == "SI")
gen int mo = mofd(pub_date) - ym(2021, 6)
label var mo "Months since 1 Jun 2021 (0 = Jun 2021)"

* Control period + P2 up to month 21, non-PNRR (as in the main sample)
keep if pnrr == 0 & (${g_CTRL} | (period == 2 & mo <= 21))

* Bands. Lots at exactly €139,000 belong to the eligible band (section 1.7).
gen byte band = .
replace band = 1 if importo_lotto >  $BAND_LO & importo_lotto <= 139000
replace band = 0 if importo_lotto >  139000   & importo_lotto <= 180000
keep if !missing(band)
label var band "Newly eligible band (vs comparison band 139k-180k)"

gen ym = ym(year(pub_date), month(pub_date))
egen reg_id = group(region), label

* Time bins after the reform. The control period is the reference.
*   1: months 0–2   (Jun–Aug 2021)     2: months 3–5   (Sep–Nov 2021)
*   3: months 6–11  (Dec 2021–May 2022) 4: months 12–21 (long run)
gen byte tbin = 0
replace tbin = 1 if inrange(mo, 0, 2)
replace tbin = 2 if inrange(mo, 3, 5)
replace tbin = 3 if inrange(mo, 6, 11)
replace tbin = 4 if inrange(mo, 12, 21)
forvalues b = 1/4 {
    gen byte bb`b' = band * (tbin == `b')
}

* Band × month dummies, built by hand (factor-variable interactions without
* a main effect can make reghdfe drop the wrong level)
forvalues m = 0/21 {
    gen byte bm`m' = band * (mo == `m')
}

di as text _n "  Lots by period and band (direct-award share):"
table post band, stat(mean direct) stat(freq) nformat(%5.3f)


* ==============================================================================
* 6.1  AGGREGATE ADJUSTMENT CURVE
* ==============================================================================
* Regression (all lots in both bands):
*   direct = band + Σ_m β_m (band × month m) + month FE + region FE + CPV2 FE
* The reference is the whole control period, so β_m = gap(m) − gap(control).
* Long-run gap β_LR = average of β_12 … β_21. closed(m) = β_m / β_LR.
* Then a two-parameter curve summarises the path:
*   closed(m) = 1 − (1 − α)·exp(−λ·m)
* α = share closed on impact (month 0); λ = monthly speed at which the rest
* closes; half-life of the remaining gap = ln(2)/λ months.

di as text _n "========================================"
di as text    "  6.1: AGGREGATE ADJUSTMENT CURVE"
di as text    "========================================"

reghdfe direct band bm0-bm21, absorb(ym reg_id cpv2) vce(cluster authority_id)
di as text "  Gap in the control period (band coefficient): " %6.4f _b[band] " (" %6.4f _se[band] ")"

local lrx "(_b[bm12]"
forvalues m = 13/21 {
    local lrx "`lrx' + _b[bm`m']"
}
local lrx "`lrx')/10"
lincom `lrx'
local lr = r(estimate)
di as text "  Long-run change in the gap (months 12-21): " %6.4f r(estimate) " (" %6.4f r(se) ")"

di as text _n "  Share of the adjustment completed (closed(m) = beta_m / beta_LR):"
foreach m in 0 1 2 3 6 9 12 {
    quietly nlcom _b[bm`m'] / (`lrx')
    matrix NB = r(b)
    matrix NV = r(V)
    di as text "    month " %2.0f `m' ": " %6.3f NB[1,1] "  (SE " %5.3f sqrt(NV[1,1]) ")"
}

tempfile curve
tempname ch
postfile `ch' mo b se using `curve'
forvalues m = 0/21 {
    post `ch' (`m') (_b[bm`m']) (_se[bm`m'])
}
postclose `ch'

preserve
use `curve', clear
gen float closed = b / `lr'
gen float lo = (b - 1.96*se) / `lr'
gen float hi = (b + 1.96*se) / `lr'
* Two-parameter curve, weighted by precision (descriptive summary)
capture nl (closed = 1 - (1 - {alpha=0.5}) * exp(-{lambda=0.3} * mo)) [aw = 1/se^2]
if !_rc {
    di as text _n "  Fitted curve: impact alpha = " %5.3f _b[/alpha] " (" %5.3f _se[/alpha] ")" ///
        "  speed lambda = " %5.3f _b[/lambda] " (" %5.3f _se[/lambda] ")" ///
        "  half-life of remaining gap = " %4.1f ln(2)/_b[/lambda] " months"
    predict float fit
}
else gen float fit = .
export delimited using "results/tables/S1_adjustment_curve${SFX}.csv", replace
twoway (rcap lo hi mo, lcolor(navy%40)) ///
    (scatter closed mo, mcolor(navy)) ///
    (line fit mo, lcolor(cranberry) lpattern(dash)), ///
    yline(0 1, lcolor(gs10) lpattern(dot)) ///
    xtitle("Months since 1 Jun 2021") ytitle("Share of the adjustment completed") ///
    title("Speed of adjustment to the 139k regime") ///
    note("Gap in direct-award share, band (${BAND_LO}, 139k] vs (139k, 180k], relative to ${CTRL_G}." ///
         "1 = average gap in months 12-21. CIs ignore uncertainty in the long-run gap.") ///
    legend(order(2 "Estimate" 3 "Fitted 1-(1-a)exp(-l m)") rows(1) position(6)) ///
    graphregion(color(white))
graph export "results/figures/S1_adjustment_curve${SFX}.png", width(2000) replace
restore


* ---- 6.1b  Raw time series of the two bands ----
* The picture behind 6.1: monthly direct-award share in the newly eligible
* band and in the comparison band. What the design needs to see:
*   - BEFORE the reform the two lines move in parallel (stable gap);
*   - a jump in the eligible band only, concentrated in the first months;
*   - AFTER the adjustment the two lines are parallel again (new stable gap).
* Dashed horizontal segments = each band's average in the control period and
* in the long run (months 12–21). The shaded area marks months 0–2, where 6.1
* finds most of the adjustment. Raw shares, no fixed effects.
* (Months 22–24 are not in this sample; see the note at the top of Part 6.)

preserve
gen byte one = 1
collapse (mean) share = direct (sum) n = one, by(mo band)
reshape wide share n, i(mo) j(band)
label var share1 "Newly eligible band (${BAND_LO}, 139k]"
label var share0 "Comparison band (139k, 180k]"
gen float gap = share1 - share0
foreach b in 0 1 {
    quietly summarize share`b' if mo < 0 [aw = n`b']
    gen float pre`b' = r(mean) if mo < 0
    quietly summarize share`b' if inrange(mo, 12, 21) [aw = n`b']
    gen float lr`b' = r(mean) if inrange(mo, 12, 21)
}
quietly summarize gap if mo < 0
local gpre = r(mean)
quietly summarize gap if inrange(mo, 12, 21)
local glr = r(mean)
di as text _n "  Raw gap (eligible − comparison band): control period " %5.3f `gpre' ///
    ", long run " %5.3f `glr'
local gpre_s : display %4.2f `gpre'
local glr_s  : display %4.2f `glr'
gen float shade = 0.8 if inrange(mo, -0.5, 2.5)
export delimited using "results/tables/S1b_band_series${SFX}.csv", replace
twoway (bar shade mo if inrange(mo, 0, 2), barwidth(1) color(gs14)) ///
    (connected share1 mo, mcolor(navy) lcolor(navy) msize(small)) ///
    (connected share0 mo, mcolor(cranberry) lcolor(cranberry) msymbol(S) msize(small)) ///
    (line pre1 mo, lcolor(navy) lpattern(dash)) (line lr1 mo, lcolor(navy) lpattern(dash)) ///
    (line pre0 mo, lcolor(cranberry) lpattern(dash)) (line lr0 mo, lcolor(cranberry) lpattern(dash)), ///
    xline(-0.5, lcolor(black) lpattern(solid)) ///
    yscale(range(0 0.8)) ylabel(0(0.1)0.8) ///
    xtitle("Months since 1 Jun 2021 (negative = ${CTRL_G})") ///
    ytitle("Share of lots awarded directly") ///
    title("Direct-award share in the two bands, before and after DL 77/2021") ///
    legend(order(2 "Eligible band (${BAND_LO}, 139k]" 3 "Comparison band (139k, 180k]" ///
        4 "Band averages: control period / long run" 1 "Months 0-2") rows(2) position(6)) ///
    note("Gap eligible − comparison: `gpre_s' in ${CTRL_G}, `glr_s' in months 12-21." ///
         "Non-PNRR lots; lots at exactly 139,000 in the eligible band.") ///
    graphregion(color(white))
graph export "results/figures/S1b_band_series${SFX}.png", width(2000) replace
restore


* ==============================================================================
* 6.2  SPEED BY REGION   and   6.3  SPEED BY SECTOR
* ==============================================================================
* Same regression, run separately for each group, with the four time bins
* instead of single months (single months are too noisy for small groups):
*   direct = band + Σ_b γ_b (band × bin b) + month FE + [CPV2 FE | region FE]
* γ_4 = long-run change in the gap; closed_b = γ_b / γ_4 for b = 1, 2, 3.
* This gives the "speed matrix": rows = groups, columns = time bins.
*   Regions: 23 ANAC sections ("CENTRALE" = central authorities and
*            "NON CLASSIFICATO" are kept as their own rows).
*   Sectors: CPV2 divisions with ≥ 500 eligible-band lots in P2; the rest are
*            pooled as "other" (code 0). Also services vs supplies.
* Small groups give noisy ratios: read them with their SEs.

capture program drop speed_group
program define speed_group, rclass
    syntax if, ABSorb(varlist)
    quietly reghdfe direct band bb1 bb2 bb3 bb4 `if', absorb(`absorb') vce(cluster authority_id)
    return scalar n      = e(N)
    return scalar nclust = e(N_clust)
    return scalar pre    = _b[band]
    return scalar pre_se = _se[band]
    return scalar lr     = _b[bb4]
    return scalar lr_se  = _se[bb4]
    forvalues b = 1/3 {
        quietly nlcom _b[bb`b'] / _b[bb4]
        matrix NB = r(b)
        matrix NV = r(V)
        return scalar c`b'    = NB[1,1]
        return scalar c`b'_se = sqrt(NV[1,1])
    }
end

* Sector groups
quietly count if band == 1 & period == 2
bysort cpv2: egen n_cpv_p2 = total(band == 1 & period == 2)
gen int sector = cond(n_cpv_p2 >= 500, cpv2, 0)
label var sector "CPV2 division (0 = pooled small divisions)"
gen byte services = (oggetto_principale_contratto == "SERVIZI")

tempfile speeds
tempname sh
postfile `sh' str8 gtype int gid str40 gname n nclust n_band_p2 pre pre_se lr lr_se ///
    c1 c1_se c2 c2_se c3 c3_se using `speeds'

* -- Regions --
levelsof reg_id, local(regs)
foreach r of local regs {
    local nm : label (reg_id) `r'
    local nm = subinstr("`nm'", "SEZIONE REGIONALE ", "", .)
    quietly count if reg_id == `r' & band == 1 & period == 2
    local nb = r(N)
    capture speed_group if reg_id == `r', absorb(ym cpv2)
    if !_rc {
        post `sh' ("region") (`r') ("`nm'") (r(n)) (r(nclust)) (`nb') (r(pre)) (r(pre_se)) ///
            (r(lr)) (r(lr_se)) (r(c1)) (r(c1_se)) (r(c2)) (r(c2_se)) (r(c3)) (r(c3_se))
    }
    else di as error "  region `nm': estimation failed"
}

* -- Sectors (CPV2) --
levelsof sector, local(secs)
foreach s of local secs {
    local nm = cond(`s' == 0, "other (pooled)", "CPV " + string(`s', "%02.0f"))
    quietly count if sector == `s' & band == 1 & period == 2
    local nb = r(N)
    capture speed_group if sector == `s', absorb(ym reg_id)
    if !_rc {
        post `sh' ("sector") (`s') ("`nm'") (r(n)) (r(nclust)) (`nb') (r(pre)) (r(pre_se)) ///
            (r(lr)) (r(lr_se)) (r(c1)) (r(c1_se)) (r(c2)) (r(c2_se)) (r(c3)) (r(c3_se))
    }
    else di as error "  sector `nm': estimation failed"
}

* -- Services vs supplies --
foreach v in 0 1 {
    local nm = cond(`v' == 1, "services", "supplies")
    quietly count if services == `v' & band == 1 & period == 2
    local nb = r(N)
    capture speed_group if services == `v', absorb(ym reg_id cpv2)
    if !_rc {
        post `sh' ("object") (`v') ("`nm'") (r(n)) (r(nclust)) (`nb') (r(pre)) (r(pre_se)) ///
            (r(lr)) (r(lr_se)) (r(c1)) (r(c1_se)) (r(c2)) (r(c2_se)) (r(c3)) (r(c3_se))
    }
}
postclose `sh'

* ---- Sector-mix adjustment for regions ----
* A region can look slow simply because it buys more from slow sectors.
* expected_c_b(region) = Σ_s w(region, s) · c_b(sector s), with w = the
* region's share of P2 eligible-band lots in sector s. The difference
* raw − expected is the part of the region's speed NOT explained by its
* sector mix.
preserve
keep if band == 1 & period == 2
contract reg_id sector, freq(n_rs)
bysort reg_id: egen n_r = total(n_rs)
gen float w = n_rs / n_r
tempfile mix
save `mix'
use `speeds', clear
keep if gtype == "sector"
rename (gid c1 c2 c3) (sector sc1 sc2 sc3)
keep sector sc1 sc2 sc3
merge 1:m sector using `mix', keep(match) nogen
forvalues b = 1/3 {
    gen float wc`b' = w * sc`b'
}
collapse (sum) exp_c1 = wc1 exp_c2 = wc2 exp_c3 = wc3, by(reg_id)
rename reg_id gid
gen str8 gtype = "region"
tempfile expected
save `expected'
restore

preserve
use `speeds', clear
merge 1:1 gtype gid using `expected', nogen
forvalues b = 1/3 {
    gen float dev_c`b' = c`b' - exp_c`b' if gtype == "region"
}
format pre pre_se lr lr_se c1 c1_se c2 c2_se c3 c3_se exp_c* dev_c* %6.3f
compress
save "data/intermediate/adjustment_speed_groups${SFX}.dta", replace

di as text _n "========================================"
di as text    "  6.2: SPEED BY REGION (share of adjustment completed)"
di as text    "  c1 = months 0-2, c2 = 3-5, c3 = 6-11; lr = long-run change in gap"
di as text    "  exp_c = expected from sector mix; dev = raw - expected"
di as text    "========================================"
set linesize 160
gsort gtype -c1
list gname n_band_p2 pre lr lr_se c1 c1_se c2 c3 c3_se exp_c1 dev_c1 dev_c3 if gtype == "region", ///
    noobs clean abbreviate(10)
di as text _n "========================================"
di as text    "  6.3: SPEED BY SECTOR (CPV2) AND OBJECT"
di as text    "========================================"
list gname n_band_p2 pre lr lr_se c1 c1_se c2 c3 c3_se if gtype == "sector", noobs clean abbreviate(10)
list gname n_band_p2 pre lr lr_se c1 c1_se c2 c3 c3_se if gtype == "object", noobs clean abbreviate(10)
set linesize 80

export delimited using "results/tables/S2_speed_groups${SFX}.csv", replace

* Dispersion summary: are groups really different, or is it sampling noise?
* If the spread of the estimates across groups (SD) is not larger than their
* typical standard error, the ranking is mostly noise.
* Result of the main run (P1b): regions differ in HOW MUCH they
* adopted (lr: SD 0.092 vs SE 0.043) far more than in HOW FAST (c1: SD 0.148
* vs SE 0.199). Ratios c_b are unstable when lr is small (e.g. CPV 09).
foreach t in region sector {
    foreach v in lr c1 c3 {
        quietly summarize `v' if gtype == "`t'" [aw = n_band_p2]
        local sd = r(sd)
        quietly summarize `v'_se if gtype == "`t'" [aw = n_band_p2]
        di as text "  `t's: weighted SD of `v' = " %5.3f `sd' "  vs average SE = " %5.3f r(mean)
    }
}

* Figure: regions ranked by share closed in months 0-2, with 95% CIs
keep if gtype == "region"
gsort c1
gen int rank = _n
forvalues i = 1/`=_N' {
    local lab`i' = gname[`i']
    label define rk `i' "`lab`i''", add
}
label values rank rk
gen float lo = c1 - 1.96*c1_se
gen float hi = c1 + 1.96*c1_se
twoway (rcap lo hi rank, horizontal lcolor(navy%40)) ///
    (scatter rank c1, mcolor(navy)) ///
    (scatter rank c3, mcolor(cranberry) msymbol(Dh)), ///
    ylabel(1/`=_N', valuelabel angle(0) labsize(vsmall)) ytitle("") ///
    xline(1, lcolor(gs10) lpattern(dot)) ///
    xtitle("Share of the long-run adjustment completed") ///
    title("Speed of adjustment by region") ///
    legend(order(2 "Months 0-2 (95% CI)" 3 "Months 6-11") rows(1) position(6)) ///
    graphregion(color(white))
graph export "results/figures/S2_speed_regions${SFX}.png", width(2000) replace
restore




* ==============================================================================
* 6.4  REGION × SECTOR MATRIX OF LONG-RUN TAKE-UP
* ==============================================================================
* MEASURE: long-run take-up = the change in the
* direct-award gap (eligible band − comparison band) between the control
* period and months 12–21 — the coefficient γ_4 ("lr") of 6.2–6.3. Section 6.3
* showed that groups differ in HOW MUCH they adopted far more than in HOW FAST,
* so take-up, not speed, is the variable worth mapping.
*
* CELLS: region × sector (sector = CPV2 groups of 6.3). A cell is estimated
* only if it has ≥ 100 eligible-band lots in P2. Each cell: same regression
* as 6.2, run on the cell's lots with month FE.
*
* SHRINKAGE (empirical Bayes). Small cells give noisy estimates; ranking them
* raw would mostly rank noise. We
*   1. predict each cell from an additive model lr = region effect + sector
*      effect (weighted by 1/SE²);
*   2. estimate how much true cell-level variation is left around that
*      prediction: τ² = mean(residual²) − mean(SE²)  (method of moments);
*   3. combine: lr_eb = w·raw + (1 − w)·prediction, with w = τ² / (τ² + SE²).
* Precise cells keep their own estimate; noisy cells are pulled toward what
* their region and sector predict. (The prediction is fitted on the same
* cells, so τ² is slightly understated: shrinkage is a bit conservative.)
*
* RESULT (main run, P1b): 174 cells (79% of eligible P2 lots).
* Sector explains more of the cell variation than region (weighted R² 0.77 vs
* 0.55; both 0.86). τ² = 0: once region and sector effects are in, the cells
* show no extra variation beyond sampling noise, so lr_eb equals the additive
* prediction — the matrix is "region effect + sector effect", with no
* detectable region-specific sector patterns.

di as text _n "========================================"
di as text    "  6.4: REGION × SECTOR TAKE-UP MATRIX"
di as text    "========================================"

* Region and sector names and their take-up ranking (from 6.2–6.3), for the
* heatmap: rank 1 = lowest take-up.
preserve
use "data/intermediate/adjustment_speed_groups${SFX}.dta", clear
keep if gtype == "region"
sort lr
gen int rrank = _n
rename gid rid
keep rid gname rrank
tempfile regorder
save `regorder'
* axis labels for ALL regions (also those without an estimated cell)
local nr = _N
local ylab ""
forvalues i = 1/`nr' {
    local nm = subinstr(gname[`i'], "PROVINCIA AUTONOMA DI ", "P.A. ", 1)
    local ylab `"`ylab' `i' "`nm'""'
}
use "data/intermediate/adjustment_speed_groups${SFX}.dta", clear
keep if gtype == "sector"
sort lr
gen int srank = _n
rename gid sector
keep sector srank
tempfile secorder
save `secorder'
local ns = _N
local xlab ""
forvalues i = 1/`ns' {
    local nm = cond(sector[`i'] == 0, "other", "CPV " + string(sector[`i'], "%02.0f"))
    local xlab `"`xlab' `i' "`nm'""'
}
restore

capture program drop lr_cell
program define lr_cell, rclass
    syntax if, ABSorb(varlist)
    quietly reghdfe direct band bb1 bb2 bb3 bb4 `if', absorb(`absorb') vce(cluster authority_id)
    return scalar lr     = _b[bb4]
    return scalar lr_se  = _se[bb4]
    return scalar n      = e(N)
end

egen int cell = group(reg_id sector)
bysort cell: egen n_cell_p2 = total(band == 1 & period == 2)

tempfile cells
tempname cp
postfile `cp' int cell int rid int sector n n_band_p2 lr lr_se using `cells'
levelsof cell if n_cell_p2 >= 100, local(cl)
foreach c of local cl {
    quietly summarize reg_id if cell == `c', meanonly
    local r = r(min)
    quietly summarize sector if cell == `c', meanonly
    local s = r(min)
    quietly summarize n_cell_p2 if cell == `c', meanonly
    local nb = r(min)
    capture lr_cell if cell == `c', absorb(ym)
    if !_rc & r(lr_se) > 0 & !missing(r(lr_se)) {
        post `cp' (`c') (`r') (`s') (r(n)) (`nb') (r(lr)) (r(lr_se))
    }
}
postclose `cp'

* Share of eligible-band P2 lots covered by the estimated cells
quietly count if band == 1 & period == 2
local n_all = r(N)
quietly count if band == 1 & period == 2 & n_cell_p2 >= 100
di as text "  Cells with >= 100 eligible P2 lots cover " %4.1f 100*r(N)/`n_all' "% of eligible-band P2 lots"

preserve
use `cells', clear
di as text "  Cells estimated: " _N

* 1. Additive prediction and variance decomposition
gen float wt = 1 / lr_se^2
quietly regress lr i.rid [aw = wt]
local r2_reg = e(r2)
quietly regress lr i.sector [aw = wt]
local r2_sec = e(r2)
quietly regress lr i.rid i.sector [aw = wt]
local r2_both = e(r2)
predict float lr_pred, xb
di as text "  Share of cell variation in take-up explained by (weighted R2):"
di as text "    region only " %4.2f `r2_reg' "   sector only " %4.2f `r2_sec' "   both " %4.2f `r2_both'

* 2. Remaining true variation (method of moments)
gen float res2 = (lr - lr_pred)^2
gen float se2 = lr_se^2
quietly summarize res2
local m_res2 = r(mean)
quietly summarize se2
local m_se2 = r(mean)
local tau2 = max(0, `m_res2' - `m_se2')
di as text "  Mean squared residual = " %6.4f `m_res2' "  mean SE^2 = " %6.4f `m_se2' ///
    "  tau^2 = " %6.4f `tau2' " (tau = " %5.3f sqrt(`tau2') ")"

* 3. Shrinkage
gen float w_eb = `tau2' / (`tau2' + se2)
gen float lr_eb = w_eb * lr + (1 - w_eb) * lr_pred
quietly summarize w_eb
di as text "  Average weight on the cell's own estimate: " %4.2f r(mean)
summarize lr lr_eb [aw = n_band_p2]

* Names and rankings for the figure
merge m:1 rid using `regorder', keep(match) nogen
merge m:1 sector using `secorder', keep(match) nogen
gen str12 sname = cond(sector == 0, "other", "CPV " + string(sector, "%02.0f"))
save "`cells'", replace
export delimited using "results/tables/S4_takeup_cells${SFX}.csv", replace

* Heatmap: rows = regions ordered by region take-up (6.2), columns = sectors
* ordered by sector take-up (6.3); colour = shrunk take-up lr_eb.
gen byte cbin = 1 + (lr_eb >= .2) + (lr_eb >= .3) + (lr_eb >= .4) + (lr_eb >= .5)
twoway (scatter rrank srank if cbin == 1, msymbol(S) msize(large) mcolor("222 235 247")) ///
       (scatter rrank srank if cbin == 2, msymbol(S) msize(large) mcolor("158 202 225")) ///
       (scatter rrank srank if cbin == 3, msymbol(S) msize(large) mcolor("107 174 214")) ///
       (scatter rrank srank if cbin == 4, msymbol(S) msize(large) mcolor("49 130 189")) ///
       (scatter rrank srank if cbin == 5, msymbol(S) msize(large) mcolor("8 81 156")), ///
    ylabel(`ylab', angle(0) labsize(vsmall) nogrid) xlabel(`xlab', angle(90) labsize(vsmall) nogrid) ///
    yscale(range(0.5 `=`nr'+0.5')) xscale(range(0.5 `=`ns'+0.5')) ///
    ytitle("") xtitle("") ///
    title("Long-run take-up of direct award" "region × sector", size(medium)) ///
    legend(order(1 "< 0.20" 2 "0.20-0.30" 3 "0.30-0.40" 4 "0.40-0.50" 5 ">= 0.50") ///
        title("Change in gap", size(small)) rows(1) position(6)) ///
    note("Shrunk (empirical Bayes) change in the direct-award gap, eligible vs comparison band," ///
         "${CTRL_G} to months 12-21. Empty cell = fewer than 100 eligible P2 lots." ///
         "Rows/columns ordered by region/sector take-up (lowest at bottom/left).", size(vsmall)) ///
    xsize(12) ysize(9) graphregion(color(white))
graph export "results/figures/S4_takeup_matrix${SFX}.png", width(2400) replace
restore


* ==============================================================================
* 6.5  CHECKS
* ==============================================================================
* (a) RELIABILITY. Is a region's (sector's) take-up a stable trait, or noise?
*     Split the eligible band in two: A = (BAND_LO, 99k], B = (99k, 139k].
*     Estimate take-up separately on each half (each against the comparison
*     band) and correlate across regions/sectors. Band A is also the version
*     to use as a moderator later: it lies outside the main RD window
*     (lots ≥ 99k at h = 40k), so it is not built from the same lots as the
*     outcome estimates.
* (b) FAKE REFORM DATE inside the control period: split the control period in
*     two at its middle month and estimate the change in the gap. Should be ~0.
* RESULTS (main run, P1b): (a) correlation band A vs band B = 0.79
* for regions (N = 23) and 0.79 for sectors (N = 30) — take-up is a stable
* trait of a region/sector, not noise; (b) −0.004 (SE 0.011); (c) +0.015
* (SE 0.010). Both placebos ≈ 0.
* (c) COMPARISON BAND ALONE: (139k, 180k] vs (180k, 214k], neither eligible in
*     P2 (214k = EU threshold for non-central authorities). The change in the
*     gap between control period and months 12–21 should be ~0.

di as text _n "========================================"
di as text    "  6.5: CHECKS"
di as text    "========================================"

tempfile halves
tempname hp
postfile `hp' str8 gtype int gid lrA lrA_se lrB lrB_se nA nB using `halves'
foreach t in region sector {
    local gv = cond("`t'" == "region", "reg_id", "sector")
    local fe = cond("`t'" == "region", "ym cpv2", "ym reg_id")
    levelsof `gv', local(gl)
    foreach g of local gl {
        capture lr_cell if `gv' == `g' & (band == 0 | importo_lotto <= 99000), absorb(`fe')
        if _rc continue
        local a = r(lr)
        local as = r(lr_se)
        quietly count if `gv' == `g' & band == 1 & period == 2 & importo_lotto <= 99000
        local na = r(N)
        capture lr_cell if `gv' == `g' & (band == 0 | importo_lotto > 99000), absorb(`fe')
        if _rc continue
        local b = r(lr)
        local bs = r(lr_se)
        quietly count if `gv' == `g' & band == 1 & period == 2 & importo_lotto > 99000
        post `hp' ("`t'") (`g') (`a') (`as') (`b') (`bs') (`na') (r(N))
    }
}
postclose `hp'

preserve
use `halves', clear
foreach t in region sector {
    quietly correlate lrA lrB if gtype == "`t'"
    local rho = r(rho)
    quietly spearman lrA lrB if gtype == "`t'"
    di as text "  (a) `t's: correlation of take-up, band A vs band B = " %5.2f `rho' ///
        "  (Spearman " %5.2f r(rho) ", N = " r(N) ")"
}
save "`halves'", replace
restore

* (b) Fake reform date at the middle of the control period
preserve
keep if mo < 0
quietly summarize mo
local mid = floor((r(min) + r(max)) / 2)
gen byte fake = (mo >= `mid')
gen byte band_fake = band * fake
quietly reghdfe direct band band_fake, absorb(ym reg_id cpv2) vce(cluster authority_id)
di as text "  (b) Fake reform at month `mid' of the control period: change in gap = " ///
    %6.4f _b[band_fake] " (" %6.4f _se[band_fake] ")  N = " e(N)
rpost Scheck fakedate gap, coef(band_fake)
restore

* (c) Comparison band vs a higher band
preserve
use "data/intermediate/lots_v2.dta", clear
gen byte pnrr = (flag_pnrr_pnc == "1" | flag_pnrr_pnc == "SI")
gen int mo = mofd(pub_date) - ym(2021, 6)
keep if pnrr == 0 & (${g_CTRL} | (period == 2 & inrange(mo, 12, 21)))
gen byte band_c = .
replace band_c = 1 if importo_lotto > 139000 & importo_lotto <= 180000
replace band_c = 0 if importo_lotto > 180000 & importo_lotto <= 214000
keep if !missing(band_c)
gen byte band_c_lr = band_c * (period == 2)
gen ym = ym(year(pub_date), month(pub_date))
egen reg_id = group(region)
quietly reghdfe direct band_c band_c_lr, absorb(ym reg_id cpv2) vce(cluster authority_id)
di as text "  (c) Comparison band (139k,180k] vs (180k,214k]: change in gap = " ///
    %6.4f _b[band_c_lr] " (" %6.4f _se[band_c_lr] ")  N = " e(N)
rpost Scheck compband gap, coef(band_c_lr)
restore


* ==============================================================================
* 6.6  SAVE TAKE-UP MEASURES FOR LATER ANALYSIS
* ==============================================================================
* One file, three levels (gtype = region / sector / cell):
*   lr, lr_se   take-up on the full eligible band (6.2–6.4)
*   lr_eb       shrunk take-up (cells only, 6.4)
*   lrA, lrA_se take-up on band A = (BAND_LO, 99k] only — USE THIS ONE as a
*               moderator of RD results (outside the RD window, see 6.5a)
*   c1–c3       speed (share of adjustment completed by bin, 6.2–6.3)
* Keys: reg_id (with region name), sector (CPV2 group; 0 = pooled).

preserve
use "data/intermediate/adjustment_speed_groups${SFX}.dta", clear
keep if inlist(gtype, "region", "sector")
merge 1:1 gtype gid using `halves', nogen
gen int reg_id = gid if gtype == "region"
gen int sector = gid if gtype == "sector"
append using `cells'
replace gtype = "cell" if missing(gtype)
replace reg_id = rid if gtype == "cell"
capture drop rid wt res2 se2 rrank srank
order gtype reg_id sector gname sname n_band_p2 lr lr_se lr_eb lrA lrA_se lrB lrB_se c1 c1_se c2 c2_se c3 c3_se
label var lr    "Long-run take-up: change in direct gap, eligible vs comparison band"
label var lr_eb "Long-run take-up, empirical-Bayes shrunk (cells)"
label var lrA   "Long-run take-up on band A (BAND_LO, 99k] - moderator version"
compress
save "data/intermediate/adjustment_speed${SFX}.dta", replace
di as text "  Saved adjustment_speed${SFX}.dta: " _N " rows (regions, sectors, cells)"
restore



* ##############################################################################
* ##############################################################################
* ##                                                                          ##
* ##   PART 7: NETWORK EXTENSION — DID THE REFORM OPEN THE MARKET? (Module N) ##
* ##                                                                          ##
* ##   Where do the new winners below 139k come from: firms already tied to   ##
* ##   the authority, firms in its wider network, or firms new to the market? ##
* ##                                                                          ##
* ##############################################################################
* ##############################################################################
*
* QUESTION. Part 5 shows that, after the reform, lots just below 139k are more
* often won by a firm with no earlier contract with THAT authority. That could
* mean two different things:
*   (a) OPENING: the authority buys from firms new to the whole market;
*   (b) ROTATION: the authority rotates among firms it already knows through
*       its network (other suppliers of its suppliers' buyers), or brings back
*       former suppliers after skipping a turn.
* The network classes below separate (a) from (b).
*
* MEASURES (built in Python, code/net_py/, run by code/net_master.do, which
* also prints the build checks). For each lot with
* a winner f at authority a, using awards in the 24 months BEFORE the award
* (day-level window: strictly earlier awards only) within the same CPV2 market:
*   net_incumbent   f won a's most recent award in the same CPV3
*   net_prior_other f supplied a in the window, but not its most recent award
*   net_indirect    f never supplied a, but is two steps away: some authority b
*                   bought from f AND from one of a's suppliers
*   net_outsider    f won awards elsewhere in the market, with no such path to a
*   net_newobs      f won NO award in this market in the window ("new firm")
*   net_return_gap  f supplied a before but not its last award (subset of
*                   prior_other): the signature of rotation ("skip a turn")
*   net_ldeg_hist   log(1 + number of authorities f supplied in the window):
*                   how established the winner is (only earlier awards).
* The first five classes are mutually exclusive and sum to 1 for every lot, so
* their diff-in-disc coefficients sum to 0: they show where the change in
* winners comes from (checked in 7.2).
*
* HISTORY DATES differ from Part 5 on purpose: the network uses the AWARD date
* (when the relationship exists) and starts in 2015; Part 5 uses publication
* dates from 2018 and ignores the market (CPV2). "New to the authority" (Part 5)
* and "new to the market" (here) are different questions.
*
* NOT USED HERE: the Python build also writes other network versions
* (monthly window, history including 2024), available by running
* code/net_master.do.

di as text _n "========================================"
di as text    "  PART 7: NETWORK EXTENSION (OPENING)"
di as text    "========================================"

* ---- Helpers ----
* net_post: store one estimate (b, SE, p, N, and the mean of the outcome among
* control-period lots below the cutoff in the estimation sample) in the
* results file and print it. p uses the t distribution with e(df_r), as in
* Parts 4–5; the normal if the estimator reports no df_r.
capture program drop net_post
program define net_post
    args spec outcome coef meancond
    local b  = _b[`coef']
    local se = _se[`coef']
    if missing(e(df_r)) local p = 2*normal(-abs(`b'/`se'))
    else                local p = 2*ttail(e(df_r), abs(`b'/`se'))
    local n = e(N)
    quietly summarize `outcome' if e(sample) & `meancond', meanonly
    post nres ("`spec'") ("`outcome'") (`b') (`se') (`p') (`n') (r(mean))
    di as text %-10s "`spec'" %-18s "`outcome'" " b=" %8.4f `b' ///
        " (" %7.4f `se' ")  p=" %6.4f `p' "  N=" %6.0f `n'
end

* net_rob: the six class outcomes under one specification. cmd has @ in place
* of the outcome; vsfx picks a network version (e.g. _w12) built in Python.
capture program drop net_rob
program define net_rob
    args spec cmd coef meancond vsfx
    foreach y in net_incumbent net_prior_other net_indirect net_outsider ///
        net_newobs net_return_gap {
        local c : subinstr local cmd "@" "`y'`vsfx'", all
        quietly `c'
        net_post "`spec'" `y'`vsfx' "`coef'" "`meancond'"
    }
end


* ==============================================================================
* 7.0  DATA AND CHECKS
* ==============================================================================
* The Python build writes one row per lot of lots_winners.dta. If Part 5 was
* re-run after the build (e.g. a new winners file), the two can disagree; the
* merge below then stops instead of silently mixing versions.
*
* BUILD STEP (so that one run of this file does everything):
* if net_lot_measures.dta is missing, or its lots do not match lots_winners.dta,
* or global NET_REBUILD is 1, run the Python build (code/net_master.do, about
* 15 minutes) here. NET_FROM_MAIN tells net_master.do to clear only the data
* (not "clear all", which would also delete this file's programs and the open
* results collector).

local need_build = ("$NET_REBUILD" == "1")
capture confirm file "data/intermediate/net_lot_measures.dta"
if _rc local need_build 1
if !`need_build' {
    use cig using "data/intermediate/lots_winners.dta", clear
    capture merge 1:1 cig using "data/intermediate/net_lot_measures.dta", ///
        keepusing(net_newobs) assert(match) nogen
    if _rc local need_build 1
}
if `need_build' {
    di as text "  Network measures missing or out of date: running code/net_master.do"
    global NET_FROM_MAIN 1
    global ROOT "`c(pwd)'"
    do "code/net_master.do"
    global NET_FROM_MAIN ""
}
else di as text "  Network measures up to date (net_lot_measures.dta matches lots_winners.dta)"

use "data/intermediate/lots_winners.dta", clear
local nv net_incumbent net_prior_other net_indirect net_outsider net_newobs ///
    net_return_gap net_ldeg_hist
foreach v in w12 base cpv3 {
    local nv `nv' net_incumbent_`v' net_prior_other_`v' net_indirect_`v' ///
        net_outsider_`v' net_newobs_`v' net_return_gap_`v'
}
capture noisily merge 1:1 cig using "data/intermediate/net_lot_measures.dta", ///
    keepusing(`nv') assert(match) nogen
if _rc {
    di as error "  net_lot_measures.dta does not match lots_winners.dta lot by lot."
    di as error "  The build above did not fix it: check code/logs/net_master.log"
    exit 459
}
di as text "  Merged with network measures: " _N " lots (all matched)"

* The five classes must be exhaustive and exclusive in every version used.
foreach s in "" _w12 _base _cpv3 {
    egen byte _s = rowtotal(net_incumbent`s' net_prior_other`s' net_indirect`s' ///
        net_outsider`s' net_newobs`s')
    assert _s == 1
    drop _s
}

* Same variables and samples as Parts 4–5 (one capture per variable: a single
* "capture drop a b c" drops nothing if any one of them is missing)
foreach v in pnrr main_sample alt_sample kw40 post cpv2_post region_post ym ///
    below_post below_x post_x below_post_x x2 {
    capture drop `v'
}
gen byte pnrr = (flag_pnrr_pnc == "1" | flag_pnrr_pnc == "SI")
gen byte main_sample = (${g_CTRL} | period == 2) & pnrr == 0
gen byte alt_sample  = (${g_ALT}  | period == 2) & pnrr == 0
gen float kw40 = max(0, 1 - abs(x)/40000) if abs(x) <= 40000
gen byte post = (period == 2)
egen cpv2_post = group(cpv2 post)
egen region_post = group(region post)
gen ym = ym(year(pub_date), month(pub_date))
gen float below_post = below * post
gen float below_x = below * x
gen float post_x = post * x
gen float below_post_x = below * post * x
gen float x2 = x^2

label var net_incumbent   "Incumbent (won last award)"
label var net_prior_other "Prior supplier, not last"
label var net_indirect    "Indirect (two steps)"
label var net_outsider    "Outsider (no path)"
label var net_newobs      "New to the market (24m)"
label var net_return_gap  "Return after a gap"
label var net_ldeg_hist   "log(1 + authorities supplied, 24m)"

count if main_sample == 1 & abs(x) <= 40000
di as text "  Estimation sample ($CTRL_G + P2, non-PNRR, |x| <= 40k): " r(N) " lots"

local CM "${g_CTRL} & below == 1"     // reference mean: control period, below


* ==============================================================================
* 7.1  DESCRIPTIVES: WHO WINS, BY PERIOD AND SIDE
* ==============================================================================
* Raw shares in the four cells (control/P2 × above/below 139k). The estimate
* is the diff-in-disc in 7.2; this table only shows what the classes look like.

gen byte ncell = 1 + below + 2*post if main_sample == 1 & abs(x) <= 40000
label define ncell_l 1 "$CTRL_G above" 2 "$CTRL_G below" 3 "P2 above" 4 "P2 below", replace
label values ncell ncell_l
tabstat net_incumbent net_prior_other net_indirect net_outsider net_newobs ///
    net_return_gap net_ldeg_hist, by(ncell) stat(mean) format(%6.4f) nototal

* Binned plot around 139k. Bins are right-closed, (k−2000, k], so lots at
* exactly 139,000 (x = 0) fall in the last bin BELOW the cutoff, as they are
* direct-eligible (below = importo_lotto <= 139000, section 1.7).
gen byte net_tie = net_incumbent + net_prior_other
preserve
keep if main_sample == 1 & abs(x) <= 40000
gen bin = ceil(x/2000)*2000 - 1000
replace bin = -39000 if bin == -41000    // x = −40,000 exactly joins the first bin
collapse (mean) net_tie net_newobs net_outsider net_indirect, by(post bin)
local t_net_tie      "Existing supplier (incumbent + prior)"
local t_net_newobs   "New to the market (no award in 24m)"
local t_net_outsider "Outsider: awards elsewhere, no path"
local t_net_indirect "Indirect: two steps from the authority"
foreach v in net_tie net_newobs net_outsider net_indirect {
    twoway (scatter `v' bin if post == 0, mcolor(gs10) msymbol(Oh) msize(small)) ///
        (scatter `v' bin if post == 1, mcolor(navy) msize(small)) ///
        (lfit `v' bin if post == 0 & bin < 0, lcolor(gs10)) ///
        (lfit `v' bin if post == 0 & bin > 0, lcolor(gs10)) ///
        (lfit `v' bin if post == 1 & bin < 0, lcolor(navy)) ///
        (lfit `v' bin if post == 1 & bin > 0, lcolor(navy)), ///
        xline(0, lcolor(cranberry)) title("`t_`v''", size(medsmall)) ///
        xtitle("Lot value - 139,000 (EUR)", size(small)) ytitle("Share of lots", size(small)) ///
        xlabel(-40000 "-40k" -20000 "-20k" 0 "0" 20000 "20k" 40000 "40k", labsize(small)) ///
        legend(order(1 "$CTRL_G (pre-reform)" 2 "P2 (post-reform)") rows(1) size(small) position(6)) ///
        graphregion(color(white)) name(g_`v', replace)
}
graph combine g_net_tie g_net_newobs g_net_outsider g_net_indirect, cols(2) ///
    graphregion(color(white)) ///
    title("Winner classes around 139k ($CTRL_G vs P2, 2k bins)", size(medium)) ///
    note("Right-closed 2k bins (lots at exactly 139,000 are below); unweighted linear fits; descriptive, no FE.", size(vsmall))
graph export "results/figures/N1_classes_binned${SFX}.png", width(2400) replace
restore


* ==============================================================================
* 7.2  MAIN ESTIMATES: ITT AND LATE
* ==============================================================================
* SPECIFICATION: exactly that of Part 5.3 (local linear on each side and
* period, triangular weights h=40k, FE for CPV2×post, region×post and
* year-month, SEs clustered by authority). Sample: awarded lots with a winner.
* LATE: direct award instrumented by below×post, as in 4.3 and 5.3.

capture postclose nres
tempfile nresf
postfile nres str12 spec str24 outcome double(b se p N mean_ctrl_below) using `nresf'

di as text _n "--- 7.2 ITT (below×post) ---"
local k 0
foreach y in net_incumbent net_prior_other net_indirect net_outsider net_newobs ///
    net_return_gap net_ldeg_hist {
    local ++k
    quietly reghdfe `y' i.below##i.post##c.x [aw=kw40] ///
        if main_sample == 1 & abs(x) <= 40000, ///
        absorb(cpv2_post region_post ym) vce(cluster authority_id)
    estimates store nitt_`k'
    net_post "main_itt" `y' "1.below#1.post" "`CM'"
    cstore n_itt_`y' `y'
}

* Decomposition check: same sample and regressors, so the five class
* coefficients must sum to 0. A non-zero sum would reveal a coding error.
local sumb 0
forvalues j = 1/5 {
    estimates restore nitt_`j'
    local sumb = `sumb' + _b[1.below#1.post]
    if `j' == 1 local n0 = e(N)
    assert e(N) == `n0'
}
di as text "  Sum of the five class ITTs = " %10.2e `sumb' "  (common N = " `n0' ")"
assert abs(`sumb') < 1e-6
estimates drop nitt_*

di as text _n "--- 7.2 LATE (direct = below×post) ---"
foreach y in net_incumbent net_prior_other net_indirect net_outsider net_newobs ///
    net_return_gap net_ldeg_hist {
    quietly ivreghdfe `y' below post x below_x post_x below_post_x ///
        (direct = below_post) [aw=kw40] ///
        if main_sample == 1 & abs(x) <= 40000, ///
        absorb(cpv2_post region_post ym) cluster(authority_id)
    net_post "main_iv" `y' "direct" "`CM'"
    estimates store n_iv_`y'
}
di as text "  Kleibergen-Paap F = " %6.1f e(widstat)


* ==============================================================================
* 7.3  ROBUSTNESS
* ==============================================================================
* Each row re-estimates the six class outcomes under one change. "New to the
* market" (net_newobs) is the result of interest; the other classes show
* where it comes from.

di as text _n "--- 7.3 Robustness ---"
local S  "main_sample == 1 & abs(x) <= 40000"
local A  "absorb(cpv2_post region_post ym) vce(cluster authority_id)"
local RD "i.below##i.post##c.x"

* Bandwidths (triangular weights rebuilt for each h)
foreach h in 20000 30000 60000 {
    local hk = `h'/1000
    capture drop kw_h
    gen float kw_h = max(0, 1 - abs(x)/`h') if abs(x) <= `h'
    net_rob "h`hk'" "reghdfe @ `RD' [aw=kw_h] if main_sample == 1 & abs(x) <= `h', `A'" ///
        "1.below#1.post" "`CM'"
    quietly reghdfe net_ldeg_hist `RD' [aw=kw_h] if main_sample == 1 & abs(x) <= `h', `A'
    net_post "h`hk'" net_ldeg_hist "1.below#1.post" "`CM'"
}
drop kw_h

* Local quadratic (as 4.6b)
net_rob "quad" "reghdfe @ `RD' i.below##i.post##c.x2 [aw=kw40] if `S', `A'" ///
    "1.below#1.post" "`CM'"

* Donuts (as 4.6a) and excluding lots at exactly 139,000 (as 4.6g)
foreach d in 1000 2500 5000 {
    net_rob "donut`d'" "reghdfe @ `RD' [aw=kw40] if `S' & abs(x) >= `d', `A'" ///
        "1.below#1.post" "`CM'"
}
net_rob "no139" "reghdfe @ `RD' [aw=kw40] if `S' & importo_lotto != 139000, `A'" ///
    "1.below#1.post" "`CM'"

* Network versions built in Python: 12-month window; network fixed before the
* reform (awards 17 Jul 2018 – 16 Jul 2020, so post-reform awards cannot shape
* the classes); CPV3 instead of CPV2 markets.
net_rob "w12"  "reghdfe @ `RD' [aw=kw40] if `S', `A'" "1.below#1.post" "`CM'" "_w12"
net_rob "base" "reghdfe @ `RD' [aw=kw40] if `S', `A'" "1.below#1.post" "`CM'" "_base"
net_rob "cpv3" "reghdfe @ `RD' [aw=kw40] if `S', `A'" "1.below#1.post" "`CM'" "_cpv3"

* Alternative control period (as 4.6i)
net_rob "alt_ctrl" "reghdfe @ `RD' [aw=kw40] if alt_sample == 1 & abs(x) <= 40000, `A'" ///
    "1.below#1.post" "${g_ALT} & below == 1"
quietly reghdfe net_ldeg_hist `RD' [aw=kw40] if alt_sample == 1 & abs(x) <= 40000, `A'
net_post "alt_ctrl" net_ldeg_hist "1.below#1.post" "${g_ALT} & below == 1"

* Value-band DiD (as 4.7): 100–130k vs 150–180k, control period vs P2
gen byte treat_band = .
replace treat_band = 1 if importo_lotto >= 100000 & importo_lotto < 130000
replace treat_band = 0 if importo_lotto >= 150000 & importo_lotto < 180000
net_rob "vband" "reghdfe @ c.treat_band#c.post treat_band post if main_sample == 1 & !missing(treat_band), absorb(cpv2 region ym) vce(cluster authority_id)" ///
    "c.treat_band#c.post" "${g_CTRL} & treat_band == 1"

* Authority fixed effects (follow-up to the balance test of 4.10):
* within-authority comparison of lots below and above 139k.
net_rob "authfe" "reghdfe @ `RD' [aw=kw40] if `S', absorb(cpv2_post region_post ym authority_id) vce(cluster authority_id)" ///
    "1.below#1.post" "`CM'"


* ==============================================================================
* 7.4  PLACEBOS
* ==============================================================================
* (a) 139k in each pre-reform period (as 4.6d): no jump should exist there.
* (b) Cutoffs in P2 where nothing changed (as 4.6c): one-sided, never crossing
*     139k, h=15k (10k at 200k).

di as text _n "--- 7.4 Placebos ---"
foreach g in P1b P0 {
    net_rob "plac139`g'" "reghdfe @ i.below##c.x [aw=kw40] if ${g_`g'} & pnrr == 0 & abs(x) <= 40000, absorb(cpv2 region ym) vce(cluster authority_id)" ///
        "1.below" "${g_`g'} & below == 1"
}
foreach c in 100000 120000 160000 200000 {
    local ck = `c'/1000
    local h = 15000
    if `c' == 200000 local h = 10000
    local side "importo_lotto < 139000"
    if `c' > 139000 local side "importo_lotto > 139000"
    capture drop x_plac below_plac kw_plac
    gen float x_plac = importo_lotto - `c'
    gen byte below_plac = (importo_lotto < `c')
    gen float kw_plac = max(0, 1 - abs(x_plac)/`h') if abs(x_plac) <= `h'
    net_rob "plac`ck'" "reghdfe @ i.below_plac##c.x_plac [aw=kw_plac] if period == 2 & pnrr == 0 & abs(x_plac) <= `h' & `side', absorb(cpv2 region ym) vce(cluster authority_id)" ///
        "1.below_plac" "period == 2 & below_plac == 1"
}
drop x_plac below_plac kw_plac

* (c) FOLLOW-UP TO THE FAILED 120k PLACEBO.
* WHY? At 120k nothing legal changes in P2, yet "new to the market" jumps
* (−0.049, p=0.0005). Part 4 found that lots at exact round values (e.g.
* €100,000) are a different kind of lot (much faster to award). Each placebo
* cutoff is itself a round value, and lots at exactly c sit on the ABOVE side
* (below_plac = importo_lotto < c), so a heap of "different" lots at c alone
* can create a jump. If so, it matters for 139k too: €139,000 became a heap
* in P2 (11% of lots within ±5k vs 3% in P1b), and the diff-in-disc does not
* subtract a heap that exists only after the reform.
* THREE STEPS:
*   (i)   how different are lots at exactly c? share new to the market at c
*         vs the other lots within ±15k;
*   (ii)  re-run each P2 placebo without the lots at exactly c, and without
*         any lot at a multiple of €5,000;
*   (iii) re-run the main estimate without lots at multiples of €5,000 (the
*         exact-139,000 exclusion is already in 7.3, "no139").
di as text _n "--- 7.4c Round values and the placebo cutoffs ---"
gen byte round5k = (mod(importo_lotto, 5000) == 0) if !missing(importo_lotto)

di as text "  Share new to the market: lots at exactly c vs other lots within ±15k"
foreach c in 100000 120000 139000 160000 200000 {
    foreach g in P2 $CTRL_G {
        quietly summarize net_newobs if ${g_`g'} & pnrr == 0 & importo_lotto == `c'
        local m_at = r(mean)
        local n_at = r(N)
        quietly summarize net_newobs if ${g_`g'} & pnrr == 0 & importo_lotto != `c' ///
            & abs(importo_lotto - `c') <= 15000
        di as text "    c=" %7.0f `c' "  `g'" _col(22) "at c: " %6.4f `m_at' ///
            " (N=" %5.0f `n_at' ")   others ±15k: " %6.4f r(mean) " (N=" %6.0f r(N) ")"
    }
}

foreach c in 100000 120000 160000 200000 {
    local ck = `c'/1000
    local h = 15000
    if `c' == 200000 local h = 10000
    local side "importo_lotto < 139000"
    if `c' > 139000 local side "importo_lotto > 139000"
    capture drop x_plac below_plac kw_plac
    gen float x_plac = importo_lotto - `c'
    gen byte below_plac = (importo_lotto < `c')
    gen float kw_plac = max(0, 1 - abs(x_plac)/`h') if abs(x_plac) <= `h'
    local P "reghdfe @ i.below_plac##c.x_plac [aw=kw_plac] if period == 2 & pnrr == 0 & abs(x_plac) <= `h' & `side'"
    local PA "absorb(cpv2 region ym) vce(cluster authority_id)"
    net_rob "plac`ck'_noc" "`P' & importo_lotto != `c', `PA'" ///
        "1.below_plac" "period == 2 & below_plac == 1"
    net_rob "plac`ck'_nor5" "`P' & round5k == 0, `PA'" ///
        "1.below_plac" "period == 2 & below_plac == 1"
}
drop x_plac below_plac kw_plac

net_rob "main_nor5" "reghdfe @ `RD' [aw=kw40] if `S' & round5k == 0, `A'" ///
    "1.below#1.post" "`CM'"

* RESULTS 7.4c (main run):
* (i) In P2, lots at exactly a round value go to firms new to the market MORE
*     often than nearby lots: 120,000: 0.340 vs 0.262 (N=1,449); 100,000:
*     0.302 vs 0.257; 160,000: 0.263 vs 0.173; 200,000: 0.236 vs 0.183;
*     139,000: 0.294 vs 0.257 (N=1,001). In P1b the gaps are small or
*     reversed (120,000: 0.245 vs 0.210; 139,000: 0.194 vs 0.225, N=36).
* (ii) The 120k placebo for "new to the market" disappears without the
*     €120,000 lots: −0.009 (0.015), p=0.55 (was −0.049, p=0.0005); and
*     without any multiple of €5,000: −0.004 (0.016), p=0.78. The €120,000 lots
*     sit on the above side of the placebo cutoff, so their high share of new
*     firms made "above" look higher. The other placebos stay clean; the only
*     new value near 5% is return after a gap at 120k without multiples of
*     €5,000 (−0.027, p=0.045), one of 48 extra tests.
* (iii) The main result holds without multiples of €5,000: new to the market
*     +0.047 (0.021), p=0.024 (N=41,731); prior supplier −0.054 (p=0.029).
*     Excluding the €139,000 heap (7.3, "no139") gives +0.045 (p=0.016), so
*     the 139,000 heap does not drive it either.
* READING: the failed placebo was a round-number artefact, not a sign that
* lot values sort on supplier history in general.


* ==============================================================================
* 7.5  OUTPUTS: RESULTS TABLE AND COEFFICIENT PLOT
* ==============================================================================

postclose nres
preserve
use `nresf', clear
export delimited using "results/tables/N1_network_results${SFX}.csv", replace
di as text "  wrote results/tables/N1_network_results${SFX}.csv (" _N " estimates)"

* Coefficient plot: main ITT and LATE for the five classes and return gap,
* with 95% CIs. The five class coefficients sum to 0 within each panel.
keep if inlist(spec, "main_itt", "main_iv") & outcome != "net_ldeg_hist"
gen byte k = .
local j 0
foreach y in net_incumbent net_prior_other net_indirect net_outsider net_newobs net_return_gap {
    local ++j
    replace k = `j' if outcome == "`y'"
}
label define nk_l 1 "Incumbent" 2 "Prior supplier" 3 "Indirect" 4 "Outsider" ///
    5 "New to market" 6 "Return after gap", replace
label values k nk_l
gen float lo = b - 1.96*se
gen float hi = b + 1.96*se
foreach s in main_itt main_iv {
    local tt = cond("`s'" == "main_itt", "ITT (below × post)", "LATE (direct award)")
    twoway (rcap lo hi k if spec == "`s'", horizontal lcolor(navy%60)) ///
        (scatter k b if spec == "`s'", mcolor(navy)), ///
        xline(0, lcolor(gs8) lpattern(dot)) ylabel(1/6, valuelabel angle(0) labsize(small)) ///
        yscale(reverse) ytitle("") xtitle("Effect on the share of lots", size(small)) ///
        title("`tt'", size(medsmall)) legend(off) graphregion(color(white)) ///
        name(c_`s', replace)
}
graph combine c_main_itt c_main_iv, cols(2) graphregion(color(white)) ///
    title("Who wins below 139k after the reform ($CTRL_G vs P2)", size(medium)) ///
    note("95% CIs, SEs clustered by authority. Classes 1-5 are exhaustive: their coefficients sum to 0.", size(vsmall))
graph export "results/figures/N2_network_coef${SFX}.png", width(2400) replace
restore

drop ncell net_tie treat_band round5k below_post below_x post_x below_post_x x2

* RESULTS PART 7 (main run; P1b control, h=40k, N = 53,352 lots
* with a winner; KP F = 456.6; the five class ITTs sum to −1e-15):
*                         ITT              p       LATE      P0 control (ITT, p)
*   incumbent           −0.012 (0.014)   0.38    −0.027     −0.022 (0.03)
*   prior supplier      −0.050 (0.021)   0.018   −0.114     −0.055 (0.001)
*   indirect            +0.026 (0.018)   0.15    +0.058     +0.021 (0.10)
*   outsider            −0.014 (0.017)   0.42    −0.031     +0.011 (0.37)
*   NEW TO THE MARKET   +0.050 (0.019)   0.007   +0.114     +0.045 (<0.001)
*   return after a gap  −0.036 (0.021)   0.089   −0.082     −0.053 (0.001)
*   log degree          −0.135 (0.058)   0.019   −0.307     −0.085 (0.025)
* Raw shares (7.1): new to the market 0.205/0.215 (P1b above/below) vs
* 0.177/0.272 (P2 above/below); existing supplier (incumbent + prior) falls
* below the cutoff in P2 only.
*
* ROBUSTNESS of "new to the market": h=20k +0.044 (p=0.09), 30k +0.050 (0.02),
* 60k +0.050 (0.001); quadratic +0.050 (0.07); donuts 1k/2.5k/5k +0.061/
* +0.068/+0.047 (all p<0.05); no lots at 139,000 +0.045 (0.016); fixed
* pre-reform network +0.058 (0.003); CPV3 markets +0.049 (0.013); value-band
* DiD +0.034 (0.001). Weaker with a 12-month window: +0.028 (0.14), as a
* shorter history labels more firms "new" in both periods.
* Log degree: h=20k −0.128 (0.12), 30k −0.139 (0.04), 60k −0.111 (0.015).
*
* PLACEBOS: at 139k in P1b and P0 all six classes are small (p ≥ 0.13). In
* P2, 100k and 160k are clean; 200k is borderline for indirect (−0.036,
* p=0.08) and return after a gap (+0.042, p=0.10). At 120k "new to the
* market" fails as estimated: −0.049 (0.014), p = 0.0005, but this is a
* round-number artefact: without the €120,000 lots it is −0.009 (p=0.55);
* see 7.4c. The main result holds without multiples of €5,000 (+0.047,
* p=0.024).
*
* READING: below 139k after the reform, about 5 pp of lots move away from the
* authority's previous suppliers to firms with NO award in that market in the
* previous 24 months (11 pp for lots that switched to direct award). Returns
* after a gap do not rise, and winners have smaller networks. This fits
* OPENING of the market rather than rotation among known firms. Which other
* class (indirect vs outsider) gains or loses is not determined: their signs
* differ between controls, and in the binned plot (descriptive, no FE)
* outsiders rise and indirect firms fall below the cutoff in P2, the opposite
* of the regression signs, so that split depends on the sector/region/month
* controls.




* ##############################################################################
* ##############################################################################
* ##                                                                          ##
* ##   PART 8: EXPORT RESULTS FOR THE REPORTS                                 ##
* ##                                                                          ##
* ##   Writes results/tables/coefficients${SFX}.csv (every reported estimate) ##
* ##   and the LaTeX tables in results/tables/tex/ used by                    ##
* ##   report_pdf/report.tex. No estimation here: only formatting.            ##
* ##                                                                          ##
* ##############################################################################
* ##############################################################################
*
* WHAT goes in the tables: every
* significant result, the placebos (they are meant to be null), and the nulls
* that rule out a competing story (e.g. incumbents are not favoured). Results
* that are inconclusive or replaced by a better measure are listed once, in
* the "dropped" table, with the reason. All coefficients read as
* below 139k MINUS above 139k (rdrobust signs are flipped by rpost).
* Stars: * p < 0.10, ** p < 0.05, *** p < 0.01. SEs clustered by authority
* unless stated.

di as text _n "========================================"
di as text    "  PART 8: EXPORT TABLES"
di as text    "========================================"

postclose RES
postclose DESC
preserve
use "data/intermediate/_descriptives${SFX}.dta", clear
export delimited using "results/tables/descriptives${SFX}.csv", replace
di as text "  wrote results/tables/descriptives${SFX}.csv (" _N " numbers)"
restore
erase "data/intermediate/_descriptives${SFX}.dta"
capture mkdir "results/tables/tex"
local T "results/tables/tex"

* ---- 8.1 Main tables with esttab (stored estimates of Parts 4, 5, 7) ----
* One column per outcome. Panel A: ITT, N, control-period mean below 139k.
* Panel B: LATE (direct award instrumented by below×post), Kleibergen–Paap F.

* Part I: speed of the award (4.8 split sample, so the two parts add up)
tab_main using "`T'/I_main_speed${SFX}.tex", ///
    itt(rf_itt_days_award rf_itt_bid_window rf_itt_eval_days) ///
    iv(rf_iv_days_award rf_iv_bid_window rf_iv_eval_days) ///
    titles("Days to award" "Publication to deadline" "Deadline to award")

* Part I: bids, price and award criterion
tab_main using "`T'/I_main_bids${SFX}.tex", ///
    itt(itt_single_bid itt_lratio rf_itt_meat rf_itt_crit_recorded) ///
    iv(iv_single_bid iv_lratio rf_iv_meat rf_iv_crit_recorded) ///
    titles("Single bid" "Log(award/base)" "MEAT criterion" "Criterion recorded")

* Part II: who wins (supplier history)
tab_main using "`T'/II_main${SFX}.tex", ///
    itt(c_itt_new_supplier c_itt_new_firm_12m c_itt_new_firm_24m ///
        c_itt_repeat_winner_24m c_itt_repeat_winner_cpv c_itt_tie_strength) ///
    iv(c_iv_new_supplier c_iv_new_firm_12m c_iv_new_firm_24m ///
       c_iv_repeat_winner_24m c_iv_repeat_winner_cpv c_iv_tie_strength) ///
    titles("\makecell{New to\\authority}" "\makecell{New to PP\\(12m)}" ///
           "\makecell{New to PP\\(24m)}" "\makecell{Repeat\\(24m)}" ///
           "\makecell{Repeat\\(CPV3)}" "\makecell{Prior\\contracts}")

* Part III: network classes (indirect, outsider, log degree: see dropped table)
tab_main using "`T'/III_main${SFX}.tex", ///
    itt(n_itt_net_newobs n_itt_net_prior_other n_itt_net_incumbent n_itt_net_return_gap) ///
    iv(n_iv_net_newobs n_iv_net_prior_other n_iv_net_incumbent n_iv_net_return_gap) ///
    titles("New to market" "Prior supplier" "Incumbent" "Return after gap")

* ---- 8.2 Collector file: all estimates, plus the network results of 7.5 ----
use "data/intermediate/_coefficients${SFX}.dta", clear
tempfile coef
save `coef'
import delimited using "results/tables/N1_network_results${SFX}.csv", clear varnames(1) case(preserve)
gen str24 tbl = "N"
rename spec row
rename outcome col
* network versions (_w12, _base, _cpv3) are columns of the same outcomes
foreach v in _w12 _base _cpv3 {
    replace col = subinstr(col, "`v'", "", 1)
}
gen double lo = b - 1.96*se
gen double hi = b + 1.96*se
rename mean_ctrl_below extra
keep tbl row col b se p N lo hi extra
append using `coef'
* 5.4 / 5.4b: one column; the cell restriction goes into the row id
replace row = row + "_" + col if tbl == "Cconc"
replace col = "b" if tbl == "Cconc"
order tbl row col b se p N lo hi extra
compress
export delimited using "results/tables/coefficients${SFX}.csv", replace
di as text "  wrote results/tables/coefficients${SFX}.csv (" _N " estimates)"
erase "data/intermediate/_coefficients${SFX}.dta"

* ---- 8.3 Grid tables (rows = specifications, columns = outcomes) ----
local m4 "%9.3f %9.1f %9.3f %9.3f"            // direct, days, lratio, single_bid

* Part I: design checks (rdrobust h = 20k, signs flipped to below − above)
textab using "`T'/I_design${SFX}.tex", tbl(design) ///
    rows(cov_has_award fsplac_all fsplac_central fsplac_other) cols(P0 P1b P2) ///
    rowlab("Award record (coverage)" "Direct award, all authorities" ///
           "Direct award, central authorities" "Direct award, other authorities")
textab using "`T'/I_design_did${SFX}.tex", tbl(design) ///
    rows(covdid_has_award) cols(CTRL ALT) rowlab("Coverage, difference in discontinuities")

* Part I: bunching (bootstrap percentile CIs) and its sensitivity
textab using "`T'/I_bunch${SFX}.tex", tbl(bunch) rows(main) cols(P2 ${CTRL_G} diff) ///
    rowlab("Excess mass (bunching estimate)") fmt(%9.1f) ci

* Part I: robustness of the main estimates
textab using "`T'/I_robust${SFX}.tex", tbl(Mrob) ///
    rows(main h20 h30 h60 donut1000 donut2500 donut5000 quad provcl pnrr no139 ///
         nocentral ctrlsize authfe strict altctrl rdrobust vband) ///
    cols(direct days_award lratio single_bid) cfmt(`m4') ///
    rowlab("Main (h = 40k)" "h = 20k" "h = 30k" "h = 60k" "Donut 1k" "Donut 2.5k" ///
           "Donut 5k" "Local quadratic" "Province clusters" "With PNRR lots" ///
           "Without lots at 139,000" "Without central authorities" ///
           "Control for authority size" "Authority fixed effects" ///
           "Strict eligibility (< 139k)" "${ALT_G} as control" ///
           "rdrobust, h = 20k, no FE" "Value-band DiD")
textab using "`T'/I_flags_robust${SFX}.tex", tbl(Mflag) rows(main h20 h60) ///
    cols(meat eval_days) cfmt(%9.3f %9.1f) rowlab("h = 40k" "h = 20k" "h = 60k")
textab using "`T'/I_selection${SFX}.tex", tbl(Msel) rows(main) ///
    cols(awarded_90 awarded_180) rowlab("All lots, h = 40k")

* Part I: placebo cutoffs
textab using "`T'/I_placebo${SFX}.tex", tbl(Mplac) ///
    rows(c100 c120 c160 c200 p139_P1b p139_P0) cols(direct days_award lratio) ///
    cfmt(%9.3f %9.1f %9.3f) ///
    rowlab("100k in P2" "120k in P2" "160k in P2" "200k in P2" "139k in P1b" "139k in P0")

* Part I: outcome cleaning (4.9) and balance test (4.10)
textab using "`T'/I_cleaning${SFX}.tex", tbl(Mclean) rows(main clean wins) ///
    cols(days_award bid_window eval_days single_bid lratio) ///
    cfmt(%9.1f %9.1f %9.1f %9.3f %9.3f) ///
    rowlab("As in the main tables" "Cleaned" "Price ratio winsorized")
textab using "`T'/I_balance${SFX}.tex", tbl(Mbal) ///
    rows(central south services cpv33 lauth_prev pdays) cols(did did_no139 p2) ///
    fmt(%9.3f %9.3f %9.3f %9.3f %9.3f %9.1f) ///
    rowlab("Central authority" "South and islands" "Services" "Medical supplies (CPV 33)" ///
           "Log lots of the authority, previous year" "Predicted days to award")

* Part I: checks of the adoption curve (Part 6)
textab using "`T'/I_speed_checks${SFX}.tex", tbl(Scheck) rows(fakedate compband) ///
    cols(gap) rowlab("Fake reform date in the control period" ///
                     "Comparison band (139--180k vs 180--214k)") fmt(%9.3f %9.3f)

* Part II: robustness and placebos
local c5 "new_supplier new_firm_12m new_firm_24m repeat_winner_24m repeat_winner_cpv"
textab using "`T'/II_robust${SFX}.tex", tbl(Crob) ///
    rows(main h20 h30 h60 authfe altctrl p139_P1b p139_P0) cols(`c5') ///
    rowlab("Main (h = 40k)" "h = 20k" "h = 30k" "h = 60k" "Authority fixed effects" "${ALT_G} as control" ///
           "Placebo: 139k in P1b" "Placebo: 139k in P0")
textab using "`T'/II_concentration${SFX}.tex", tbl(Cconc) ///
    rows(supplier_hhi_all new_share_all hhi_count_n1 hhi_count_n2 same_firm_n2 ///
         S_es_m2_n2 S_es_p0_n2) cols(b) ///
    rowlab("HHI by value, all cells" "Share of firms new to the authority" ///
           "HHI by count, all cells" "HHI by count, cells with 2+ contracts" ///
           "S (same firm), cells with 2+ contracts" ///
           "S: exposure \texttimes{} semester -2 (pre-reform)" ///
           "S: exposure \texttimes{} semester 0")

* Part III: robustness and placebos
textab using "`T'/III_robust${SFX}.tex", tbl(N) ///
    rows(main_itt h20 h30 h60 quad donut1000 donut2500 donut5000 no139 main_nor5 ///
         authfe w12 base cpv3 alt_ctrl vband) ///
    cols(net_newobs net_prior_other net_incumbent net_return_gap) ///
    rowlab("Main (h = 40k)" "h = 20k" "h = 30k" "h = 60k" "Local quadratic" ///
           "Donut 1k" "Donut 2.5k" "Donut 5k" "Without lots at 139,000" ///
           "Without multiples of 5k" "Authority fixed effects" "12-month window" ///
           "Network fixed before reform" "CPV3 markets" "${ALT_G} as control" "Value-band DiD")
textab using "`T'/III_placebo${SFX}.tex", tbl(N) ///
    rows(plac139P1b plac139P0 plac100 plac120 plac120_noc plac120_nor5 plac160 plac200) ///
    cols(net_newobs net_prior_other net_incumbent net_return_gap) ///
    rowlab("139k in P1b" "139k in P0" "100k in P2" "120k in P2" ///
           "120k in P2, without lots at 120,000" "120k in P2, without multiples of 5k" ///
           "160k in P2" "200k in P2")

* Dropped results: inconclusive, or replaced by a better measure
preserve
keep if (tbl == "Mrob" & row == "main" & inlist(col, "nbids", "n_invited")) | ///
        (tbl == "Cconc" & row == "same_firm_n5") | ///
        (tbl == "N" & row == "main_itt" & inlist(col, "net_indirect", "net_outsider", "net_ldeg_hist"))
replace row = cond(tbl == "N" | tbl == "Mrob", col, row)
replace tbl = "drop"
replace col = "b"
tempfile drop
save `drop'
restore
append using `drop'
textab using "`T'/X_dropped${SFX}.tex", tbl(drop) ///
    rows(nbids n_invited same_firm_n5 net_indirect net_outsider net_ldeg_hist) cols(b) ///
    rowlab("Number of bids" "Number of firms invited" "S, cells with 5+ contracts" ///
           "Indirect (two steps from the authority)" "Outsider (no path)" ///
           "Log degree of the winner") fmt(%9.2f %9.1f %9.3f %9.3f %9.3f %9.3f)

* ---- 8.4 Tables from the CSV outputs of Parts 3 and 6 ----
* Bunching sensitivity (3.5)
import delimited using "results/tables/B3_bunching_sensitivity${SFX}.csv", clear varnames(1) case(preserve)
tempname fh
file open `fh' using "`T'/I_bunch_sens${SFX}.tex", write replace
forvalues i = 1/`=_N' {
    local lab = label[`i']
    local lab = subinstr("`lab'", "main: ", "Main: ", 1)
    file write `fh' "`lab' & " %5.1f (bP2[`i']) " & " %5.1f (b${CTRL_G}[`i']) ///
        " & " %5.1f (b_diff[`i']) " \\" _n
}
file close `fh'

* Bunching by group (3.6)
import delimited using "results/tables/B5_bunching_by_group${SFX}.csv", clear varnames(1) case(preserve)
file open `fh' using "`T'/I_bunch_groups${SFX}.tex", write replace
local prev ""
forvalues i = 1/`=_N' {
    local grp = grouping[`i']
    if "`grp'" != "`prev'" {
        local head = cond("`grp'" == "contract", "Contract type", ///
            cond("`grp'" == "central", "Central vs other authorities", ///
            cond("`grp'" == "macro", "Macro area", "Legal type of authority (ANAC register)")))
        if "`prev'" != "" file write `fh' "\addlinespace" _n
        file write `fh' "\multicolumn{5}{l}{\textit{`head'}} \\" _n
        local prev "`grp'"
    }
    local lev = level[`i']
    local gap = cond(gap[`i'] == 0 & gap_lo[`i'] == 0, "reference", ///
        string(gap[`i'], "%5.1f") + " [" + string(gap_lo[`i'], "%5.1f") + ", " + ///
        string(gap_hi[`i'], "%5.1f") + "]")
    file write `fh' "`lev' & " %5.1f (bP2[`i']) " & " %5.1f (b${CTRL_G}[`i']) ///
        " & " %5.1f (d[`i']) " [" %5.1f (d_lo[`i']) ", " %5.1f (d_hi[`i']) "] & `gap' \\" _n
}
file close `fh'

* Long-run take-up and speed by region (6.2)
import delimited using "results/tables/S2_speed_groups${SFX}.csv", clear varnames(1) case(preserve)
keep if gtype == "region"
gsort -lr
file open `fh' using "`T'/I_speed_regions${SFX}.tex", write replace
forvalues i = 1/`=_N' {
    local nm = proper(gname[`i'])
    file write `fh' "`nm' & " %9.0fc (n_band_p2[`i']) " & " %5.2f (lr[`i']) ///
        " {\footnotesize (" %4.2f (lr_se[`i']) ")} & " %5.2f (c1[`i']) ///
        " {\footnotesize (" %4.2f (c1_se[`i']) ")} & " %5.2f (c2[`i']) " \\" _n
}
file close `fh'

di as text "  wrote LaTeX tables to `T'/"



* ##############################################################################
* ##############################################################################
* ##                                                                          ##
* ##   END                                                                    ##
* ##                                                                          ##
* ##############################################################################
* ##############################################################################

di as text _n "========================================"
di as text    "  ANALYSIS COMPLETE"
di as text    "========================================"
di as text    "  All results are in the log file."
di as text    "  Figures: results/figures/"
di as text    "  Tables:  results/tables/"

log close
