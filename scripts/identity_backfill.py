#!/usr/bin/env python3
"""
Backfill junk commitment counterparties from WhatsApp's canonical names.

Safe by construction:
  - Only touches JUNK counterparties (Unknown / base64 / raw-id / "Group").
    Never overrides a real human name (avoids creating mis-attribution).
  - Backs up the DB before writing.
  - Dry-run by default; pass --apply to write.

Usage:
  python3 scripts/identity_backfill.py           # dry run (shows what would change)
  python3 scripts/identity_backfill.py --apply   # back up + apply
"""
import os, re, sqlite3, sys, shutil, datetime

CDB = os.path.expanduser("~/.alfred/commitment_scan.db")
WDB = os.path.expanduser(
    "~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
)

def is_junk(name: str) -> bool:
    s = (name or "").strip()
    return (not s) or s == "Unknown" or s == "Group" or s.endswith("==") or len(s) > 48

def digits(s: str) -> str:
    return re.sub(r"\D", "", s or "")

def build_source_index():
    jid2name, phone2name = {}, {}
    w = sqlite3.connect(f"file:{WDB}?mode=ro", uri=True)
    for jid, name in w.execute(
        "SELECT ZCONTACTJID, ZPARTNERNAME FROM ZWACHATSESSION WHERE ZPARTNERNAME IS NOT NULL"
    ):
        if not jid or is_junk(name):
            continue
        jid2name[jid] = name
        if jid.endswith("@s.whatsapp.net"):
            d = digits(jid)
            if d:
                phone2name[d] = name
    w.close()
    return jid2name, phone2name

def resolve(thread_id, jid2name, phone2name):
    if thread_id in jid2name:
        return jid2name[thread_id]
    if not thread_id.endswith("@g.us"):
        d = digits(thread_id)
        if d and d in phone2name:
            return phone2name[d]
    return None

def main():
    apply = "--apply" in sys.argv
    jid2name, phone2name = build_source_index()
    c = sqlite3.connect(CDB)
    rows = c.execute(
        "SELECT id, thread_id, counterparty FROM commitment_extractions"
    ).fetchall()

    plan = []  # (id, thread_id, old, new)
    for rid, tid, cp in rows:
        if is_junk(cp):
            new = resolve(tid, jid2name, phone2name)
            if new and new.strip() != (cp or "").strip():
                plan.append((rid, tid, cp, new))

    print(f"Junk rows resolvable to a real name: {len(plan)}")
    # Show a sample grouped by thread
    seen = set()
    for rid, tid, old, new in plan:
        if tid in seen:
            continue
        seen.add(tid)
        print(f"  {tid[:36]:36}  {str(old)[:18]:18} -> {new}")

    if not apply:
        print("\nDry run. Re-run with --apply to write (a backup is made first).")
        c.close()
        return

    # Backup then apply
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = f"{CDB}.bak-{ts}"
    shutil.copy2(CDB, backup)
    print(f"\nBacked up DB -> {backup}")
    c.executemany(
        "UPDATE commitment_extractions SET counterparty=? WHERE id=?",
        [(new, rid) for (rid, _, _, new) in plan],
    )
    c.commit()
    c.close()
    print(f"Applied {len(plan)} updates.")

if __name__ == "__main__":
    main()
