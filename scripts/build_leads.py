#!/usr/bin/env python3
"""
Build the company-centric leads files from every run folder.

Scans data/runs/*/ (decisionmakers.csv + jobs.json), then writes:
  data/master_leads.csv    one row per COMPANY — the file you work from:
                           Company | Location | DM_Name | DM_Title | DM_Email | DM_LinkedIn | JobPost
  data/master_leads.jsonl  same companies + full job text + ALL contacts (for AI / backup)

Rebuilt from scratch each run, so it is always deduped (grouped by company) and
re-running simply adds the new companies — no duplicates.

The single decision-maker per company is chosen as: corporate email first, then the
most senior finance/ops title. The job is matched to the company by LinkedIn company
name (robust to the URL-slug mismatch that left JobPost empty — e.g. a "…careers"
or country-subdomain company page vs the person's company page).
"""
import sys, csv, os, re, json, glob, html
from collections import defaultdict, OrderedDict, Counter

DESC_LIMIT = 800

def seniority(title):
    t = (title or "").lower()
    if "chief financial" in t or re.search(r"\bcfo\b", t):                 return 100
    if "svp" in t or "vice president" in t or re.search(r"\bvp\b", t):     return 90
    if "controller" in t:                                                  return 85
    if any(k in t for k in ["director of finance", "finance director",
                            "head of finance", "head of accounting"]):     return 80
    if "director" in t:                                                    return 70
    if "head of" in t:                                                     return 68
    if "senior" in t and ("finance" in t or "account" in t):              return 60
    if "finance manager" in t or "accounting manager" in t:                return 55
    if "manager" in t:                                                     return 45
    if "finance" in t or "account" in t:                                   return 30
    return 10

EMAIL_RANK = {"corporate": 0, "personal": 1, "none": 2, "": 2}

def clean(t):  return re.sub(r"\s+", " ", html.unescape(t or "")).strip()
def keyname(n): return re.sub(r"[^a-z0-9]", "", (n or "").lower())   # match company across name variants

# Drop staffing/recruiting/outsourcing firms that slipped through Step 2 (they post on
# behalf of clients, so they are not Cellilox buyers). Agnostic — no company names:
#   - generic name tokens,
#   - LinkedIn industry classification,
#   - the job description itself revealing an "on behalf of a client" intermediary
#     (catches outsourcers even when their name looks normal and the industry is the
#     client's sector, e.g. tagged "Motor Vehicle Manufacturing").
AGENCY_NAME = ["staffing", "recruit", "headhunt", "outsourc", "bpo", "talent solutions"]
AGENCY_IND  = ["staffing and recruiting", "outsourcing and offshoring", "executive search"]
AGENCY_DESC = ["client overview", "our client is", "the client is a", "on behalf of our client",
               "for our client", "about our client", "our client's", "our client,"]
def is_agency(name, jobs):
    if any(t in (name or "").lower() for t in AGENCY_NAME):
        return True
    for j in jobs:
        ind = j.get("industries")
        ind = ", ".join(ind) if isinstance(ind, list) else (ind or "")
        if any(t in ind.lower() for t in AGENCY_IND):                  return True
        if any(t in (j.get("descriptionText") or "").lower() for t in AGENCY_DESC): return True
    return False

def main():
    out_csv = "data/master_leads.csv"; out_jsonl = "data/master_leads.jsonl"
    args = sys.argv[1:]
    if "--out" in args: out_csv = args[args.index("--out") + 1]

    people = OrderedDict()          # person-key -> their decisionmaker row (deduped across runs)
    jobs_by_co = defaultdict(list)  # normalized company name -> [job, ...]
    seen_job = set()
    for rd in sorted(glob.glob("data/runs/*")):
        jf = os.path.join(rd, "jobs.json")
        if os.path.exists(jf):
            try: jobs = json.load(open(jf))
            except Exception: jobs = []
            for j in jobs:
                jid = j.get("id")
                if jid in seen_job: continue
                seen_job.add(jid)
                jobs_by_co[keyname(j.get("companyName"))].append(j)
        dmf = os.path.join(rd, "decisionmakers.csv")
        if os.path.exists(dmf):
            for r in csv.DictReader(open(dmf)):
                k = (r.get("LinkedIn") or "").strip().lower() or (r.get("Email") or "").strip().lower() or r.get("Name", "")
                if k and k not in people:
                    people[k] = r

    # group the deduped people by NORMALIZED company name, so spelling variants
    # ("U.S. Pharmacopeia" vs "US Pharmacopeia") collapse into one row.
    groups = defaultdict(list)
    for r in people.values():
        groups[keyname(r["Company"])].append(r)

    def top_job(company):
        jl = jobs_by_co.get(keyname(company), [])
        return sorted(jl, key=lambda j: (j.get("postedAt") or "", j.get("applicantsCount") or 0),
                      reverse=True)

    def job_cell(jobs, dm):
        if jobs:
            j = jobs[0]
            title, url = clean(j.get("title")), (j.get("link") or j.get("jobUrl") or "")
            posted, desc = j.get("postedAt") or "", clean(j.get("descriptionText"))
        else:  # fall back to whatever Step 3 already attached on the person row
            title, url = clean(dm.get("TopJobTitle")), dm.get("TopJobUrl", "")
            posted, desc = dm.get("TopJobPostedAt", ""), clean(dm.get("JobSummary"))
        if len(desc) > DESC_LIMIT:
            desc = desc[:DESC_LIMIT].rstrip() + "…"
        parts = []
        if title: parts.append(title + (f"  (posted {posted})" if posted else ""))
        if url:   parts.append(url)
        if desc:  parts.append(desc)
        return "\n".join(parts)

    header = ["Company", "Location", "DM_Name", "DM_Title", "DM_Email", "DM_LinkedIn", "JobPost"]
    rows, recs = [], []
    for ckey, ppl in groups.items():
        # display name = the most common spelling among this company's people
        company = Counter(p["Company"].strip() for p in ppl).most_common(1)[0][0]
        jobs = top_job(ckey)
        if is_agency(company, jobs):      # skip staffing/outsourcing firms (agnostic)
            continue
        ppl.sort(key=lambda r: (EMAIL_RANK.get(r.get("EmailType", ""), 2), -seniority(r.get("Title", ""))))
        dm = ppl[0]
        top = jobs[0] if jobs else {}
        location = clean(top.get("location")) or dm.get("JobLocation") or dm.get("Location") or ""
        rows.append({"Company": company, "Location": location,
                     "DM_Name": dm["Name"], "DM_Title": dm["Title"], "DM_Email": dm["Email"],
                     "DM_LinkedIn": dm.get("LinkedIn", ""), "JobPost": job_cell(jobs, dm)})
        # full text of EVERY matching job for this company — this is what an LLM reads
        # to judge whether the role's manual document work is a fit for Cellilox.
        full_jobs = [{"title": clean(j.get("title")), "url": j.get("link") or j.get("jobUrl"),
                      "postedAt": j.get("postedAt"), "location": clean(j.get("location")),
                      "jobFunction": clean(j.get("jobFunction")),
                      "descriptionText": clean(j.get("descriptionText"))} for j in jobs]
        recs.append({
            "company": company, "location": location,
            "decision_maker": {"name": dm["Name"], "title": dm["Title"], "email": dm["Email"],
                               "emailType": dm.get("EmailType", ""), "linkedin": dm.get("LinkedIn", "")},
            "job": (full_jobs[0] if full_jobs else None),   # the top/most-recent post
            "jobs": full_jobs,                               # every matching post, full text
            "other_contacts": [{"name": p["Name"], "title": p["Title"], "email": p["Email"],
                                "linkedin": p.get("LinkedIn", "")} for p in ppl[1:]],
        })

    order = sorted(range(len(rows)), key=lambda i: (0 if rows[i]["DM_Email"] else 1, rows[i]["Company"].lower()))
    with open(out_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=header); w.writeheader()
        for i in order: w.writerow(rows[i])
    with open(out_jsonl, "w") as f:
        for i in order: f.write(json.dumps(recs[i], ensure_ascii=False) + "\n")

    ready = sum(1 for r in rows if r["DM_Email"])
    print(f"✓ {len(rows)} companies ({ready} with a DM email) -> {out_csv} (+ .jsonl)")

if __name__ == "__main__":
    main()
