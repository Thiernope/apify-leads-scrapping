# Command Reference — calling the lead-gen scripts

A complete reference for every script, flag, format, and example.
For the short everyday guide see [USAGE.md](USAGE.md); for the *why* see [WORKFLOW.md](WORKFLOW.md).

---

## 0. The big picture

There are **four scripts**. You normally only run the first one (`run_daily.sh`),
which calls the other three for you:

| Script | What it does | Costs money? |
|--------|--------------|:---:|
| `scripts/run_daily.sh` | **Orchestrator** — runs the whole pipeline below, in order | — |
| `scripts/1_scrape_jobs.sh` | Scrape LinkedIn job postings (the buying signal) | 💲 Apify |
| `scripts/2_extract_companies.py` | Collapse jobs → companies, drop staffing agencies | free |
| `scripts/3_find_decision_makers.sh` | Find the finance decision-maker + email per company | 💲 Apify |

**Everything is driven by flags. Nothing is hardcoded** — roles, location, recency,
counts, and titles are all changeable at the command line.

A flag is `--name value`. Order doesn't matter. Values with spaces **must be quoted**:
`--location "United Kingdom"` ✅ — `--location United Kingdom` ❌ (shell splits it).

---

## 1. `run_daily.sh` — the one you run every day

```bash
./scripts/run_daily.sh [flags]
```

Runs Step 1 → 2 → 3, asks `y/N` before each charge, dedupes against past runs, and
appends results to `data/master_leads.csv`.

### Flags

| Flag | Meaning | Default |
|------|---------|---------|
| `--location "<text>"` | Where to search (free text, see §5) | global |
| `--geoid <id>` | Precise LinkedIn location ID — overrides `--location` (see §5) | none |
| `--titles "<a,b,c>"` | **Job-post roles** to search for — Step 1 (see §6) | AP / Document Controller / Invoice Processing / Data Entry Clerk |
| `--dm-titles "<a,b>"` | **Decision-maker titles** to find — Step 3 | CFO / Finance Director / Controller / … |
| `--count <N>` | Max jobs to scrape (the Step 1 cost cap) | 150 (~$0.15) |
| `--days <N>` | Only jobs posted in the last N days | 1 |
| `--companies <N>` | Max **new** companies to enrich in Step 3 | 10 |
| `--max <N>` | Max decision-maker profiles returned | 15 |
| `--remote` | Remote jobs only | off |
| `--yes` | Skip the y/N confirmations (automation) | off (asks) |
| `--dry-run` | Preview Step 1 only; spends nothing | off |

### Examples

```bash
# Free preview — always do this first
./scripts/run_daily.sh --location "Kenya" --dry-run

# A small, safe daily run (asks before each charge)
./scripts/run_daily.sh --location "Kenya" --companies 5 --max 8

# Precise location via geoId (no ambiguity)
./scripts/run_daily.sh --geoid 100710459 --companies 5 --max 8        # Kenya

# Different roles + look back a week
./scripts/run_daily.sh --location "Kenya" --days 7 \
    --titles "Bookkeeper,AP Clerk,Order Processing"

# Remote-friendly, wider net
./scripts/run_daily.sh --remote --count 100 --companies 8 --max 12

# Unattended (no prompts) — only once you trust the costs
./scripts/run_daily.sh --geoid 104843105 --companies 5 --max 8 --yes  # Rwanda
```

---

## 2. `1_scrape_jobs.sh` — scrape jobs (Step 1, runnable alone)

```bash
./scripts/1_scrape_jobs.sh [flags]
```

| Flag | Meaning | Default (standalone) |
|------|---------|---------|
| `--titles "<a,b>"` | Job roles, comma-separated (auto-quoted + OR-joined) | the 4 document roles |
| `--keywords "<query>"` | Raw LinkedIn boolean query — advanced; **overrides `--titles`** | — |
| `--location "<text>"` | Free-text place | global |
| `--geoid <id>` | Precise LinkedIn geoId | none |
| `--days <N>` | Posted within last N days | 7 |
| `--count <N>` | Max jobs to scrape (cost cap) | 300 |
| `--remote` | Remote only | off |
| `--run-dir <dir>` | Output folder (auto-created if omitted) | new timestamped folder |
| `--yes` / `--dry-run` | Skip confirm / preview only | — |

> Note: standalone defaults (`--days 7`, `--count 300`) are wider than the
> `run_daily.sh` defaults (`--days 1`, `--count 150`), which are tuned for cheap
> daily use.

```bash
./scripts/1_scrape_jobs.sh --location "Kenya" --count 200 --dry-run
./scripts/1_scrape_jobs.sh --keywords '"Bookkeeper" AND "remote"' --remote
```

Output: `data/runs/<date>_<time>_<slug>/jobs.json`

---

## 3. `2_extract_companies.py` — jobs → companies (Step 2, free)

```bash
python3 scripts/2_extract_companies.py <jobs.json> [--out-dir DIR]
```

Collapses the scraped jobs into unique companies, counts open roles, and removes
staffing/recruiting agencies (4-signal filter: industry, name tokens, known brands,
LinkedIn URL slug). No flags beyond the input file and optional output directory.

```bash
python3 scripts/2_extract_companies.py data/runs/2026-06-02_2325_global/jobs.json \
    --out-dir data/runs/2026-06-02_2325_global
```

Outputs (in the run folder): `companies.csv` (all) and `prospects.csv` (agencies
removed — this feeds Step 3).

---

## 4. `3_find_decision_makers.sh` — find the contact (Step 3, runnable alone)

```bash
./scripts/3_find_decision_makers.sh --in <prospects.csv> [flags]
```

| Flag | Meaning | Default (standalone) |
|------|---------|---------|
| `--in <file>` | **Required.** prospects CSV from Step 2 | — |
| `--companies <N>` | Max **new** companies to enrich (skips already-done ones) | 25 |
| `--max <N>` | Max profiles returned total | 25 |
| `--titles "<a,b>"` | Decision-maker titles to find | CFO / Finance Director / … |
| `--run-dir <dir>` | Run folder (defaults to the folder of `--in`) | dir of `--in` |
| `--yes` / `--dry-run` | Skip confirm / preview the actor input | — |

```bash
./scripts/3_find_decision_makers.sh \
    --in data/runs/2026-06-02_2325_global/prospects.csv \
    --companies 5 --max 8 --dry-run
```

Output: `<run-dir>/decisionmakers.csv` **and** appends to `data/master_leads.csv` +
`data/master_leads.jsonl` (deduped).

---

## 5. Location: `--location` vs `--geoid`

- **`--location "Kenya"`** — free text. LinkedIn *guesses* the place. Convenient but
  ambiguous text can match the wrong area.
- **`--geoid <id>`** — LinkedIn's exact internal ID. **No ambiguity. Overrides `--location`.**

### Does case / spelling matter?
LinkedIn place-matching is **case-insensitive and forgiving**, but be sensible:

| You type | Works? | Notes |
|----------|:---:|-------|
| `"Kenya"` / `"kenya"` / `"KENYA"` | ✅ | case is ignored |
| `"United States"` / `"united states"` | ✅ | full name is safe |
| `"us"` | ⚠️ | too short/ambiguous — avoid |
| `"KingDom"` (partial) | ❌ | use full `"United Kingdom"` |
| `United Kingdom` (no quotes) | ❌ | spaces need quotes |

**Rules of thumb:** spell the **full country name**, quote anything with a space, and
when it really matters use `--geoid`.

### geoId cheat-sheet
```
Worldwide        92000000
United States   103644278
United Kingdom  101165590
Canada          101174742
India           102713980
Kenya           100710459
Rwanda          104843105
UAE (Emirates)  104305776
```
(Find any other place's geoId: open LinkedIn Jobs, filter by location, and copy the
`geoId=` number out of the browser URL.)

---

## 6. Roles & titles: `--titles`, `--keywords`, `--dm-titles`

- **`--titles "A,B,C"`** (Step 1 job roles): a comma list. The script auto-quotes each
  and joins with OR. `--titles "Bookkeeper,AP Clerk"` → searches `"Bookkeeper" OR "AP Clerk"`.
- **`--keywords '...'`** (Step 1, advanced): a raw LinkedIn boolean query you write
  yourself. Supports `AND`/`OR`/quotes. **Overrides `--titles`.**
  Example: `--keywords '"Accounts Payable" AND ("remote" OR "hybrid")'`.
- **`--dm-titles "A,B"`** (Step 3): the decision-maker job titles to look for at each
  company (CFO, Finance Director, Controller, Head of Procurement, …).

---

## 7. Cost & credit control

1. **Confirm before every charge** — nothing spends until you type `y` (or pass `--yes`).
2. **`--dry-run`** previews any command for free.
3. **`--count`** caps Step 1. 150 jobs ≈ $0.15; 300 ≈ $0.30.
4. **Dedup** — a company enriched once is never re-enriched; re-running won't re-charge.
   If every candidate is already done, Step 3 is skipped (`$0.00`).
5. **`--days 1`** default keeps daily scrapes small.

Measured costs: scrape ≈ **$0.001/job**; Step 3 ≈ **$0.13–0.33** per batch; Steps 2 &
HubSpot push are free. Per-run actual cost is logged:
```bash
cat data/state/cost_log.csv     # every paid run with its USD cost
cat data/RUNS.md                # human-readable run history
```

> **Honest limit:** the jobs scraper can't be told "skip jobs I already have," so Step 1
> still bills per job *scraped* even if some repeat. That's why the daily window is
> `--days 1`. The expensive step (3) is fully protected by the company ledger.

---

## 8. Output files

```
data/
  master_leads.csv     ← THE FILE YOU USE: every lead, deduped, with the job that flagged them
  master_leads.jsonl   ← same leads + full job descriptions (for the AI emailer)
  runs/<date>_<time>_<place>/
      jobs.json        ← raw scraped jobs
      companies.csv    ← all companies
      prospects.csv    ← companies minus agencies (feeds Step 3)
      decisionmakers.csv ← this run's contacts
      run.json         ← this run's stats + cost
  RUNS.md              ← log of every run (counts + cost)
  state/               ← dedup memory (seen jobs / companies / people) + cost_log.csv
```

Run folders are named `YYYY-MM-DD_HHMM_place`, so the **newest sorts to the bottom**.

---

## 9. Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `Required: --in <prospects.csv>` | You ran Step 3 without `--in`. Pass the prospects file. |
| `0 new companies … skipping Step 3` | Not an error — every candidate was already enriched (dedup working). Increase `--companies` or target a new location. |
| Step prompts never appear / it auto-skips | You're not in an interactive terminal. Add `--yes` to proceed unattended. |
| `Unknown option: …` | Typo in a flag, or an unquoted value with a space. |
| Costs show `$0.00` but scraping worked | `APIFY_TOKEN` missing/blank in `.env` (cost lookup needs it; scraping uses the CLI login). |
| Few or zero jobs scraped | Location too narrow for `--days 1`. Widen with `--days 3/7` or add `--remote`. |

---

## 10. Recommended daily routine

```bash
# Morning: preview, then run a small Kenya batch
./scripts/run_daily.sh --location "Kenya" --dry-run
./scripts/run_daily.sh --location "Kenya" --companies 5 --max 8

# Optional: add Rwanda (dedup carries across both)
./scripts/run_daily.sh --geoid 104843105 --companies 5 --max 8
```
Check `data/master_leads.csv` for new leads and `data/RUNS.md` for the cost.
