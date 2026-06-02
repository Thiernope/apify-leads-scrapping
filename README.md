# Cellilox Lead Generation

Find companies that are visibly drowning in manual document work (the buying
signal for [Cellilox](https://cellilox.com) document automation), then reach the
finance/ops **decision-maker** at each one with a verified email.

## The pipeline

| Step | Tool | Script | Cost |
|------|------|--------|------|
| 1. Scrape document-work job postings | Apify `curious_coder/linkedin-jobs-scraper` | `scripts/1_scrape_jobs.sh` | ~$0.001 / job |
| 2. Dedupe jobs → companies (drop staffing agencies) | local Python | `scripts/2_extract_companies.py` | free |
| 3. Find decision-maker + verified email per company | Apify `harvestapi/linkedin-profile-search` | `scripts/3_find_decision_makers.sh` | ~$0.10/page + $0.01/profile |
| 4. Push qualified leads to CRM (optional) | HubSpot | (see `docs/WORKFLOW.md`) | free |

Why this order: step 2 collapses hundreds of jobs into far fewer companies, so
the (rate-limited) enrichment in step 3 stays cheap.

> **Note on Apollo:** Apollo's People *Search* API requires a paid plan (the free
> plan returns `API_INACCESSIBLE`). So step 3 uses the Apify profile-search actor
> instead — cheap, no subscription. If you upgrade Apollo later, you can swap step
> 3 to Apollo search + enrichment. See `docs/WORKFLOW.md`.

## Setup

1. Install the Apify CLI: `npm install -g apify-cli`
2. Copy `.env.example` → `.env` and fill in `APIFY_TOKEN` (the only key needed).
3. Make scripts executable: `chmod +x scripts/*.sh`

## Run it

**The easy way — one command for the whole pipeline**, with a y/N confirmation
before each charge and built-in dedup so you never pay twice:

```bash
./scripts/run_daily.sh --location "Kenya" --dry-run   # free preview
./scripts/run_daily.sh --location "Kenya"             # real run, confirms each paid step
```

Results land in `data/master_leads.csv` (deduped, with the job post that flagged
each lead).

- **Quick how-to-run + credit control:** [docs/USAGE.md](docs/USAGE.md)
- **Full command reference** (every script, flag, format, geoIds, troubleshooting): [docs/COMMANDS.md](docs/COMMANDS.md)

---

### Running the steps individually

Every step also takes arguments — scrape globally, by country, by location, by
role, or by recency:

Both the **job-posting roles** (step 1) and the **decision-maker titles** (step 3)
are arguments, so you can re-target the search anytime:

```bash
# Step 1 — scrape jobs (all flags optional; omit location for GLOBAL)
./scripts/1_scrape_jobs.sh                                          # global, defaults
./scripts/1_scrape_jobs.sh --titles "Bookkeeper,AP Clerk,Order Processing"
./scripts/1_scrape_jobs.sh --location "Kenya" --count 200
./scripts/1_scrape_jobs.sh --geoid 104843105 --days 30             # Rwanda, last 30d
./scripts/1_scrape_jobs.sh --keywords '"Bookkeeper" AND "remote"' --remote
#   flags: --titles --keywords --location --geoid --days --count --remote
#   --titles = comma list (auto-quoted+OR);  --keywords = raw query (advanced)

# Step 2 — collapse to unique companies (auto-removes staffing agencies)
python3 scripts/2_extract_companies.py data/<date>_jobs_<slug>.json

# Step 3 — find finance/ops decision-maker + email per company
./scripts/3_find_decision_makers.sh --in data/<date>_prospects_<slug>.csv \
    --companies 20 --max 25 \
    --titles "CFO,Finance Director,Controller,Head of Procurement"
#   flags: --in --companies --max --titles
```

**Combining flags:** all flags can be combined in any order. Add `--dry-run` to
either script to preview the exact LinkedIn URL / actor input **without spending
credits** — handy for sanity-checking a search before running it:

```bash
./scripts/1_scrape_jobs.sh --titles "Bookkeeper,AP Clerk" --location "Kenya" \
    --days 30 --count 150 --remote --dry-run
```

Outputs land in a timestamped run folder `data/runs/<date>_<time>_<place>/`
(`jobs.json`, `companies.csv`, `prospects.csv`, `decisionmakers.csv`), and the
cumulative deduped leads are appended to `data/master_leads.csv` (+ `.jsonl`).

## Budget guardrails

- Job scraping is $0.001/result — **always pass a `count` cap**. "All jobs globally"
  with no cap can be 100k+ postings ($100+).
- Prefer high-intent titles (Accounts Payable, Document Controller, Invoice
  Processing) over generic "Data Entry" to cut volume and raise relevance.
- Do email enrichment in Apollo (your existing credits), not in Apify.

See `docs/WORKFLOW.md` for the full method and the Apollo/HubSpot steps.
