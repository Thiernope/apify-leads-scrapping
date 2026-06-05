#!/usr/bin/env bash
#
# Step 3 — For the hiring companies, find the finance/ops DECISION-MAKER + email,
# and attach the job post(s) that flagged each company (the outreach hook).
# Actor: harvestapi/linkedin-profile-search  ("Full + email search" mode).
#
# Money-saver: companies already enriched on a previous run (tracked in
# data/state/seen_companies.txt) are skipped, so we never pay to enrich twice.
# If every candidate company is already done, the actor is not called at all.
#
#   --in   <file>   prospects CSV from step 2  (required)
#   --companies N    how many NEW companies to enrich  (default: 25)
#   --max       N    max profiles to return total      (default: 25)
#   --titles "<a,b>" comma-separated decision-maker titles
#   --run-dir <dir>  run folder (defaults to the folder of --in)
#   --yes            skip the y/n confirmation (for automation)
#   --dry-run        show the actor input without spending credits
#
# Example:
#   ./scripts/3_find_decision_makers.sh --in data/runs/<ts>_global/prospects.csv \
#       --companies 5 --max 5
#
# Outputs: <run-dir>/decisionmakers.csv  +  appends data/master_leads.{csv,jsonl}

set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a
. "$(dirname "$0")/lib.sh"
ensure_state

IN=""; NCOMP=25; MAXP=25; DRYRUN=""; RUN_DIR=""
TITLES="CFO,Chief Financial Officer,Finance Director,Finance Manager,Controller,VP Finance,Head of Accounting,Head of Procurement"
while [ $# -gt 0 ]; do
  case "$1" in
    --in) IN="$2"; shift 2;;
    --companies) NCOMP="$2"; shift 2;;
    --max) MAXP="$2"; shift 2;;
    --titles) TITLES="$2"; shift 2;;
    --run-dir) RUN_DIR="$2"; shift 2;;
    --yes) ASSUME_YES=1; shift;;
    --dry-run) DRYRUN="1"; shift;;
    *) echo "Unknown option: $1" >&2; exit 1;;
  esac
done
[ -z "$IN" ] && { echo "Required: --in <prospects.csv>" >&2; exit 1; }
[ -z "$RUN_DIR" ] && RUN_DIR="$(dirname "$IN")"
JOBS="${RUN_DIR}/jobs.json"
OUT="${RUN_DIR}/decisionmakers.csv"

# Build the actor input: only companies NOT already in the seen-companies ledger.
INPUT_JSON=$(python3 - "$IN" "$NCOMP" "$MAXP" "$TITLES" "$STATE_DIR/seen_companies.txt" <<'PY'
import sys, csv, json
infile, ncomp, maxp, titles, ledger = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
def norm(u): return (u or "").strip().split("?")[0].rstrip("/").lower()
seen = set(norm(l) for l in open(ledger) if l.strip())
urls = []
for r in csv.DictReader(open(infile)):
    u = (r.get("CompanyLinkedinUrl") or "").strip()
    if not u or norm(u) in seen:      # skip blanks and already-enriched companies
        continue
    urls.append(u)
    if len(urls) >= ncomp:
        break
print(json.dumps({"profileScraperMode": "Full + email search", "currentCompanies": urls,
    "currentJobTitles": [t.strip() for t in titles.split(",") if t.strip()], "maxItems": maxp}))
PY
)
NNEW=$(echo "$INPUT_JSON" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["currentCompanies"]))')

echo "▶ Decision-maker search: ${NNEW} new companies (max ${MAXP} profiles), run-dir=${RUN_DIR}"
if [ "$NNEW" -eq 0 ]; then
  echo "✓ 0 new companies (all candidates already enriched on a prior run) — skipping Step 3, \$0.00 spent."
  exit 0
fi
if [ -n "$DRYRUN" ]; then
  echo "  Actor input that would be sent:"; echo "$INPUT_JSON" | python3 -m json.tool
  echo "✓ --dry-run: not calling Apify, no credits spent."
  exit 0
fi

EST="$(python3 -c "print('%.2f'%(${NNEW}*0.02))")"
confirm "Enrich ${NNEW} companies now (rough est. ~\$${EST})?" || exit 0

RUN=$(apify actors call "harvestapi/linkedin-profile-search" -i "$INPUT_JSON" --user-agent "$UA" --json 2>/dev/null)
RID=$(echo "$RUN" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))")
DS=$(echo "$RUN"  | python3 -c "import sys,json;print(json.load(sys.stdin)['defaultDatasetId'])")
STATUS=$(echo "$RUN" | python3 -c "import sys,json;print(json.load(sys.stdin).get('status',''))")
SMSG=$(echo "$RUN"   | python3 -c "import sys,json;print(json.load(sys.stdin).get('statusMessage') or '')")
# "SUCCEEDED" only means the actor finished without crashing — not that it returned data.
echo "  actor run finished: ${STATUS}${SMSG:+ (\"$SMSG\")} | dataset: ${DS}"

# Fetch the dataset, retrying if the first pull comes back empty (a transient quirk
# right after the run finishes — see harvestapi-profile-search-quirks memory).
RAW="${RUN_DIR}/_raw_profiles.json"
fetch_ok=""
for attempt in 1 2 3; do
  apify datasets get-items "$DS" --user-agent "$UA" --format json 2>/dev/null > "$RAW" || true
  if python3 -c "import json;json.load(open('$RAW'))" 2>/dev/null; then fetch_ok="1"; break; fi
  sleep 2
done
[ -z "$fetch_ok" ] && { echo "✗ Could not fetch dataset $DS after retries. It's paid for — re-run the flatten later." >&2; exit 1; }

# Flatten to the run's decisionmakers.csv (per-person, with job attachment). The
# company-centric master_leads.csv/.jsonl are built afterwards by build_leads.py.
python3 - "$RAW" "$JOBS" "$OUT" <<'PY'
import sys, json, csv, os, re
raw, jobs_path, out_csv = sys.argv[1:4]
data = json.load(open(raw))
jobs = json.load(open(jobs_path)) if os.path.exists(jobs_path) else []

def norm(u): return (u or "").strip().split("?")[0].rstrip("/").lower()
def keyname(n): return re.sub(r"[^a-z0-9]", "", (n or "").lower())
def webmail(e): return any(d in e.lower() for d in ["gmail","yahoo","hotmail","outlook","icloud"])
def clean(t): return re.sub(r"\s+", " ", (t or "")).strip()

# Index jobs by company URL AND company name — the name fallback fixes the case where
# the job's company page slug differs from the person's (e.g. a "…careers" page).
jobs_by_url, jobs_by_name = {}, {}
for j in jobs:
    u = norm(j.get("companyLinkedinUrl"))
    if u: jobs_by_url.setdefault(u, []).append(j)
    n = keyname(j.get("companyName"))
    if n: jobs_by_name.setdefault(n, []).append(j)
sk = lambda j: (j.get("postedAt") or "", j.get("applicantsCount") or 0)  # top = newest, then most applicants

FIELDS = ["Name","Title","Company","Location","Email","EmailType","LinkedIn","OpenRoles",
          "SourceRoles","TopJobTitle","TopJobUrl","TopJobPostedAt","JobLocation",
          "JobFunction","JobSummary","JobIds"]

run_rows = []
for p in data:
    name = ((p.get("firstName") or "")+" "+(p.get("lastName") or "")).strip()
    cp = p.get("currentPosition") or []
    pos = cp[0] if (isinstance(cp, list) and cp) else {}
    comp = pos.get("companyName", "")
    title = pos.get("position") or pos.get("title") or (p.get("headline") or "")
    emails = [e.get("email") if isinstance(e, dict) else str(e) for e in (p.get("emails") or [])]
    corp = [e for e in emails if not webmail(e)]
    email = corp[0] if corp else (emails[0] if emails else "")
    loc = p.get("location") or {}
    li = p.get("linkedinUrl", "")
    cojobs = jobs_by_url.get(norm(pos.get("companyLinkedinUrl"))) or jobs_by_name.get(keyname(comp)) or []
    cojobs = sorted(cojobs, key=sk, reverse=True)
    top = cojobs[0] if cojobs else {}
    roles = list(dict.fromkeys(clean(j.get("title")) for j in cojobs if j.get("title")))
    run_rows.append({
        "Name": name, "Title": clean(title)[:80], "Company": comp,
        "Location": (loc.get("linkedinText") if isinstance(loc, dict) else loc) or "",
        "Email": email,
        "EmailType": "corporate" if email and not webmail(email) else ("personal" if email else "none"),
        "LinkedIn": li, "OpenRoles": len(cojobs), "SourceRoles": " | ".join(roles),
        "TopJobTitle": clean(top.get("title")),
        "TopJobUrl": top.get("link") or top.get("jobUrl") or "",
        "TopJobPostedAt": top.get("postedAt") or "", "JobLocation": clean(top.get("location")),
        "JobFunction": clean(top.get("jobFunction")),
        "JobSummary": clean(top.get("descriptionText"))[:300],
        "JobIds": " | ".join(str(j.get("id")) for j in cojobs if j.get("id") is not None),
    })

run_rows.sort(key=lambda r: 0 if r["EmailType"] == "corporate" else (1 if r["EmailType"] == "personal" else 2))
with open(out_csv, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=FIELDS); w.writeheader(); w.writerows(run_rows)
print(f"✓ {len(run_rows)} decision-makers this run "
      f"({sum(1 for r in run_rows if r['Email'])} with email) -> {out_csv}")
PY

NPROF=$(python3 -c "import json;print(len(json.load(open('$RAW'))))" 2>/dev/null || echo 0)
rm -f "$RAW"
USD=$(log_cost "$RID" "enrich" "harvestapi/linkedin-profile-search" "$NNEW")

if [ "$NPROF" -eq 0 ]; then
  # Returned nothing — almost always the Apify free-plan run limit for this premium
  # pay-per-event actor (separate from your $ credit), a rate limit, or a transient
  # error — NOT "these companies have no decision-maker". So do NOT burn the companies;
  # the next run retries them once the limit resets / you upgrade.
  # The actor run "SUCCEEDED" (finished cleanly) but returned nothing. Apify's own
  # statusMessage usually says why — surface it verbatim so the cause is definitive.
  [ -n "$SMSG" ] && warn "Apify says: \"$SMSG\""
  banner "$C_YEL" \
    "ENRICHMENT RETURNED 0 PROFILES  (cost \$${USD})" \
    "" \
    "The actor finished OK but did no work. Usual cause: the" \
    "Apify free-plan run limit for this premium pay-per-event" \
    "actor (separate from your \$ credit), or a rate limit." \
    "" \
    "These ${NNEW} companies were NOT marked done; they retry next run." \
    "Check plan/usage:  https://console.apify.com/billing"
  exit 0
fi

# Got results — mark these companies as enriched so future runs skip them (no re-pay).
echo "$INPUT_JSON" | python3 -c 'import sys,json;[print(u) for u in json.load(sys.stdin)["currentCompanies"]]' >> "$STATE_DIR/seen_companies.txt"
echo "✓ Step 3 done -> ${OUT}   (actual cost: \$${USD})"
