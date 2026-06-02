# How to run the lead-gen tool (and not overspend)

This is the day-to-day guide. For the *why* behind each step see [WORKFLOW.md](WORKFLOW.md).
For the **complete reference** of every script, flag, location format, geoId list, and
troubleshooting, see [COMMANDS.md](COMMANDS.md).

## One-time setup
```bash
npm install -g apify-cli          # the scraper CLI
cp .env.example .env              # then put your APIFY_TOKEN inside
chmod +x scripts/*.sh             # make scripts runnable
```

## The everyday command
One command runs the whole pipeline (jobs → companies → decision-makers) and asks
you to confirm **before every charge**:

```bash
./scripts/run_daily.sh --location "Kenya"
```

What happens:
1. **Step 1 – scrape jobs** (paid). Shows an estimate, asks `y/N`.
2. **Step 2 – companies** (free). Dedupes jobs into companies, drops staffing agencies.
3. **Step 3 – decision-makers** (paid). Enriches only **new** companies, asks `y/N`.
4. Appends results to `data/master_leads.csv` and prints the run's actual cost.

### Always preview first (costs nothing)
```bash
./scripts/run_daily.sh --location "Kenya" --dry-run
```
`--dry-run` shows the exact search and the cost estimate **without calling Apify**.

### Useful flags
| Flag | Meaning | Default |
|------|---------|---------|
| `--location "Kenya"` / `--geoid 104843105` | where to search (omit both = global) | global |
| `--count N` | max jobs to scrape (the Step 1 cost cap) | 150 (~$0.15) |
| `--days N` | only jobs posted in the last N days | 1 |
| `--companies N` | max **new** companies to enrich in Step 3 | 10 |
| `--max N` | max decision-maker profiles returned | 15 |
| `--titles "..."` | job-post roles to hunt (Step 1) | AP / Document Controller / … |
| `--dm-titles "..."` | decision-maker titles to find (Step 3) | CFO / Finance Director / … |
| `--yes` | skip the y/N prompts (for automation) | off |

## Where your results land
```
data/
  master_leads.csv     ← THE FILE YOU USE — every lead found, deduped, with the job that flagged them
  master_leads.jsonl   ← same leads + full job descriptions (for the future AI emailer)
  runs/<date>_<time>_<place>/   ← each run's raw files (jobs.json, prospects.csv, …)
  RUNS.md              ← a log of every run with counts + cost
  state/               ← memory of what's already been scraped/enriched (powers dedup)
```
The run folders are named `YYYY-MM-DD_HHMM_place`, so the **newest sorts to the bottom** — no more guessing which file is latest. `RUNS.md` is the quick history.

## How credits are protected (5 guardrails)
1. **Confirmation before every charge.** Nothing is spent until you type `y`.
2. **`--dry-run`** previews any command for free.
3. **`--count` cap** on scraping — never an uncapped "all jobs" pull. 150 jobs ≈ $0.15.
4. **Dedup ledgers.** A company enriched once is recorded in `data/state/seen_companies.txt`
   and **never enriched again** — re-running tomorrow won't re-charge for it. If every
   candidate is already done, Step 3 is skipped entirely ("$0.00 spent").
5. **`--days 1`** by default — daily runs only look at *yesterday's* new postings, so
   there's little overlap to pay for.

> **Honest limitation:** the LinkedIn jobs scraper can't be told "skip jobs I already
> have," so Step 1 still bills per job *scraped* even if some are duplicates. That's why
> the daily default is a narrow `--days 1` window. The real savings are in Step 3 (the
> expensive step), which the company ledger fully protects.

## What things actually cost (measured)
| Action | Real cost |
|--------|-----------|
| Scrape 150 jobs | ~$0.15 |
| Scrape 300 jobs | ~$0.30 |
| Enrich ~20 companies → ~24 contacts w/ emails (Step 3) | ~$0.33 |
| Step 2 (companies), HubSpot push | free |

Check your true spend anytime:
```bash
cat data/state/cost_log.csv     # one row per paid run
```

## A safe first run
```bash
./scripts/run_daily.sh --location "Kenya" --companies 3 --max 5 --dry-run   # free preview
./scripts/run_daily.sh --location "Kenya" --companies 3 --max 5             # ~$0.20 total
```
