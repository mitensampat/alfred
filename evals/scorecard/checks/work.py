"""
The working surfaces: commitments, closures, to-dos, the Desk, people.

Most of these assert referential integrity between tables that nothing in SQLite enforces.
Two of them — orphaned closure detections and double-counted closures — are the data bugs the
November connector audit turned up, written down so they cannot come back unnoticed.
"""

from harness import check, ok, bad, skip, metric, Target

CDB = "commitment_scan.db"
TDB = "todos.db"

AUTO_CLOSE_FLOOR = 0.85      # CommitmentScanTracker: >= 0.85 auto-closes
ASK_FLOOR = 0.6              # below this, a signal is ignored entirely
OPEN_COMMITMENT_MAX_DAYS = 30   # the 30-day auto-Done rule


# ── Commitment extraction ───────────────────────────────────────────────────

@check("extraction", "extraction.has_title", "every extracted commitment has a title")
def _(t: Target):
    n = t.one(CDB, "SELECT COUNT(*) FROM commitment_extractions "
                   "WHERE title IS NULL OR TRIM(title)=''")
    total = t.one(CDB, "SELECT COUNT(*) FROM commitment_extractions")
    f = bad(n, f"{n}/{total} commitment(s) with nothing to show")
    f.metrics.update(metric("extraction.total", total, tol=0.15, floor=25))
    return f


@check("extraction", "extraction.has_hash", "every commitment has a stable hash")
def _(t: Target):
    n = t.one(CDB, "SELECT COUNT(*) FROM commitment_extractions "
                   "WHERE commitment_hash IS NULL OR TRIM(commitment_hash)=''")
    return bad(n, f"{n} commitment(s) that cannot be deduplicated or closed")


@check("extraction", "extraction.confidence_range", "extraction confidence stays within [0,1]")
def _(t: Target):
    n = t.one(CDB, "SELECT COUNT(*) FROM commitment_extractions "
                   "WHERE confidence IS NOT NULL AND (confidence < 0 OR confidence > 1)")
    return bad(n, f"{n} commitment(s) with out-of-range confidence")


@check("extraction", "extraction.open_age_cap",
       f"nothing stays open past {OPEN_COMMITMENT_MAX_DAYS} days")
def _(t: Target):
    n = t.one(CDB, "SELECT COUNT(*) FROM commitment_extractions WHERE was_closed=0 "
                   "AND extracted_at < ?", (t.ago(OPEN_COMMITMENT_MAX_DAYS),))
    openn = t.one(CDB, "SELECT COUNT(*) FROM commitment_extractions WHERE was_closed=0")
    f = bad(n, f"{n} commitment(s) past the auto-Done rule — the Desk queue grows if this drifts")
    f.metrics.update(metric("extraction.open", openn, tol=0.4, floor=10))
    return f


@check("extraction", "extraction.closed_have_dates", "a closed commitment records when it closed")
def _(t: Target):
    n = t.one(CDB, "SELECT COUNT(*) FROM commitment_extractions WHERE was_closed=1 "
                   "AND (closed_at IS NULL OR TRIM(closed_at)='')")
    return bad(n, f"{n} closure(s) with no date — days_open is uncomputable for these")


# ── Closure detection ───────────────────────────────────────────────────────

@check("closure", "closure.no_orphans", "every closure detection points at a real commitment")
def _(t: Target):
    n = t.one(CDB, "SELECT COUNT(*) FROM closure_detections d WHERE NOT EXISTS "
                   "(SELECT 1 FROM commitment_extractions e "
                   "  WHERE e.commitment_hash = d.commitment_hash)")
    return bad(n, f"{n} closure(s) attached to a commitment that no longer exists")


@check("closure", "closure.no_double_count", "a commitment is closed once, not twice")
def _(t: Target):
    rows = t.sql(CDB, "SELECT commitment_hash FROM closure_detections "
                      "GROUP BY 1 HAVING COUNT(*) > 1")
    return bad(len(rows), f"{len(rows)} commitment(s) with more than one closure row — "
                          "this is what inflated the closure stats")


@check("closure", "closure.auto_threshold",
       f"nothing auto-closes below {AUTO_CLOSE_FLOOR} confidence")
def _(t: Target):
    n = t.one(CDB, "SELECT COUNT(*) FROM closure_detections WHERE auto_closed=1 "
                   f"AND confidence < {AUTO_CLOSE_FLOOR}")
    total = t.one(CDB, "SELECT COUNT(*) FROM closure_detections WHERE auto_closed=1")
    f = bad(n, f"{n}/{total} auto-closed under the threshold")
    f.metrics.update(metric("closure.auto_closed", total, tol=0.15, floor=20))
    return f


@check("closure", "closure.ask_band",
       f"a closure left for you to confirm sits between {ASK_FLOOR} and {AUTO_CLOSE_FLOOR}")
def _(t: Target):
    n = t.one(CDB, "SELECT COUNT(*) FROM closure_detections "
                   "WHERE auto_closed=0 AND user_confirmed IS NULL "
                   f"AND (confidence < {ASK_FLOOR} OR confidence >= {AUTO_CLOSE_FLOOR})")
    pending = t.one(CDB, "SELECT COUNT(*) FROM closure_detections "
                         "WHERE auto_closed=0 AND user_confirmed IS NULL")
    f = bad(n, f"{n}/{pending} pending closure(s) outside the ask band")
    f.metrics.update(metric("closure.pending", pending, tol=0.4, floor=8))
    return f


@check("closure", "closure.confidence_range", "closure confidence stays within [0,1]")
def _(t: Target):
    n = t.one(CDB, "SELECT COUNT(*) FROM closure_detections WHERE confidence < 0 OR confidence > 1")
    return bad(n, f"{n} closure(s) with out-of-range confidence")


# ── To-dos & Notion sync ────────────────────────────────────────────────────

VALID_TODO_STATUS = ("open", "done", "dismissed", "suggested", "snoozed")


@check("todos", "todos.status_vocabulary", "every to-do has a status the UI knows how to render")
def _(t: Target):
    rows = t.sql(TDB, "SELECT DISTINCT status FROM todos")
    unknown = [r[0] for r in rows if r[0] not in VALID_TODO_STATUS]
    return bad(len(unknown), f"unknown status: {unknown}" if unknown else "")


@check("todos", "todos.has_source", "every to-do says where it came from")
def _(t: Target):
    n = t.one(TDB, "SELECT COUNT(*) FROM todos WHERE source IS NULL OR TRIM(source)=''")
    return bad(n, f"{n} to-do(s) with no provenance")


@check("todos", "todos.has_title", "every to-do has a title")
def _(t: Target):
    n = t.one(TDB, "SELECT COUNT(*) FROM todos WHERE TRIM(title)=''")
    openn = t.one(TDB, "SELECT COUNT(*) FROM todos WHERE status='open'")
    f = bad(n, f"{n} to-do(s) with no text")
    f.metrics.update(metric("todos.open", openn, tol=0.3, floor=15))
    return f


@check("todos", "todos.no_duplicate_dedupe_key",
       "the dedupe key actually dedupes among live to-dos")
def _(t: Target):
    rows = t.sql(TDB, "SELECT dedupe_key FROM todos "
                      "WHERE status IN ('open','suggested') "
                      "  AND dedupe_key IS NOT NULL AND TRIM(dedupe_key) <> '' "
                      "GROUP BY 1 HAVING COUNT(*) > 1")
    return bad(len(rows), f"{len(rows)} duplicated to-do(s) the dedupe key should have caught")


@check("todos", "todos.sources_resolve", "every source link points at a to-do that exists")
def _(t: Target):
    n = t.one(TDB, "SELECT COUNT(*) FROM todo_sources s WHERE NOT EXISTS "
                   "(SELECT 1 FROM todos x WHERE x.id = s.todo_id)")
    return bad(n, f"{n} orphaned source link(s)")


@check("todos", "todos.done_have_dates", "a completed to-do records when it completed")
def _(t: Target):
    n = t.one(TDB, "SELECT COUNT(*) FROM todos WHERE status='done' "
                   "AND (done_at IS NULL OR TRIM(done_at)='')")
    return bad(n, f"{n} completed to-do(s) with no completion time")


# ── Desk / Now / fronts ─────────────────────────────────────────────────────

@check("desk", "desk.responds", "the Desk answers with its three surfaces")
def _(t: Target):
    d = t.get("/api/desk")
    if "__error__" in d:
        return bad(1, d["__error__"])
    missing = [k for k in ("queue", "fronts", "people") if k not in d]
    f = bad(len(missing), f"missing: {missing}" if missing else "")
    f.metrics.update(metric("desk.queue", len(d.get("queue") or []), tol=0.4, floor=5))
    f.metrics.update(metric("desk.fronts", len(d.get("fronts") or []), tol=0.3, floor=3))
    return f


@check("desk", "desk.queue_items_complete", "every queue item has an id and a person")
def _(t: Target):
    d = t.get("/api/desk")
    if "__error__" in d:
        return skip(d["__error__"])
    q = d.get("queue") or []
    broken = [i for i, it in enumerate(q) if not it.get("id") or not (it.get("who") or it.get("contact_id"))]
    return bad(len(broken), f"{len(broken)}/{len(q)} queue item(s) that cannot be acted on")


@check("desk", "desk.no_duplicate_fronts", "no front appears twice")
def _(t: Target):
    d = t.get("/api/desk")
    if "__error__" in d:
        return skip(d["__error__"])
    ids = [f.get("id") for f in (d.get("fronts") or []) if f.get("id")]
    return bad(len(ids) - len(set(ids)), f"{len(ids) - len(set(ids))} duplicated front(s)")


@check("desk", "desk.top_fronts_are_fronts", "the promoted fronts are drawn from the real list")
def _(t: Target):
    d = t.get("/api/desk")
    if "__error__" in d:
        return skip(d["__error__"])
    ids = {f.get("id") for f in (d.get("fronts") or [])}
    stray = [f.get("id") for f in (d.get("top_fronts") or []) if f.get("id") not in ids]
    return bad(len(stray), f"{len(stray)} promoted front(s) that are not on the Desk")


@check("desk", "desk.first_move_resolves", "the one next move points at something real")
def _(t: Target):
    d = t.get("/api/desk")
    if "__error__" in d:
        return skip(d["__error__"])
    fm = d.get("first_move") or {}
    if not fm:
        return ok("no first move offered")
    ids = {it.get("id") for it in (d.get("queue") or [])}
    target = fm.get("clear_id")
    return bad(0 if (target is None or target in ids) else 1,
               "the headline move points at an item that is not in the queue")


@check("desk", "desk.fronts_named", "every front has a name and an owner")
def _(t: Target):
    d = t.get("/api/desk")
    if "__error__" in d:
        return skip(d["__error__"])
    fr = d.get("fronts") or []
    broken = [f.get("id") for f in fr if not (f.get("name") or "").strip()]
    return bad(len(broken), f"{len(broken)}/{len(fr)} unnamed front(s)")


# ── People ──────────────────────────────────────────────────────────────────

@check("people", "people.named", "every person has a name and initials")
def _(t: Target):
    d = t.get("/api/v2/people")
    if "__error__" in d:
        return bad(1, d["__error__"])
    ppl = d.get("people") or []
    broken = [p for p in ppl if not (p.get("name") or "").strip() or not (p.get("initials") or "").strip()]
    f = bad(len(broken), f"{len(broken)}/{len(ppl)} person/people missing a name or initials")
    f.metrics.update(metric("people.shown", len(ppl), tol=0.4, floor=4))
    return f


@check("people", "people.counts_sane", "owed counts are never negative")
def _(t: Target):
    d = t.get("/api/v2/people")
    if "__error__" in d:
        return skip(d["__error__"])
    ppl = d.get("people") or []
    bad_rows = [p.get("name") for p in ppl
                if (p.get("you_owe") or 0) < 0 or (p.get("they_owe") or 0) < 0]
    return bad(len(bad_rows), f"{len(bad_rows)} person/people with a negative balance")


@check("people", "people.pinned_subset", "the pinned count never exceeds the people shown")
def _(t: Target):
    d = t.get("/api/v2/people")
    if "__error__" in d:
        return skip(d["__error__"])
    pinned = int(d.get("pinned_count") or 0)
    return bad(1 if pinned > len(d.get("people") or []) else 0,
               f"pinned_count={pinned} exceeds the list")
