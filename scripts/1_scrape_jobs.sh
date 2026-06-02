#!/usr/bin/env bash
#
# Step 1 — Scrape Cellilox-replaceable job postings via Apify (DYNAMIC).
# Actor: curious_coder/linkedin-jobs-scraper  ($0.001 per job result)
#
# All knobs are optional flags — omit --location/--geoid for a GLOBAL scrape.
#
#   --titles  "<a,b,c>"   Job-posting roles as a comma-separated list; each is
#                         quoted and joined with OR automatically.
#                         e.g. --titles "Data Entry Clerk,Accounts Payable,Bookkeeper"
#   --keywords "<query>"  Raw LinkedIn keyword query (advanced; supports boolean
#                         operators). Overrides --titles if both are given.
#                         default: the 4 document-work roles below
#   --location "<text>"   Free-text place, e.g. "Kenya", "London", "United States"
#   --geoid   "<id>"      Precise LinkedIn geoId (overrides --location ambiguity)
#   --days     N          Posted within last N days   (default: 7)
#   --count    N          Max jobs to scrape (cost cap) (default: 300)
#   --remote              Only remote jobs
#
# Examples:
#   ./scripts/1_scrape_jobs.sh                                   # global, defaults
#   ./scripts/1_scrape_jobs.sh --titles "Bookkeeper,AP Clerk,Order Processing"
#   ./scripts/1_scrape_jobs.sh --location "Kenya" --count 200
#   ./scripts/1_scrape_jobs.sh --geoid 104843105 --days 30       # Rwanda, last 30d
#   ./scripts/1_scrape_jobs.sh --keywords '"Bookkeeper" AND "remote"' --remote
#
# Common geoIds:  Worldwide 92000000 | United States 103644278 |
#   United Kingdom 101165590 | Kenya 100710459 | Rwanda 104843105 |
#   United Arab Emirates 104305776 | India 102713980 | Canada 101174742

set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

. "$(dirname "$0")/lib.sh"
ensure_state

# ---- defaults ----
DEFAULT_TITLES="Accounts Payable,Document Controller,Invoice Processing,Data Entry Clerk"
TITLES=""; KEYWORDS=""; LOCATION=""; GEOID=""; DAYS=7; COUNT=300; REMOTE=""; DRYRUN=""; RUN_DIR=""

# ---- parse flags (any order, freely combined) ----
while [ $# -gt 0 ]; do
  case "$1" in
    --titles)   TITLES="$2";   shift 2;;
    --keywords) KEYWORDS="$2"; shift 2;;
    --location) LOCATION="$2"; shift 2;;
    --geoid)    GEOID="$2";    shift 2;;
    --days)     DAYS="$2";     shift 2;;
    --count)    COUNT="$2";    shift 2;;
    --remote)   REMOTE="1";    shift;;
    --run-dir)  RUN_DIR="$2";  shift 2;;
    --yes)      ASSUME_YES=1;  shift;;
    --dry-run)  DRYRUN="1";    shift;;
    *) echo "Unknown option: $1" >&2; exit 1;;
  esac
done

# Build the keyword query: explicit --keywords wins; else quote+OR the title list.
build_query() { python3 -c "import sys;print(' OR '.join('\"%s\"'%t.strip() for t in sys.argv[1].split(',') if t.strip()))" "$1"; }
if [ -z "$KEYWORDS" ]; then
  KEYWORDS="$(build_query "${TITLES:-$DEFAULT_TITLES}")"
fi

enc() { python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$1"; }

# ---- build LinkedIn Jobs search URL ----
URL="https://www.linkedin.com/jobs/search/?keywords=$(enc "$KEYWORDS")"
[ -n "$LOCATION" ] && URL="${URL}&location=$(enc "$LOCATION")"
[ -n "$GEOID" ]    && URL="${URL}&geoId=${GEOID}"
URL="${URL}&f_TPR=r$((DAYS*86400))"
[ -n "$REMOTE" ]   && URL="${URL}&f_WT=2"

# ---- run folder (created here if not handed one by run_daily.sh) ----
SLUG="$(make_slug "$LOCATION" "$GEOID")"
[ -z "$RUN_DIR" ] && RUN_DIR="${RUNS_DIR}/$(stamp)_${SLUG}"
mkdir -p "$RUN_DIR"
OUT="${RUN_DIR}/jobs.json"
EST="$(python3 -c "print('%.2f'%(${COUNT}*0.001))")"

echo "▶ Scrape: keywords=[${KEYWORDS}]"
echo "  location=[${LOCATION:-GLOBAL}] geoId=[${GEOID:-none}] days=${DAYS} count=${COUNT} remote=${REMOTE:-no}"
echo "  URL: ${URL}"
echo "  Output -> ${OUT}   (est. cost up to ~\$${EST} at \$0.001/job)"

if [ -n "$DRYRUN" ]; then
  echo "✓ --dry-run: not calling Apify, no credits spent."
  exit 0
fi

confirm "Scrape up to ${COUNT} jobs now (~\$${EST})?" || exit 0

RUN=$(apify actors call "curious_coder/linkedin-jobs-scraper" \
  -i "{\"urls\":[\"${URL}\"],\"count\":${COUNT},\"scrapeCompany\":true}" \
  --user-agent "$UA" --json 2>/dev/null)
RID=$(echo "$RUN" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))")
DS=$(echo "$RUN" | python3 -c "import sys,json;print(json.load(sys.stdin)['defaultDatasetId'])")
echo "  status: $(echo "$RUN" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])") | dataset: ${DS}"

apify datasets get-items "$DS" --user-agent "$UA" --format json > "$OUT"

# Report new-vs-seen jobs and append new IDs to the ledger (informational dedup;
# the real money-saver is the company ledger gating Step 3).
python3 - "$OUT" "$STATE_DIR/seen_jobs.txt" <<'PY'
import sys, json
jobs=json.load(open(sys.argv[1])); ledger=sys.argv[2]
seen=set(l.strip() for l in open(ledger) if l.strip())
ids=[str(j.get("id")) for j in jobs if j.get("id") is not None]
new=[i for i in ids if i not in seen]
with open(ledger,"a") as f:
    for i in new: f.write(i+"\n")
print(f"  jobs scraped: {len(ids)} | new since last run: {len(new)} | already-seen: {len(ids)-len(new)}")
PY

USD=$(log_cost "$RID" "scrape" "curious_coder/linkedin-jobs-scraper" "$COUNT")
N=$(python3 -c "import json;print(len(json.load(open('$OUT'))))")
echo "✓ Saved ${N} jobs -> ${OUT}   (actual cost: \$${USD})"
echo "  Next: python3 scripts/2_extract_companies.py ${OUT} --out-dir ${RUN_DIR}"
