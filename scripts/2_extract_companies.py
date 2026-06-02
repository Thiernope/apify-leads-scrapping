#!/usr/bin/env python3
"""
Step 2 — Collapse raw job postings into a deduplicated list of hiring companies,
and filter out staffing/recruiting agencies (they post on behalf of clients and
are NOT Cellilox buyers).

This step keeps the decision-maker enrichment (step 3) cheap: many jobs map to
far fewer unique companies.

Usage:
    python3 scripts/2_extract_companies.py data/<date>_jobs_<slug>.json

Outputs (named after the input file):
    data/<date>_companies_<slug>.csv   all unique companies
    data/<date>_prospects_<slug>.csv   companies minus staffing agencies (use this)
"""
import sys, json, csv, os, re
from collections import defaultdict

# Staffing/recruiting agencies post jobs on behalf of clients — they are NOT
# Cellilox buyers, and Step 3 spends real Apify credits per company, so we filter
# them out here. Three independent signals (a company is dropped if ANY matches):

# 1) Name keywords + high-precision tokens. A company named "… Search" or "… Jobs"
#    is almost always a recruiter; generic words like "partners"/"consulting" are
#    deliberately excluded because they catch real buyers (law firms, PE, mfg).
STAFFING_KW = ['robert half', 'vaco', 'randstad', 'adecco', 'manpower', 'kelly services',
    'staffing', 'recruit', 'executive search', 'talent', 'remotehunter', 'jobgether',
    'hays', 'aerotek', 'insight global', 'teksystems', 'hiring', 'headhunt', 'placement',
    'lhh', 'robert walters', 'michael page', 'search', 'jobs']

# 2) LinkedIn's own industry classification — authoritative, works on any scrape.
STAFFING_INDUSTRY = ['staffing and recruiting', 'outsourcing and offshoring',
    'executive search']

# 3) Known staffing/recruiting brands whose NAME has no keyword and whose industry
#    LinkedIn mislabels (e.g. Dexian -> "Manufacturing", Korn Ferry -> "Industrial").
STAFFING_BRANDS = ['dexian', 'kforce', 'korn ferry', 'jobot', 'ledgent', 'beacon hill',
    'oxford global', 'swipejobs', 'lumicity', 'professional alternatives', 'sparks group',
    'stevendouglas', 'sayva', 'segrera', 'truity', 'taylor white', 'the ht group',
    'addition management', 'henderson scott', 'macdonald & company', 'global edge',
    'digital executive', 'pyramid consulting', 'harrison richard', 'atlantic group',
    'blue signal']

# 4) The LinkedIn URL slug — exposes agencies whose name AND industry both hide it
#    (e.g. "Brilliant®" -> /company/brilliant-staffing). Only unambiguous tokens here:
#    'search' is excluded on purpose (it matches "re-search", e.g. duetto-research).
STAFFING_URL = ['staffing', 'recruit', 'headhunt', 'talent']

# Placeholder names job posters use to hide their identity — no real company to find.
PLACEHOLDER = ['confidential']

def get(d, *keys):
    for k in keys:
        if isinstance(d, dict) and d.get(k) not in (None, ""):
            return d[k]
    return ""

def is_staffing(name, industry="", url=""):
    n = name.lower(); ind = (industry or "").lower(); u = (url or "").lower()
    return (any(k in n for k in STAFFING_KW)
            or any(k in ind for k in STAFFING_INDUSTRY)
            or any(b in n for b in STAFFING_BRANDS)
            or any(k in u for k in STAFFING_URL)
            or any(p in n for p in PLACEHOLDER))

def main():
    # Args: <jobs.json> [--out-dir DIR]. With --out-dir, writes companies.csv /
    # prospects.csv there (run-folder mode); otherwise falls back to legacy names.
    args = [a for a in sys.argv[1:]]
    out_dir = ""
    if "--out-dir" in args:
        i = args.index("--out-dir"); out_dir = args[i + 1]; del args[i:i + 2]
    if not args:
        sys.exit("Usage: python3 scripts/2_extract_companies.py <jobs.json> [--out-dir DIR]")
    src = args[0]
    jobs = json.load(open(src))

    companies = defaultdict(lambda: {"jobTitles": set(), "count": 0,
                                     "linkedinUrl": "", "website": "",
                                     "location": "", "industry": "", "jobUrl": ""})
    for j in jobs:
        name = get(j, "companyName", "company").strip()
        if not name:
            continue
        c = companies[name]
        c["count"] += 1
        title = get(j, "title")
        if title:
            c["jobTitles"].add(title.strip())
        # strip LinkedIn tracking query params off the company URL
        li = get(j, "companyLinkedinUrl").split("?")[0]
        c["linkedinUrl"] = c["linkedinUrl"] or li
        c["jobUrl"]      = c["jobUrl"]      or get(j, "link", "jobUrl")
        c["website"]     = c["website"]     or get(j, "companyWebsite")
        ind = j.get("industries")
        ind = ind[0] if isinstance(ind, list) and ind else (ind or get(j, "industry"))
        c["industry"]    = c["industry"]    or (ind or "")
        loc = j.get("location")
        if isinstance(loc, dict):
            loc = loc.get("linkedinText") or loc.get("text") or ""
        c["location"]    = c["location"]    or (loc or "")

    rows = sorted(companies.items(), key=lambda kv: kv[1]["count"], reverse=True)

    header = ["Company", "OpenRoles", "SampleJobTitles", "Location", "Industry",
              "Website", "CompanyLinkedinUrl", "SampleJobUrl"]

    def write(path, items):
        with open(path, "w", newline="") as f:
            w = csv.writer(f); w.writerow(header)
            for name, c in items:
                w.writerow([name, c["count"], " | ".join(sorted(c["jobTitles"])[:3]),
                            c["location"], c["industry"], c["website"],
                            c["linkedinUrl"], c["jobUrl"]])

    if out_dir:
        all_path = os.path.join(out_dir, "companies.csv")
        pro_path = os.path.join(out_dir, "prospects.csv")
    else:
        # Legacy: derive output names from input ".../<date>_jobs[_<slug>].json"
        stem = re.sub(r"\.json$", "", src)
        m = re.search(r"_jobs(_.*)?$", stem)
        suffix = (m.group(1) or "") if m else ""        # "_global", "_kenya", or ""
        base = re.sub(r"_jobs(_.*)?$", "", stem) + "_{kind}" + suffix
        all_path = base.format(kind="companies") + ".csv"
        pro_path = base.format(kind="prospects") + ".csv"
    prospects = [(n, c) for n, c in rows
                 if not is_staffing(n, c["industry"], c["linkedinUrl"])]
    write(all_path, rows)
    write(pro_path, prospects)

    print(f"✓ {len(jobs)} jobs -> {len(rows)} companies "
          f"({len(rows)-len(prospects)} staffing agencies removed)")
    print(f"  All companies -> {all_path}")
    print(f"  Prospects     -> {pro_path}")
    print("\nTop prospects (most open document-work roles):")
    for name, c in prospects[:10]:
        print(f"  {c['count']:>2}x  {name}  [{c['location']}]")

if __name__ == "__main__":
    main()
