#!/usr/bin/env bash
# Shared helpers for the Cellilox lead-gen daily tool.
# Sourced by the step scripts AFTER they cd to the project root and source .env.

UA="${UA:-apify-agent-skills/apify-ultimate-scraper}"
STATE_DIR="data/state"
RUNS_DIR="data/runs"
MASTER_CSV="data/master_leads.csv"
MASTER_JSONL="data/master_leads.jsonl"
COST_LOG="${STATE_DIR}/cost_log.csv"
RUNS_MD="data/RUNS.md"

# Create the state/run scaffolding and empty ledgers on first use.
ensure_state() {
  mkdir -p "$STATE_DIR" "$RUNS_DIR"
  local f
  for f in seen_jobs.txt seen_companies.txt seen_people.txt; do
    [ -f "$STATE_DIR/$f" ] || : > "$STATE_DIR/$f"
  done
  [ -f "$COST_LOG" ] || echo "timestamp,step,actor,count,usd,runId" > "$COST_LOG"
  if [ ! -f "$RUNS_MD" ]; then
    {
      echo "# Run log"
      echo
      echo "| When | Slug | Jobs (new) | Prospects | Enriched | New leads | Cost |"
      echo "|------|------|-----------|-----------|----------|-----------|------|"
    } > "$RUNS_MD"
  fi
}

stamp() { date +%Y-%m-%d_%H%M; }

# Build a filesystem slug from --location / --geoid; "global" when neither given.
make_slug() { # $1=location $2=geoid
  local loc="$1" geo="$2" slug="global"
  [ -n "$loc" ] && slug="$(echo "$loc" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
  [ -n "$geo" ] && slug="${slug}-geo${geo}"
  echo "$slug"
}

# y/n confirmation before a paid step. Auto-yes when ASSUME_YES=1 (set by --yes).
confirm() { # $1=message
  if [ "${ASSUME_YES:-0}" = "1" ]; then echo "  ↳ $1  [auto-yes]"; return 0; fi
  printf "  ↳ %s  [y/N] " "$1"
  local ans=""; read -r ans </dev/tty 2>/dev/null || ans=""
  case "$ans" in y|Y|yes|YES) return 0;; *) echo "  ✗ skipped."; return 1;; esac
}

# Look up the real USD cost of an Apify run, append a cost-log row, echo the number.
log_cost() { # $1=runId $2=step $3=actor $4=count  -> echoes usd
  local rid="$1" step="$2" actor="$3" cnt="$4" usd="0"
  if [ -n "${APIFY_TOKEN:-}" ] && [ -n "$rid" ]; then
    usd=$(curl -s "https://api.apify.com/v2/actor-runs/${rid}?token=${APIFY_TOKEN}" 2>/dev/null \
      | python3 -c "import sys,json
try: print('%.4f'%((json.load(sys.stdin).get('data') or {}).get('usageTotalUsd') or 0))
except Exception: print('0')" 2>/dev/null) || usd="0"
  fi
  [ -z "$usd" ] && usd="0"
  echo "$(date -u +%FT%TZ),${step},${actor},${cnt},${usd},${rid}" >> "$COST_LOG"
  echo "$usd"
}

# Total spend to date across all logged runs.
total_spend() {
  [ -f "$COST_LOG" ] || { echo "0.00"; return; }
  python3 -c "import csv;print('%.2f'%sum(float(r['usd'] or 0) for r in csv.DictReader(open('$COST_LOG'))))" 2>/dev/null || echo "0.00"
}
