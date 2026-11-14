* ==============================================================================
* 01_download.do — Download raw data from ANAC open-data portal
* ==============================================================================
capture mkdir "code/logs"     // logs are not in the repository
log using "code/logs/01_download.log", replace

local base "https://dati.anticorruzione.it/opendata/download/dataset"
local fails 0

* --- 1. CIG monthly files, 2018–2023 (72 zips) ---
di as text _n "=== Downloading CIG monthly files 2018-2023 ==="
forvalues y = 2018/2023 {
    forvalues m = 1/12 {
        local mm : display %02.0f `m'
        local url "`base'/cig-`y'/filesystem/cig_csv_`y'_`mm'.zip"
        local dest "data/raw/cig_`y'_`mm'.zip"
        capture confirm file "`dest'"
        if _rc {
            di as text "  Downloading cig_`y'_`mm'.zip ..."
            capture copy "`url'" "`dest'", replace
            if _rc {
                di as error "  FAILED: cig_`y'_`mm'.zip (rc = " _rc ")"
                local fails = `fails' + 1
            }
        }
        else {
            di as text "  Already exists: cig_`y'_`mm'.zip"
        }
    }
}

* --- 2. Awards file (aggiudicazioni) ---
di as text _n "=== Downloading aggiudicazioni ==="
local dest "data/raw/aggiudicazioni_csv.zip"
capture confirm file "`dest'"
if _rc {
    di as text "  Downloading aggiudicazioni_csv.zip (~759 MB) ..."
    capture copy "`base'/aggiudicazioni/filesystem/aggiudicazioni_csv.zip" "`dest'", replace
    if _rc {
        di as error "  FAILED: aggiudicazioni_csv.zip (rc = " _rc ")"
        local fails = `fails' + 1
    }
}
else {
    di as text "  Already exists: aggiudicazioni_csv.zip"
}

* --- 3. Winning firms (aggiudicatari) ---
di as text _n "=== Downloading aggiudicatari ==="
local dest "data/raw/aggiudicatari_csv.zip"
capture confirm file "`dest'"
if _rc {
    di as text "  Downloading aggiudicatari_csv.zip (~800 MB) ..."
    capture copy "`base'/aggiudicatari/filesystem/aggiudicatari_csv.zip" "`dest'", replace
    if _rc {
        di as error "  FAILED: aggiudicatari_csv.zip (rc = " _rc ")"
        local fails = `fails' + 1
    }
}
else {
    di as text "  Already exists: aggiudicatari_csv.zip"
}

* --- 4. Procedure-type code list ---
di as text _n "=== Downloading procedure-type code list ==="
local dest "data/raw/bandi_cig_tipo_scelta_contraente.csv"
capture confirm file "`dest'"
if _rc {
    di as text "  Downloading bandi_cig_tipo_scelta_contraente ..."
    capture copy "`base'/bandi-cig-tipo-scelta-contraente/filesystem/bandi_cig_tipo_scelta_contraente.csv" "`dest'", replace
    if _rc {
        di as text "  First URL failed, trying JSON variant ..."
        capture copy "`base'/bandi-cig-tipo-scelta-contraente/filesystem/bandi_cig_tipo_scelta_contraente.json" ///
            "data/raw/bandi_cig_tipo_scelta_contraente.json", replace
        if _rc {
            di as error "  FAILED: bandi_cig_tipo_scelta_contraente (rc = " _rc ")"
            local fails = `fails' + 1
        }
    }
}
else {
    di as text "  Already exists: bandi_cig_tipo_scelta_contraente.csv"
}

* --- Summary ---
di as text _n "=== Download summary ==="
di as text "  Failed downloads: `fails'"
if `fails' > 0 {
    di as error "  WARNING: Some downloads failed. Check the log above."
    di as error "  You may need to download these files manually into data/raw/."
}

log close
