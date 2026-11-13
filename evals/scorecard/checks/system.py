"""
The system around the features: connectors, the briefing, learning v2, prompt injection,
and the scheduler.

Several of these only mean anything against the running install. A frozen snapshot is stale by
definition, so asserting "the newest message is less than a day old" in the sandbox tests nothing
but how long ago the snapshot was taken — those carry targets=("live",).
"""

import json
import re

from harness import check, ok, bad, skip, metric, Target

LDB = "workflow_learning.db"

PROMPT_CONTEXT_BUDGET = 2600    # SelfModelService.promptContext(maxChars:)
BRIDGE_STALE_HOURS = 24


# ── Connectors ──────────────────────────────────────────────────────────────

@check("connectors", "connectors.health_shape", "health reports a status for every service")
def _(t: Target):
    d = t.get("/api/health/detailed")
    if "__error__" in d:
        return bad(1, d["__error__"])
    svcs = d.get("services") or []
    broken = [s for s in svcs if not s.get("name") or not s.get("status")]
    f = bad(len(broken) + (0 if svcs else 1),
            "no services reported" if not svcs else f"{len(broken)} service(s) with no status")
    f.metrics.update(metric("connectors.services", len(svcs), tol=0.1, floor=1))
    return f


@check("connectors", "connectors.none_failing", "no connector is reporting an error",
       targets=("live",))
def _(t: Target):
    # Live only: the sandbox runs the bare binary rather than the signed app bundle, so every
    # TCC-gated source (iMessage, Contacts) is structurally unavailable there. Failing that in
    # the sandbox would teach us to ignore a red row.
    d = t.get("/api/health/detailed")
    if "__error__" in d:
        return bad(1, d["__error__"])
    errs = [s.get("name") for s in (d.get("services") or []) if s.get("status") == "error"]
    return bad(len(errs), f"failing: {errs}" if errs else "")


@check("connectors", "connectors.bridge_paired", "the WhatsApp bridge is paired and reachable",
       targets=("live",))
def _(t: Target):
    d = t.get("/api/wa-bridge/status")
    if "__error__" in d:
        return bad(1, d["__error__"])
    problems = []
    if not d.get("paired"):
        problems.append("not paired")
    if not d.get("reachable"):
        problems.append("unreachable")
    if d.get("logged_out"):
        problems.append("logged out")
    f = bad(len(problems), ", ".join(problems))
    f.metrics.update(metric("connectors.wa_messages", int(d.get("messages") or 0),
                            tol=0.25, floor=500))
    return f


@check("connectors", "connectors.bridge_fresh",
       f"the newest message is less than {BRIDGE_STALE_HOURS}h old", targets=("live",))
def _(t: Target):
    import time
    d = t.get("/api/wa-bridge/status")
    if "__error__" in d:
        return skip(d["__error__"])
    newest = int(d.get("newest_message") or 0)
    if not newest:
        return bad(1, "no messages at all")
    hours = (time.time() - newest) / 3600.0
    return bad(1 if hours > BRIDGE_STALE_HOURS else 0,
               f"newest message is {hours:.1f}h old — a silent ingestion stall looks exactly "
               f"like a quiet day, which is why this is a check and not a glance")


@check("connectors", "connectors.reflections_flowing", "the reflection store has content")
def _(t: Target):
    d = t.get("/api/reflect/stats")
    if "__error__" in d:
        return bad(1, d["__error__"])
    total = int(d.get("total_reflections") or 0)
    themes = int(d.get("active_themes") or 0)
    f = bad(1 if (total == 0 or themes == 0) else 0,
            f"reflections={total} themes={themes}")
    f.metrics.update(metric("connectors.reflections", total, tol=0.2, floor=20))
    f.metrics.update(metric("connectors.themes", themes, tol=0.25, floor=5))
    return f


# ── Briefing ────────────────────────────────────────────────────────────────

@check("briefing", "briefing.cadence_present", "a briefing cadence exists and is schedulable")
def _(t: Target):
    d = t.get("/api/cadences")
    if "__error__" in d:
        return bad(1, d["__error__"])
    cs = [c for c in (d.get("cadences") or [])
          if "brief" in (c.get("action_type") or "").lower()
          or "brief" in (c.get("name") or "").lower()]
    if not cs:
        return bad(1, "no briefing cadence at all")
    broken = [c.get("name") for c in cs if not (c.get("schedule") or {}).get("type")]
    return bad(len(broken), f"{len(broken)} briefing cadence(s) with no schedule")


@check("briefing", "briefing.last_run_recorded",
       "the briefing records what it produced, not just that it ran")
def _(t: Target):
    d = t.get("/api/cadences")
    if "__error__" in d:
        return skip(d["__error__"])
    cs = [c for c in (d.get("cadences") or [])
          if "brief" in (c.get("action_type") or "").lower()]
    ran = [c for c in cs if c.get("last_run_timestamp")]
    empty = [c.get("name") for c in ran if not (c.get("last_run_summary") or "").strip()]
    return bad(len(empty), f"{len(empty)} run(s) with no summary — a silent pass and a failed "
                           f"pass are indistinguishable without one")


# ── Learning v2 ─────────────────────────────────────────────────────────────

@check("learning", "learning.confidence_range", "pattern confidence stays within [0,1]")
def _(t: Target):
    n = t.one(LDB, "SELECT COUNT(*) FROM learned_patterns WHERE confidence < 0 OR confidence > 1")
    return bad(n, f"{n} pattern(s) with out-of-range confidence")


@check("learning", "learning.direct_instructions_are_certain",
       "an instruction you gave outright is held at full confidence")
def _(t: Target):
    n = t.one(LDB, "SELECT COUNT(*) FROM learned_patterns "
                   "WHERE is_direct_instruction=1 AND is_archived=0 AND confidence < 1.0")
    total = t.one(LDB, "SELECT COUNT(*) FROM learned_patterns WHERE is_direct_instruction=1")
    f = bad(n, f"{n}/{total} direct instruction(s) decayed below certainty")
    f.metrics.update(metric("learning.direct", total, tol=0.3, floor=5))
    return f


@check("learning", "learning.archived_stay_hidden",
       "an archived pattern is never served to a prompt")
def _(t: Target):
    d = t.get("/api/learning/patterns")
    if "__error__" in d:
        return skip(d["__error__"])
    served = {p.get("id") for p in (d.get("patterns") or [])}
    archived = {r[0] for r in t.sql(LDB, "SELECT pattern_id FROM learned_patterns "
                                         "WHERE is_archived=1")}
    leak = served & archived
    f = bad(len(leak), f"{len(leak)} archived pattern(s) still being injected")
    f.metrics.update(metric("learning.active", len(served), tol=0.3, floor=3))
    return f


@check("learning", "learning.reviews_resolve",
       "every pending review points at a pattern that exists")
def _(t: Target):
    cols = {r[1] for r in t.sql(LDB, "PRAGMA table_info(pending_pattern_reviews)")}
    key = "pattern_id" if "pattern_id" in cols else None
    if not key:
        return skip("pending_pattern_reviews has no pattern_id column")
    n = t.one(LDB, f"SELECT COUNT(*) FROM pending_pattern_reviews r WHERE NOT EXISTS "
                   f"(SELECT 1 FROM learned_patterns p WHERE p.pattern_id = r.{key})")
    pending = t.one(LDB, "SELECT COUNT(*) FROM pending_pattern_reviews")
    f = bad(n, f"{n}/{pending} review(s) for a pattern that is gone")
    f.metrics.update(metric("learning.pending_reviews", pending, tol=0.5, floor=4))
    return f


@check("learning", "learning.events_typed", "every learning event carries a type")
def _(t: Target):
    n = t.one(LDB, "SELECT COUNT(*) FROM learning_events WHERE TRIM(event_type)=''")
    total = t.one(LDB, "SELECT COUNT(*) FROM learning_events")
    f = bad(n, f"{n} untyped event(s)")
    f.metrics.update(metric("learning.events", total, tol=0.3, floor=10))
    return f


# ── Prompt injection ────────────────────────────────────────────────────────

@check("injection", "injection.non_empty", "the self-model reaches the prompt at all")
def _(t: Target):
    d = t.get("/api/model/prompt-context")
    if "__error__" in d:
        return bad(1, d["__error__"])
    ctx = d.get("context") or ""
    f = bad(1 if len(ctx.strip()) < 50 else 0,
            f"only {len(ctx)} chars — Alfred would be coaching a stranger")
    f.metrics.update(metric("injection.chars", int(d.get("chars") or len(ctx)),
                            tol=0.2, floor=120))
    return f


@check("injection", "injection.within_budget",
       f"the injected context stays under {PROMPT_CONTEXT_BUDGET} characters")
def _(t: Target):
    d = t.get("/api/model/prompt-context")
    if "__error__" in d:
        return skip(d["__error__"])
    n = int(d.get("chars") or len(d.get("context") or ""))
    return bad(1 if n > PROMPT_CONTEXT_BUDGET else 0,
               f"{n} chars — over budget, so something else got truncated out of the prompt")


@check("injection", "injection.has_sections",
       "the injected context keeps its headed sections")
def _(t: Target):
    d = t.get("/api/model/prompt-context")
    if "__error__" in d:
        return skip(d["__error__"])
    ctx = d.get("context") or ""
    want = ["## WHO THIS PERSON IS"]
    missing = [w for w in want if w not in ctx]
    subs = len(re.findall(r"^### ", ctx, re.M))
    f = bad(len(missing) + (1 if subs == 0 else 0),
            f"missing {missing}" if missing else (f"no subsections" if subs == 0 else ""))
    f.metrics.update(metric("injection.sections", subs, tol=0.5, floor=1))
    return f


@check("injection", "injection.budget_matches_source",
       "the budget asserted here is the budget in the code")
def _(t: Target):
    src = t.src("Sources/Services/SelfModelService.swift")
    m = re.search(r"func promptContext\(maxChars: Int = (\d+)\)", src)
    if not m:
        return skip("could not find promptContext signature")
    return bad(0 if int(m.group(1)) == PROMPT_CONTEXT_BUDGET else 1,
               f"code says {m.group(1)}, this check says {PROMPT_CONTEXT_BUDGET}")


# ── Scheduler & cadences ────────────────────────────────────────────────────

@check("cadences", "cadences.well_formed", "every cadence has a name, an action and a schedule")
def _(t: Target):
    d = t.get("/api/cadences")
    if "__error__" in d:
        return bad(1, d["__error__"])
    cs = d.get("cadences") or []
    broken = [c.get("name") or "?" for c in cs
              if not (c.get("name") or "").strip()
              or not (c.get("action_type") or "").strip()
              or not (c.get("schedule") or {}).get("type")]
    f = bad(len(broken), f"{len(broken)}/{len(cs)} malformed: {broken[:3]}" if broken else "")
    f.metrics.update(metric("cadences.total", len(cs), tol=0.15, floor=2))
    f.metrics.update(metric("cadences.enabled", sum(1 for c in cs if c.get("enabled")),
                            tol=0.25, floor=2))
    return f


@check("cadences", "cadences.schedule_vocabulary",
       "every stored schedule type can be decoded")
def _(t: Target):
    # CadenceSchedule decodes by hand on a "type" discriminator and throws on anything else, so
    # a schedule type that is not in that switch is a cadence that silently fails to load.
    d = t.get("/api/cadences")
    if "__error__" in d:
        return skip(d["__error__"])
    src = t.src("Sources/Models/Cadence.swift")
    block = re.search(r"init\(from decoder: Decoder\).*?default:", src, re.S)
    if not block:
        return skip("could not read the CadenceSchedule decoder")
    known = set(re.findall(r'case\s+"([a-z_]+)":', block.group(0)))
    types = {x for x in ((c.get("schedule") or {}).get("type")
                         for c in (d.get("cadences") or [])) if x}
    unknown = sorted(types - known)
    return bad(len(unknown), f"schedule types the decoder rejects: {unknown}" if unknown else
               f"{len(types)} type(s), all decodable")


@check("cadences", "cadences.action_vocabulary",
       "every cadence action is one the runner implements")
def _(t: Target):
    d = t.get("/api/cadences")
    if "__error__" in d:
        return skip(d["__error__"])
    src = t.src("Sources/Models/Cadence.swift")
    known = set(re.findall(r'case\s+\w+\s*=\s*"([a-z_]+)"', src))
    if not known:
        return skip("could not read the CadenceAction cases")
    actions = {x for x in ((c.get("action_type") or "") for c in (d.get("cadences") or [])) if x}
    unknown = sorted(actions - known)
    return bad(len(unknown), f"cadences wired to an action that does not exist: {unknown}"
               if unknown else f"{len(actions)} action(s), all implemented")


@check("cadences", "cadences.state_file_parses", "the scheduler's state file is readable")
def _(t: Target):
    p = t.data_dir / "scheduler_state.json"
    if not p.exists():
        return ok("no state yet")
    try:
        json.loads(p.read_text())
    except Exception as e:      # noqa: BLE001
        return bad(1, f"corrupt — the scheduler will re-run or skip today's tasks: {e}")
    return ok("parses")


@check("cadences", "cadences.builtins_present", "the built-in cadences have not gone missing")
def _(t: Target):
    d = t.get("/api/cadences")
    if "__error__" in d:
        return skip(d["__error__"])
    n = sum(1 for c in (d.get("cadences") or []) if c.get("is_built_in"))
    f = bad(1 if n == 0 else 0, "no built-in cadences at all")
    f.metrics.update(metric("cadences.builtin", n, tol=0.15, floor=1))
    return f
