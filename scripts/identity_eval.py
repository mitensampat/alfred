#!/usr/bin/env python3
"""
Identity-resolution eval harness.

Scores how well commitment counterparties resolve to the canonical name that
WhatsApp itself stores (ZWACHATSESSION.ZPARTNERNAME), keyed by thread JID with a
normalized-phone fallback for cross-channel (iMessage <-> WhatsApp) matches.

Metrics:
  - resolution_rate : % of commitments whose stored counterparty is a real name
                      (not "Unknown"/empty/raw-id)
  - source_match    : % of commitments whose stored counterparty EXACTLY matches
                      the source-of-truth name (the target after the fix)
  - precision       : of stored names that are non-junk, % that match source
                      (mis-attribution guardrail — should be ~100%)
  - groups/phones resolvable from source (ceiling the fix can reach)

Run before and after the resolver fix. Ship only if precision stays >= 0.99 and
source_match climbs toward resolution ceiling.

Usage:
  python3 scripts/identity_eval.py            # human-readable report
  python3 scripts/identity_eval.py --json     # machine-readable
"""
import os, re, sqlite3, sys, json

CDB = os.path.expanduser("~/.alfred/commitment_scan.db")
WDB = os.path.expanduser(
    "~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
)

def is_junk(name: str) -> bool:
    s = (name or "").strip()
    return (not s) or s == "Unknown" or s.endswith("==") or len(s) > 48

def digits(s: str) -> str:
    return re.sub(r"\D", "", s or "")

def build_source_index(wdb_path):
    """jid->name (exact) and phone-digits->name (for cross-channel 1:1)."""
    jid2name, phone2name = {}, {}
    if not os.path.exists(wdb_path):
        return jid2name, phone2name
    w = sqlite3.connect(f"file:{wdb_path}?mode=ro", uri=True)
    for jid, name in w.execute(
        "SELECT ZCONTACTJID, ZPARTNERNAME FROM ZWACHATSESSION WHERE ZPARTNERNAME IS NOT NULL"
    ):
        if not jid:
            continue
        jid2name[jid] = name
        if jid.endswith("@s.whatsapp.net"):
            d = digits(jid)
            if d:
                phone2name[d] = name  # 1:1 only — never index group JIDs by phone
    w.close()
    return jid2name, phone2name

def resolve(thread_id, jid2name, phone2name):
    """Reference resolver = the logic the Swift fix should mirror."""
    if thread_id in jid2name:                      # exact JID (groups + WA 1:1)
        return jid2name[thread_id], "exact_jid"
    if not thread_id.endswith("@g.us"):            # cross-channel 1:1 by phone
        d = digits(thread_id)
        if d and d in phone2name:
            return phone2name[d], "phone_norm"
    return None, "unresolved"

def main():
    as_json = "--json" in sys.argv
    jid2name, phone2name = build_source_index(WDB)
    c = sqlite3.connect(f"file:{CDB}?mode=ro", uri=True)
    rows = c.execute("SELECT thread_id, counterparty FROM commitment_extractions").fetchall()
    c.close()

    total = len(rows)
    resolved_now = 0          # stored name is non-junk
    source_match = 0          # stored == source-of-truth
    nonjunk = 0               # denominator for precision
    nonjunk_match = 0         # stored non-junk AND == source
    source_resolvable = 0     # source can name it (the ceiling)
    mismatches = []           # stored non-junk but != source (precision risks)
    junk_total = 0            # stored counterparty is junk (the fix target)
    junk_fixable = 0          # junk AND source can name it

    for tid, stored in rows:
        src, _ = resolve(tid, jid2name, phone2name)
        if src:
            source_resolvable += 1
        if not is_junk(stored):
            resolved_now += 1
            nonjunk += 1
            if src and stored.strip() == src.strip():
                source_match += 1
                nonjunk_match += 1
            elif src:
                mismatches.append((tid, stored, src))
        else:
            junk_total += 1
            if src:
                junk_fixable += 1
            if src and stored and stored.strip() == src.strip():
                source_match += 1

    def pct(n, d):
        return round(100.0 * n / d, 1) if d else 0.0

    report = {
        "total_commitments": total,
        "resolution_rate_pct": pct(resolved_now, total),
        "source_match_pct": pct(source_match, total),
        "source_resolvable_pct": pct(source_resolvable, total),
        "precision_pct": pct(nonjunk_match, nonjunk),
        "mismatch_count": len(mismatches),
        "junk_total": junk_total,
        "junk_fixable": junk_fixable,
        "junk_fixable_pct": pct(junk_fixable, junk_total),
    }

    if as_json:
        print(json.dumps(report, indent=2))
        return

    print("=== Identity Resolution Eval ===")
    print(f"  commitments scored:        {total}")
    print(f"  resolution rate (now):     {report['resolution_rate_pct']}%  (stored name is real)")
    print(f"  source-match (now):        {report['source_match_pct']}%  (stored == canonical source)")
    print(f"  source-resolvable ceiling: {report['source_resolvable_pct']}%  (what the fix can reach)")
    print(f"  precision (guardrail):     {report['precision_pct']}%  (of non-junk names, % matching source)")
    print(f"  JUNK counterparties:       {report['junk_total']}  (the fix target)")
    print(f"  ...fixable from source:    {report['junk_fixable']} ({report['junk_fixable_pct']}%)")
    print(f"  mismatches (stored != source): {report['mismatch_count']}")
    if mismatches:
        print("\n  --- mismatches to inspect (potential mis-attribution) ---")
        for tid, stored, src in mismatches[:25]:
            print(f"    {tid[:34]:34}  stored={stored[:24]:24}  source={src}")

if __name__ == "__main__":
    main()
