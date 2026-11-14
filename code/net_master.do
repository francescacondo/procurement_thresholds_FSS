* ==============================================================================
* net_master.do — NETWORK EXTENSION, Project D (runs the whole pipeline)
*
* Question: are the new winners below €139k after the 2021 reform OUTSIDERS to
* the authority's procurement network (opening) or firms already INSIDE it
* (rotation among a closed group, cf. the "principio di rotazione")?
*
* Division of labour
*   Python (code/net_py/) builds all network measures and writes .dta files
*   keyed on cig (lot level) or authority_id × halfyear (panel).
*   ALL estimation is in Part 7 of code/full_analysis_commented.do (since
*   12 Nov 2026; the former net_estimation.do, the authority panel (Phase 6) and
*   the report-table script are in code/archive/). This file only BUILDS the
*   measures. Re-run it after any change to Parts 1 or 5 of the main file.
*   Python runs inside Stata (python script ...), so its output lands in this log.
*
* How to run (from the project root folder):
*     stata-se -b do code/net_master.do
* or set the global ROOT to the project folder before calling this file.
*
* Existing files are never modified: everything new carries a net_ prefix.
* ==============================================================================

version 19
* When called from Part 7 of full_analysis_commented.do (global NET_FROM_MAIN
* = 1) clear only the data: "clear all" would delete the calling file's
* programs and its open results file.
if "$NET_FROM_MAIN" == "1" clear
else clear all
set more off

* ---- ROOT: the project folder. Every path below is built from it. ------------
* WHY a global and not a hard-coded path? The same file must run on Mac and
* Windows; the Python scripts receive ROOT through args() and build their own
* paths from it.
if `"$ROOT"' == "" global ROOT `"`c(pwd)'"'
capture confirm file `"$ROOT/code/net_master.do"'
if _rc {
    di as error `"ROOT = "$ROOT" is not the project folder (no code/net_master.do)."'
    di as error "cd to the project root first, or set: global ROOT <path to project root>"
    exit 601
}
cd `"$ROOT"'
global PY `"$ROOT/code/net_py"'

* ---- Phase switches: 1 = run, 0 = skip ---------------------------------------
* Each phase reads the files written by the previous ones, so a phase can be
* rerun on its own once its inputs exist.
global RUN_ENV      = 1    // record Python interpreter + package versions
global RUN_PHASE0   = 1    // data acquisition + diagnostics (Python)
global RUN_PHASE1   = 1    // time-respecting network snapshots (Python)
global RUN_PHASE2   = 1    // winner classification (Python)
global RUN_PHASE3   = 1    // winner centrality (Python)
global RUN_PHASE5   = 0    // bidder network: NOT FEASIBLE (partecipanti lists only winners)
global RUN_GRAPHS   = 1    // node-and-link pictures (Python, illustration only; needs Phases 1-3)

* Phase 0 sub-steps (download is skipped automatically for files already present)
global P0_STEPS "download,build,diag"

capture log close net
log using `"$ROOT/code/logs/net_master.log"', replace text name(net)

di as text "net_master.do started $S_DATE $S_TIME | ROOT = $ROOT"
python query


* ==============================================================================
* ENVIRONMENT
* ==============================================================================
if $RUN_ENV {
    python script `"$PY/net_env.py"', args(`""$ROOT""')
}


* ==============================================================================
* PHASE 0 — DATA ACQUISITION AND DIAGNOSTICS
* ==============================================================================
* Python downloads CIG 2015 + 2024 and "partecipanti", re-applies the cleaning
* rules of the existing pipeline, checks that 2018–2023 reproduces lots_v2.dta,
* and writes net_lots_universe.dta, net_edges.dta,
* net_aggiudicatari_allroles.dta, net_partecipanti.dta and the diagnostics.
if $RUN_PHASE0 {
    python script `"$PY/net_phase0_data.py"', args(`""$ROOT""' "$P0_STEPS")

    * ---- Stata-side check of the date round trip (Python -> .dta -> Stata) ----
    * WHY? Python stores dates as Stata day counts. If the conversion were off by
    * one day (or by the 1960 vs 1970 epoch), every "strictly before" comparison
    * in the histories would be wrong. We compare with lots_v2.dta, built by Stata.
    use cig in_lots_v2 pub_date award_date using ///
        "data/intermediate/net_lots_universe.dta" if in_lots_v2 == 1, clear
    rename (pub_date award_date) (pub_date_net award_date_net)
    merge 1:1 cig using "data/intermediate/lots_v2.dta", ///
        keepusing(pub_date award_date) assert(match using) keep(match) nogen
    format pub_date_net award_date_net %td
    count if pub_date_net != pub_date
    assert r(N) == 0
    count if award_date_net != award_date
    assert r(N) == 0
    set seed 20261110
    gen double _u = runiform()
    sort _u
    list cig pub_date pub_date_net award_date award_date_net in 1/5, noobs abbrev(16)
    di as text "  Date round trip OK: pub_date and award_date identical to lots_v2.dta"
}


* ==============================================================================
* PHASE 1 — TIME-RESPECTING NETWORK SNAPSHOTS
* ==============================================================================
* Python builds one sparse authority × supplier matrix per version and focal
* month (24m and 12m windows within CPV2, 24m within CPV3, fixed pre-reform
* baseline, and a 2024-inclusive robustness version) in
* data/intermediate/net_snapshots/, plus net_phase1_focal.dta (timing of each
* focal lot). Every snapshot is checked against a brute-force count.
if $RUN_PHASE1 {
    python script `"$PY/net_phase1_snapshots.py"', args(`""$ROOT""')

    * ---- Stata-side check: one timing row for every lot in lots_winners -------
    use cig period using "data/intermediate/lots_winners.dta", clear
    merge 1:1 cig using "data/intermediate/net_phase1_focal.dta", ///
        keepusing(net_t net_timing_fallback net_window_post2023) assert(match) nogen
    format net_t %td
    tab period net_timing_fallback, m
    tab period net_window_post2023, m
    di as text "  Phase 1 timing table merges 1:1 with lots_winners.dta (all matched)"
}


* ==============================================================================
* PHASE 2 — WINNER CLASSIFICATION
* ==============================================================================
* Python classifies every lots_winners lot into incumbent / prior_other /
* indirect / outsider / newobs (+ return_gap) for six network versions, after
* passing a toy example with known answers and a brute-force check on 500 real
* lots. Output: data/intermediate/net_lot_measures.dta (keyed on cig).
if $RUN_PHASE2 {
    python script `"$PY/net_phase2_classify.py"', args(`""$ROOT""')

    * ---- Stata-side checks ------------------------------------------------------
    * WHY? The five categories must be mutually exclusive and exhaustive for every
    * lot and every version, otherwise their diff-in-disc coefficients could not
    * be read as a decomposition (they must sum to zero).
    use cig using "data/intermediate/lots_winners.dta", clear
    merge 1:1 cig using "data/intermediate/net_lot_measures.dta", assert(match) nogen
    foreach vv in main _w12 _base _cpv3 _mo _y24 {
        local v = cond("`vv'" == "main", "", "`vv'")
        egen byte _s = rowtotal(net_incumbent`v' net_prior_other`v' net_indirect`v' ///
            net_outsider`v' net_newobs`v')
        assert _s == 1
        drop _s
    }
    tab net_class, m
    di as text "  net_lot_measures.dta: 1:1 with lots_winners, five indicators sum to 1 in all versions"
}


* ==============================================================================
* PHASE 3 — WINNER CENTRALITY
* ==============================================================================
* Python adds historical degree, regions, core status and other-authority
* counts of the winner (CPV2, 24-month day-level window) to net_lot_measures.dta.
* net_deg_excess (BiCM) is not built: under the BiCM expected degree = observed
* degree by construction (shown numerically in the log).
if $RUN_PHASE3 {
    python script `"$PY/net_phase3_centrality.py"', args(`""$ROOT""')

    * ---- Stata-side checks ------------------------------------------------------
    * WHY? A winner with no award in the window (newobs) must have degree 0, and
    * every other winner degree >= 1: the two phases must describe the same window.
    use cig using "data/intermediate/lots_winners.dta", clear
    merge 1:1 cig using "data/intermediate/net_lot_measures.dta", assert(match) nogen
    assert (net_deg_hist == 0) == (net_newobs == 1)
    assert net_other_auth == net_deg_hist - (net_incumbent + net_prior_other)
    assert net_regions_hist <= net_deg_hist
    summarize net_deg_hist net_ldeg_hist net_regions_hist net_core net_other_auth net_deg_excess_alloc
    di as text "  Phase 3 variables consistent with Phase 2 classes"
}


* ==============================================================================
* NETWORK PICTURES (illustration only, nothing enters the estimates)
* ==============================================================================
* Python/networkx draws: the five winner classes on the toy network
* (net_graph_schematic.png), one authority's ego network with its post-reform
* winners by class (net_graph_ego.png), and one market before vs after the
* reform (net_graph_market.png), all in results/figures/.
if $RUN_GRAPHS {
    python script `"$PY/net_fig_graphs.py"', args(`""$ROOT""')
}


* ==============================================================================
* PHASE 5 — BIDDER NETWORK: NOT RUN
* ==============================================================================
* Phase 0 showed that "partecipanti" records only the winner (one participant in
* about 98% of lots; it is the winner in 99.8%), so there are no losing bidders
* to build a bidder network from. RUN_PHASE5 must stay 0.
if $RUN_PHASE5 {
    di as error "Phase 5 is not feasible with these data (see docs/net_build_note.md, Phase 0 D2)"
    exit 198
}


* ==============================================================================
* PHASES 4 AND 6 — MOVED / RETIRED (12 Nov 2026)
* ==============================================================================
* Phase 4 (lot-level estimation) is now Part 7 of full_analysis_commented.do,
* with P1b as main comparison period and lots at 139,000 counted as eligible.
* Phase 6 (authority × half-year panel) was dropped: null with P1b and no
* pre-trend test possible (Deviations in pilot_report.md). The old code is in
* code/archive/ (net_estimation.do, net_phase6_panel.py, net_report_tables.py).


di as text _n "net_master.do finished $S_DATE $S_TIME"
log close net
