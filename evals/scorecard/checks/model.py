"""
Self-model invariants: claims, questions, tensions, values, and the stray-move queue.

These are the rules the synthesis pass promises to keep. Each one was a bug once, or is the
explicit contract of a gate in ClaimSynthesizer / SelfModelHygiene. The point of writing them
down here is that the gate and the check can now disagree out loud.
"""

import json

from harness import check, ok, bad, skip, metric, Target

DB = "self_model.db"
RDB = "reflection.db"

MIN_SUPPORT = 2          # ClaimSynthesizer.minSupport
MIN_DISTINCT_DAYS = 2    # ClaimSynthesizer.minDistinctDays
PROPOSAL_MAX_AGE_DAYS = 60   # SelfModelHygiene.proposalMaxAgeDays
PENDING_PER_WORKSPACE_CAP = 10


def _json(s):
    try:
        return json.loads(s or "{}")
    except Exception:            # noqa: BLE001
        return {}


def _live_ids(t: Target) -> set:
    return {r[0] for r in t.sql(DB, "SELECT id FROM self_facet WHERE status='active'")}


def _live_workspaces(t: Target) -> set:
    """Every name a live workspace answers to — its machine name and the user's rename."""
    names = set()
    for stmt, user in t.sql(DB, "SELECT statement, user_statement FROM self_facet "
                                "WHERE kind='theme' AND status='active'"):
        for n in (stmt, user):
            if n and n.strip():
                names.add(n.strip().lower())
    return names


# ── Claims ──────────────────────────────────────────────────────────────────

@check("claims", "claims.evidence_floor",
       f"every synthesized claim cites >= {MIN_SUPPORT} evidence items")
def _(t: Target):
    rows = t.sql(DB, "SELECT id, evidence_json FROM self_facet "
                     "WHERE kind='belief' AND status='active' AND origin='synthesized'")
    thin = [i for i, e in rows if len(_json(e) or []) < MIN_SUPPORT]
    f = bad(len(thin), _ratio(thin, len(rows), "claim(s) below the support floor"))
    f.metrics.update(metric("claims.active", len(rows)))
    return f


def _ratio(bad_ids, total, label):
    if not bad_ids:
        return f"{total} checked"
    return f"{len(bad_ids)}/{total} {label}: {', '.join(bad_ids[:3])}"


@check("claims", "claims.distinct_days",
       f"every synthesized claim draws on >= {MIN_DISTINCT_DAYS} distinct days")
def _(t: Target):
    rows = t.sql(DB, "SELECT id, evidence_json FROM self_facet "
                     "WHERE kind='belief' AND status='active' AND origin='synthesized'")
    thin = []
    for i, e in rows:
        days = {(x.get("ts") or "")[:10] for x in (_json(e) or []) if isinstance(x, dict) and x.get("ts")}
        if len(days) < MIN_DISTINCT_DAYS:
            thin.append(i)
    return bad(len(thin), _ratio(thin, len(rows), "claim(s) resting on a single day"))


@check("claims", "claims.confidence_range", "claim confidence stays within [0,1]")
def _(t: Target):
    n = t.one(DB, "SELECT COUNT(*) FROM self_facet WHERE kind='belief' "
                  "AND (confidence < 0 OR confidence > 1)")
    return bad(n, f"{n} belief(s) with out-of-range confidence")


@check("claims", "claims.non_empty", "no active facet has an empty statement")
def _(t: Target):
    n = t.one(DB, "SELECT COUNT(*) FROM self_facet WHERE status='active' AND TRIM(statement)=''")
    return bad(n, f"{n} active facet(s) with no text")


@check("claims", "claims.no_duplicates", "no two active claims say the same thing verbatim")
def _(t: Target):
    rows = t.sql(DB, "SELECT LOWER(TRIM(statement)) s, COUNT(*) n FROM self_facet "
                     "WHERE kind='belief' AND status='active' GROUP BY 1 HAVING n > 1")
    return bad(len(rows), f"{len(rows)} duplicated claim text(s)")


@check("claims", "claims.lineage", "every active claim is attached to a workspace")
def _(t: Target):
    rows = t.sql(DB, "SELECT COUNT(*) FROM self_facet f WHERE f.kind='belief' AND f.status='active' "
                     "AND f.origin='synthesized' "
                     "AND NOT EXISTS (SELECT 1 FROM facet_lineage l WHERE l.facet_id=f.id)")
    n = rows[0][0]
    return bad(n, f"{n} claim(s) with no lineage — they cannot be shown in context")


# ── Questions ───────────────────────────────────────────────────────────────

@check("questions", "questions.answered_have_answers",
       "every resolved question carries an answer or a duplicate target")
def _(t: Target):
    rows = t.sql(DB, "SELECT id, metadata_json FROM self_facet "
                     "WHERE kind='question' AND user_verdict='resolved'")
    missing = [i for i, m in rows
               if not _json(m).get("answer") and not _json(m).get("duplicate_of")]
    f = bad(len(missing), f"{len(missing)}/{len(rows)} resolved with nothing recorded")
    f.metrics.update(metric("questions.resolved", len(rows)))
    return f


@check("questions", "questions.answer_support",
       f"a question closed by synthesis cites >= {MIN_SUPPORT} references")
def _(t: Target):
    rows = t.sql(DB, "SELECT id, metadata_json FROM self_facet "
                     "WHERE kind='question' AND user_verdict='resolved'")
    thin = []
    for i, m in rows:
        md = _json(m)
        if md.get("answered_by") != "synthesis" or not md.get("answer"):
            continue
        try:
            n = int(md.get("answer_support") or 0)
        except (TypeError, ValueError):
            n = 0
        if n < MIN_SUPPORT:
            thin.append(i)
    return bad(len(thin), f"{len(thin)} thin answer(s) — the gate that reopened six on 13 Nov")


@check("questions", "questions.duplicate_targets_exist",
       "a question marked duplicate points at a question that exists")
def _(t: Target):
    ids = {r[0] for r in t.sql(DB, "SELECT id FROM self_facet WHERE kind='question'")}
    rows = t.sql(DB, "SELECT id, metadata_json FROM self_facet WHERE kind='question'")
    dangling = [i for i, m in rows
                if (_json(m).get("duplicate_of") or "") not in ("", None)
                and _json(m).get("duplicate_of") not in ids]
    return bad(len(dangling), f"{len(dangling)} duplicate pointer(s) into nothing")


@check("questions", "questions.lineage", "every open question is attached to a workspace")
def _(t: Target):
    n = t.one(DB, "SELECT COUNT(*) FROM self_facet f WHERE f.kind='question' AND f.status='active' "
                  "AND (f.user_verdict IS NULL OR f.user_verdict <> 'resolved') "
                  "AND NOT EXISTS (SELECT 1 FROM facet_lineage l WHERE l.facet_id=f.id)")
    total = t.one(DB, "SELECT COUNT(*) FROM self_facet WHERE kind='question' AND status='active'")
    f = bad(n, f"{n}/{total} open question(s) with no workspace")
    f.metrics.update(metric("questions.open", total))
    return f


# ── Tensions ────────────────────────────────────────────────────────────────

@check("tensions", "tensions.sides_live", "both sides of every tension are live facets")
def _(t: Target):
    live = _live_ids(t)
    rows = t.sql(DB, "SELECT id, metadata_json FROM self_facet "
                     "WHERE kind='tension' AND status='active'")
    dead = []
    for i, m in rows:
        md = _json(m)
        if md.get("left") not in live or md.get("right") not in live:
            dead.append(i)
    f = bad(len(dead), f"{len(dead)}/{len(rows)} tension(s) hanging off a retired claim")
    f.metrics.update(metric("tensions.active", len(rows), floor=2))
    return f


@check("tensions", "tensions.not_self", "no tension points at itself")
def _(t: Target):
    rows = t.sql(DB, "SELECT id, metadata_json FROM self_facet "
                     "WHERE kind='tension' AND status='active'")
    same = [i for i, m in rows if _json(m).get("left") and _json(m).get("left") == _json(m).get("right")]
    return bad(len(same), f"{len(same)} tension(s) between a claim and itself")


@check("tensions", "tensions.confidence_is_weaker_side",
       "a tension is no more confident than its weaker side")
def _(t: Target):
    conf = {r[0]: r[1] for r in t.sql(DB, "SELECT id, confidence FROM self_facet")}
    rows = t.sql(DB, "SELECT id, confidence, metadata_json FROM self_facet "
                     "WHERE kind='tension' AND status='active'")
    over = []
    for i, c, m in rows:
        md = _json(m)
        sides = [conf.get(md.get("left")), conf.get(md.get("right"))]
        sides = [s for s in sides if s is not None]
        if sides and c > min(sides) + 1e-6:
            over.append(i)
    return bad(len(over), f"{len(over)} tension(s) claiming more certainty than their evidence")


# ── Values ──────────────────────────────────────────────────────────────────

@check("values", "values.no_duplicates", "no two active values say the same thing")
def _(t: Target):
    rows = t.sql(DB, "SELECT LOWER(TRIM(statement)) s, COUNT(*) n FROM self_facet "
                     "WHERE kind='value' AND status='active' GROUP BY 1 HAVING n > 1")
    total = t.one(DB, "SELECT COUNT(*) FROM self_facet WHERE kind='value' AND status='active'")
    f = bad(len(rows), f"{len(rows)} duplicated value(s) of {total}")
    f.metrics.update(metric("values.active", total))
    return f


@check("values", "values.confidence_range", "value confidence stays within [0,1]")
def _(t: Target):
    n = t.one(DB, "SELECT COUNT(*) FROM self_facet WHERE kind='value' "
                  "AND (confidence < 0 OR confidence > 1)")
    return bad(n, f"{n} value(s) with out-of-range confidence")


@check("values", "values.inferred_are_marked",
       "an inferred value is distinguishable from one you declared")
def _(t: Target):
    n = t.one(DB, "SELECT COUNT(*) FROM self_facet WHERE kind='value' AND status='active' "
                  "AND (origin IS NULL OR TRIM(origin)='')")
    return bad(n, f"{n} value(s) with no origin — cannot tell yours from Alfred's")


# ── Hygiene & the stray queue ───────────────────────────────────────────────

@check("hygiene", "hygiene.targets_live",
       "no pending move proposal names a workspace that no longer exists")
def _(t: Target):
    if not t.has_db(RDB):
        return skip("no reflection.db")
    live = _live_workspaces(t)
    rows = t.sql(RDB, "SELECT id, to_theme FROM item_move_proposal WHERE status='pending'")
    dead = [i for i, to in rows if (to or "").strip().lower() not in live]
    f = bad(len(dead), f"{len(dead)}/{len(rows)} proposal(s) pointing into a merged-away workspace")
    f.metrics.update(metric("hygiene.pending", len(rows), tol=0.5, floor=5))
    return f


@check("hygiene", "hygiene.not_self_move", "no proposal moves an item into the place it already is")
def _(t: Target):
    if not t.has_db(RDB):
        return skip("no reflection.db")
    n = t.one(RDB, "SELECT COUNT(*) FROM item_move_proposal WHERE status='pending' "
                   "AND LOWER(TRIM(from_theme)) = LOWER(TRIM(to_theme))")
    return bad(n, f"{n} proposal(s) proposing nothing")


@check("hygiene", "hygiene.age_cap", f"no proposal has waited more than {PROPOSAL_MAX_AGE_DAYS} days")
def _(t: Target):
    if not t.has_db(RDB):
        return skip("no reflection.db")
    n = t.one(RDB, "SELECT COUNT(*) FROM item_move_proposal WHERE status='pending' "
                   f"AND created_at < datetime('now', '-{PROPOSAL_MAX_AGE_DAYS} day')")
    return bad(n, f"{n} proposal(s) past the expiry the reconciler promises to apply")


@check("hygiene", "hygiene.no_overridden",
       "no proposal asks about an item you have already filed yourself")
def _(t: Target):
    if not t.has_db(RDB):
        return skip("no reflection.db")
    n = t.one(RDB, "SELECT COUNT(*) FROM item_move_proposal p WHERE p.status='pending' "
                   "AND EXISTS (SELECT 1 FROM reflection_item_overrides o "
                   "            WHERE o.reflection_id=p.reflection_id "
                   "              AND o.item_type=p.item_type "
                   "              AND o.item_content=p.content)")
    return bad(n, f"{n} proposal(s) already decided by an override")


@check("hygiene", "hygiene.workspace_cap",
       f"no workspace has more than {PENDING_PER_WORKSPACE_CAP} proposals waiting")
def _(t: Target):
    if not t.has_db(RDB):
        return skip("no reflection.db")
    rows = t.sql(RDB, "SELECT from_theme, COUNT(*) n FROM item_move_proposal "
                      "WHERE status='pending' GROUP BY 1 HAVING n > ?",
                 (PENDING_PER_WORKSPACE_CAP,))
    return bad(len(rows), f"{len(rows)} workspace(s) over the cap")


@check("hygiene", "hygiene.reconcile_idempotent",
       "reconciling twice changes nothing the second time")
def _(t: Target):
    # The queue reconciles on read. If a second read still finds work to do, the reconciler is
    # chasing its own tail — which is how the 365-item backlog stayed 365 for weeks.
    first = t.get("/api/self-model/strays")
    if "__error__" in first:
        return skip(f"endpoint unavailable: {first['__error__']}")
    second = t.get("/api/self-model/strays", _pass=2)
    r = (second or {}).get("reconciled") or {}
    moved = sum(int(r.get(k) or 0) for k in
                ("dead_target", "collapsed", "superseded", "answered", "expired", "remapped"))
    f = bad(1 if moved else 0, f"second pass still changed {moved} row(s)" if moved else "stable")
    f.metrics.update(metric("hygiene.groups", len((second or {}).get("groups") or []),
                            tol=0.5, floor=3))
    return f
