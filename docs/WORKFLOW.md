# Workflow: from job postings to emailable decision-makers

## The thesis
A company posting **"Accounts Payable Clerk" / "Document Controller" /
"Invoice Processing" / "Data Entry Clerk"** is actively spending money on manual
document handling — exactly the work Cellilox automates. The job post is the
*intent signal*. But the clerk isn't the buyer; the **finance/ops leader** who
owns that budget is. So we find the company via the job, then find the leader.

## Step 1 — Scrape jobs (Apify, $0.001/job)
`scripts/1_scrape_jobs.sh` calls `curious_coder/linkedin-jobs-scraper` with a
LinkedIn Jobs search URL. Key knobs:
- **Roles** (in the URL `keywords`): high-intent document titles.
- **Recency** `f_TPR=r604800`: last 7 days = fresh intent + smaller volume.
- **`scrapeCompany: true`**: attaches company name/URL/industry to each job.
- **`count`**: hard cap. Start at 300 (~$0.30).

### Why `curious_coder/linkedin-jobs-scraper` (not `harvestapi/linkedin-job-search`)
We first tried `harvestapi/linkedin-job-search` (the skill's default recruitment
actor). In a real run its text `locations` filter **fuzzily widened "Rwanda"/
"Kenya" → "EMEA"**, returning mostly global remote roles — we couldn't pin the
geography. We switched to `curious_coder/linkedin-jobs-scraper` because:

1. **URL-based input → precise geo.** It takes a raw LinkedIn search URL, so we
   inject an exact `geoId`/recency/remote filter. This is what makes the
   `--location`/`--geoid` flags reliable (no "EMEA" widening).
2. **Clean company linkage.** It returns `companyName`, `companyLinkedinUrl`,
   `companyWebsite`, `industries` as flat fields (~95% coverage) — the exact
   bridge into Step 3 (find the decision-maker by company LinkedIn URL).
3. **Same price** (~$0.001/job) and far higher adoption (~13K users).

Trade-off: `harvestapi/linkedin-job-search` exposes a `hiringTeam` field (the
job's recruiter/poster) that curious_coder lacks — occasionally a direct contact,
though usually not the finance decision-maker we want. Worth revisiting only if we
later want recruiter contacts as a secondary signal.

Note: `harvestapi/linkedin-job-search` may still appear in the Apify "recently
executed" list from that first test. It's a public Store actor (owned by
`harvestapi`), so it can't be deleted — and it costs nothing sitting there.

## Step 2 — Dedupe to companies (free)
`scripts/2_extract_companies.py` collapses jobs into unique companies and counts
open roles per company. A company with several open document roles is a hotter
lead. Output: `data/<date>_companies.csv`.

## Step 3 — Find the decision-maker + email (Apify — cheapest working path)
For each company, find the finance/ops budget owner with a verified email.
Run with `scripts/3_find_decision_makers.sh --in <prospects.csv>`.

It calls `harvestapi/linkedin-profile-search` in **"Full + email search"** mode,
filtering by `currentCompanies` (the LinkedIn URLs carried from step 2) and
`currentJobTitles`. Output: a clean CSV sorted with corporate emails first.

Target titles (priority order):
`CFO` → `Finance Director` → `Finance Manager` → `Financial Controller` →
`Head of Procurement` → `Operations Manager`.

**Why not Apollo (tested 2026-06-02):** Apollo's People *Search* API returns
`API_INACCESSIBLE` on the free plan — programmatic search needs a paid plan
(~$49/mo). The Apify actor needs no subscription (~$0.10/page + $0.01/profile),
so it's the budget choice. If you upgrade Apollo later, swap step 3 to Apollo
`mixed_people/search` + `people/bulk_match` (1 credit/verified email) and set
`APOLLO_API_KEY` in `.env`.

**Free alternative:** company domains are in the prospects CSV (`Website`).
Hunter.io's free tier (25 domain searches/mo) can find finance emails by domain
when you want zero spend.

## Step 4 — Push to CRM (HubSpot — connected)
Qualified leads (verified email + High ICP fit) go straight into HubSpot as
contacts, tagged with the source company and the open role that flagged them.
This workspace already has HubSpot connected.

## Step 5 (optional, later) — Automate with Make.com
Only once the manual run proves the lead quality. Make's free tier (1,000
ops/month) can chain: *schedule → Apify job scrape → Apollo enrich → HubSpot
upsert*. It's an automation layer, not a data source — don't build it first.

## Daily tool + dedup
The three steps are wrapped by `scripts/run_daily.sh` for repeatable daily use.
See [USAGE.md](USAGE.md) for the full guide. Two things make daily runs cheap:

- **Narrow window** (`--days 1`): only yesterday's new postings, so little overlap.
- **Dedup ledgers** in `data/state/`: a company enriched once is recorded in
  `seen_companies.txt` and **never re-enriched** — re-running won't re-charge for it.
  (Caveat: the jobs scraper can't skip already-seen jobs server-side, so Step 1 still
  bills per job scraped; the company ledger protects the expensive Step 3.)

`data/master_leads.csv` is company-centric (one row per company: best decision-maker +
the `JobPost` that flagged them), and `master_leads.jsonl` holds the **full** job
descriptions + backup contacts for a future AI outreach step. Both are rebuilt from all
run folders by `scripts/build_leads.py`, so they are always deduped.

Agencies are filtered **agnostically** (no hardcoded company names): by LinkedIn
industry, generic name tokens, the company URL slug, and — the catch-all — job
descriptions that reveal an intermediary posting "on behalf of a client".

## Cost discipline (measured 2026-06-02)
| Item | Cost |
|------|------|
| 150 jobs | ~$0.15 |
| 300 jobs | ~$0.30 |
| Step 3: ~20 companies → ~24 contacts w/ emails | ~$0.33 |
| Step 2 (companies), HubSpot push | free |

Actual per-run cost is pulled from the Apify API and logged to
`data/state/cost_log.csv`. Always check the Apify dashboard too.
