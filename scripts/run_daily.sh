#!/usr/bin/env bash
#
# Daily one-command pipeline: scrape jobs -> companies -> decision-makers.
# Built-in cost safety: a narrow recency window (--days 1) keeps scraping cheap,
# the company ledger stops Step 3 re-paying for companies already enriched, and
# each paid step asks for y/n confirmation (skip with --yes).
#
#   --location "<text>"  e.g. "Kenya"        (omit both for GLOBAL)
#   --geoid    "<id>"    precise LinkedIn geoId
#   --titles   "<a,b>"   job-post roles to search        (Step 1)
#   --dm-titles "<a,b>"  decision-maker titles to find   (Step 3)
#   --count    N         max jobs to scrape   (default 150 ≈ $0.15)
#   --days     N         recency window       (default 1 — keeps daily runs fresh+cheap)
#   --companies N        max NEW companies to enrich (default 10)
#   --max      N         max decision-maker profiles (default 15)
#   --remote             remote jobs only
#   --yes                no confirmations (automation)
#   --dry-run            preview Step 1 only; spends nothing
#
# Examples:
#   ./scripts/run_daily.sh --location "Kenya" --dry-run        # free preview
#   ./scripts/run_daily.sh --location "Kenya" --companies 3 --max 5
#   ./scripts/run_daily.sh --geoid 104843105 --yes             # Rwanda, unattended

set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a
. "$(dirname "$0")/lib.sh"
ensure_state

LOCATION=""; GEOID=""; TITLES=""; DMTITLES=""; COUNT=150; DAYS=1
NCOMP=10; MAXP=15; REMOTE=""; DRYRUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --location) LOCATION="$2"; shift 2;;
    --geoid) GEOID="$2"; shift 2;;
    --titles) TITLES="$2"; shift 2;;
    --dm-titles) DMTITLES="$2"; shift 2;;
    --count) COUNT="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --companies) NCOMP="$2"; shift 2;;
    --max) MAXP="$2"; shift 2;;
    --remote) REMOTE="--remote"; shift;;
    --yes) ASSUME_YES=1; shift;;
    --dry-run) DRYRUN="--dry-run"; shift;;
    *) echo "Unknown option: $1" >&2; exit 1;;
  esac
done
export ASSUME_YES="${ASSUME_YES:-0}"

SLUG="$(make_slug "$LOCATION" "$GEOID")"
RUN_DIR="${RUNS_DIR}/$(stamp)_${SLUG}"
mkdir -p "$RUN_DIR"
SPEND_BEFORE="$(total_spend)"

echo "════════════════════════════════════════════════════"
echo " Daily lead-gen  ->  ${RUN_DIR}"
echo " geo=[${LOCATION:-GLOBAL}${GEOID:+ geo:$GEOID}] days=${DAYS} count=${COUNT} companies=${NCOMP} max=${MAXP}"
echo "════════════════════════════════════════════════════"

# ---- Step 1: scrape jobs ----
echo; echo "── Step 1: scrape jobs ──"
S1=( ./scripts/1_scrape_jobs.sh --days "$DAYS" --count "$COUNT" --run-dir "$RUN_DIR" )
[ -n "$LOCATION" ] && S1+=( --location "$LOCATION" )
[ -n "$GEOID" ]    && S1+=( --geoid "$GEOID" )
[ -n "$TITLES" ]   && S1+=( --titles "$TITLES" )
[ -n "$REMOTE" ]   && S1+=( "$REMOTE" )
[ -n "$DRYRUN" ]   && S1+=( "$DRYRUN" )
"${S1[@]}"

if [ -n "$DRYRUN" ]; then
  echo; echo "── dry-run: Steps 2 & 3 skipped (no data scraped, \$0 spent). ──"
  exit 0
fi
[ -f "$RUN_DIR/jobs.json" ] || { echo "No jobs scraped; stopping (nothing to do)."; exit 0; }

# ---- Step 2: companies (free) ----
echo; echo "── Step 2: extract companies (free) ──"
python3 scripts/2_extract_companies.py "$RUN_DIR/jobs.json" --out-dir "$RUN_DIR"

# ---- Step 3: decision-makers ----
echo; echo "── Step 3: find decision-makers ──"
MASTER_BEFORE=$(python3 -c "import csv,os;p='$MASTER_CSV';print(sum(1 for _ in csv.reader(open(p)))-1 if os.path.exists(p) else 0)")
S3=( ./scripts/3_find_decision_makers.sh --in "$RUN_DIR/prospects.csv" --run-dir "$RUN_DIR" --companies "$NCOMP" --max "$MAXP" )
[ -n "$DMTITLES" ] && S3+=( --titles "$DMTITLES" )
"${S3[@]}"

# ---- Build the clean, company-centric leads files (one row per company) ----
echo; echo "── Building leads (one row per company, best DM + job post) ──"
python3 scripts/build_leads.py

# ---- summary + run.json + RUNS.md row ----
SPEND_AFTER="$(total_spend)"
RUN_COST="$(python3 -c "print('%.2f'%(${SPEND_AFTER}-${SPEND_BEFORE}))")"
python3 - "$RUN_DIR" "$SLUG" "$MASTER_CSV" "$RUN_COST" "$RUNS_MD" "$MASTER_BEFORE" <<'PY'
import sys, json, csv, os, datetime
run_dir, slug, master, cost, runs_md, mbefore = sys.argv[1:7]
cc = lambda p: (sum(1 for _ in csv.reader(open(p)))-1) if os.path.exists(p) else 0
jobs = len(json.load(open(os.path.join(run_dir, "jobs.json")))) if os.path.exists(os.path.join(run_dir, "jobs.json")) else 0
prospects = cc(os.path.join(run_dir, "prospects.csv"))
dms = cc(os.path.join(run_dir, "decisionmakers.csv"))
master_n = cc(master)
new_leads = master_n - int(mbefore)
when = datetime.datetime.now().isoformat(timespec="minutes")
meta = {"run_dir": run_dir, "slug": slug, "finished": when, "jobs": jobs,
        "prospects": prospects, "decisionmakers_this_run": dms,
        "new_leads": new_leads, "master_total": master_n, "run_cost_usd": cost}
json.dump(meta, open(os.path.join(run_dir, "run.json"), "w"), indent=2)
with open(runs_md, "a") as f:
    f.write(f"| {when} | {slug} | {jobs} | {prospects} | {dms} | {new_leads} | ${cost} |\n")
print(f"  jobs={jobs}  prospects={prospects}  decision-makers={dms}  new_leads={new_leads}  master_total={master_n}")
PY

echo
echo "════════════════════════════════════════════════════"
echo " ✓ Done.  Run cost: \$${RUN_COST}   Total to date: \$$(total_spend)"
echo " LEADS:  ${MASTER_CSV}   ← one row per company, best DM + job post"
echo "         (+ ${MASTER_JSONL} = full job text + other contacts, for AI)"
echo " Run:    ${RUN_DIR}"
echo "════════════════════════════════════════════════════"
