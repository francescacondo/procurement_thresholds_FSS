* ==============================================================================
* Project D: Direct-award thresholds in Italian procurement
* MASTER DO-FILE — runs the whole project from raw data to report tables
*
* Run from the project root:   stata-se -b do code/00_master.do
*
* Steps
*   1. code/01_download.do   downloads the ANAC files into data/raw/ (files
*                            already there are skipped). The CIG files of 2015–
*                            2017 and 2024 and the partecipanti file are fetched
*                            by the network build (code/net_py/net_phase0_data.py).
*                            Files that must be downloaded by hand (the ANAC
*                            portal blocks scripts for them): the register of
*                            contracting authorities, data/raw/
*                            stazioni-appaltanti_csv.zip, and the law texts in
*                            data/raw/law/.
*   2. code/full_analysis_commented.do   Parts 1–8: data, design checks,
*                            bunching, main diff-in-disc, competition, speed of
*                            adjustment, network extension (Part 7 runs the
*                            Python build code/net_master.do when needed),
*                            export of all estimates and LaTeX tables.
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

* --- Step 1: raw data ---
do code/01_download.do

* --- Step 2: full analysis (main control period P1b) ---
* For the robustness run with P0 as control, set: global CTRL "P0"
do code/full_analysis_commented.do
