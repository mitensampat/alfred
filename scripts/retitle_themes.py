#!/usr/bin/env python3
"""
Retitle reflection themes that have drifted away from their content.

The story: an earlier version of `ReflectionExtractionService` had a prompt
that used "Series A pricing models" as a worked example. Haiku echoed the
example verbatim and accumulated 40 unrelated reflections under it. The
prompt is fixed for future extractions; this script repairs the existing
data.

What it does:
1. Loads every theme + its actual reflection content (summaries, open
   questions, decisions, mental model shifts) from ~/.alfred/reflection.db.
2. Asks Haiku, per theme: "given this content, is the current name accurate?
   If not, propose a better one."
3. Dry-run by default — prints a diff of proposed renames.
4. With --apply, performs the rename inside a transaction:
   - UPDATE theme_states (preserving state/history)
   - Rewrites themes_json + theme_classifications_json in every reflection.

Run dry first, eyeball the proposals, then --apply.

Usage:
    python3 scripts/retitle_themes.py                # dry-run, all themes
    python3 scripts/retitle_themes.py --min-count 10 # skip tiny themes
    python3 scripts/retitle_themes.py --theme "Series A pricing models"  # one theme
    python3 scripts/retitle_themes.py --apply        # actually rename
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from pathlib import Path
from typing import Optional

DB = Path(os.path.expanduser("~/.alfred/reflection.db"))


def get_api_key() -> str:
    key = os.environ.get("ANTHROPIC_API_KEY")
    if key:
        return key
    cfg = Path(os.path.expanduser("~/.config/alfred/config.json"))
    if cfg.exists():
        data = json.loads(cfg.read_text())
        key = data.get("ai", {}).get("anthropic_api_key")
        if key:
            return key
    raise RuntimeError("No ANTHROPIC_API_KEY in env or alfred config")


# ── Data loading ───────────────────────────────────────────────────────────

def fetch_theme_corpus(conn: sqlite3.Connection, theme: str, limit: int = 40):
    """
    Return all reflection content (summary / open_questions / decisions / shifts)
    that lists `theme` in its themes_json. JSON-quoted match avoids substring
    collisions (same logic Swift uses).
    """
    quoted = f'"{theme}"'
    sql = """
        SELECT content_summary, open_questions_json, decisions_json, mental_model_shifts_json, created_at
        FROM reflections
        WHERE themes_json LIKE ?
        ORDER BY created_at DESC
        LIMIT ?
    """
    rows = conn.execute(sql, (f"%{quoted}%", limit)).fetchall()

    summaries, questions, decisions, shifts = [], [], [], []
    for summary, qj, dj, sj, _created in rows:
        if summary:
            summaries.append(summary.strip())
        try:
            for q in json.loads(qj or "[]"):
                if q: questions.append(q.strip())
        except Exception:
            pass
        try:
            for d in json.loads(dj or "[]"):
                if d: decisions.append(d.strip())
        except Exception:
            pass
        try:
            for s in json.loads(sj or "[]"):
                if isinstance(s, dict):
                    fr, to = s.get("from", ""), s.get("to", "")
                    if to: shifts.append(f"{fr} → {to}".strip())
        except Exception:
            pass

    return {
        "summaries": summaries,
        "questions": questions,
        "decisions": decisions,
        "shifts": shifts,
        "n_reflections": len(rows),
    }


def list_themes(conn: sqlite3.Connection):
    """
    All themes with reflection counts, descending. We enumerate by scanning
    the themes_json arrays in reflections (theme_states is sparse and may
    be empty for ad-hoc themes that never had explicit state set).
    """
    rows = conn.execute("SELECT themes_json FROM reflections").fetchall()
    counts: dict[str, int] = {}
    for (tj,) in rows:
        try:
            themes = json.loads(tj or "[]")
        except Exception:
            continue
        for t in themes:
            if t:
                counts[t] = counts.get(t, 0) + 1
    return sorted(counts.items(), key=lambda x: -x[1])


# ── Haiku retitling ────────────────────────────────────────────────────────

def build_retitle_prompt(current_name: str, corpus: dict, existing_themes: list[str]) -> str:
    samp = lambda items, k: "\n".join(f"  - {x[:200]}" for x in items[:k])
    other = [t for t in existing_themes if t != current_name][:30]
    return f"""You are auditing whether the name of a reflection THEME accurately describes its content.

The current theme name is: "{current_name}"

Here is the actual content currently filed under this theme ({corpus['n_reflections']} reflections):

CONTENT SUMMARIES (most recent first):
{samp(corpus['summaries'], 12) or '  (none)'}

OPEN QUESTIONS being wrestled with:
{samp(corpus['questions'], 8) or '  (none)'}

DECISIONS reached:
{samp(corpus['decisions'], 8) or '  (none)'}

BELIEF SHIFTS noted:
{samp(corpus['shifts'], 5) or '  (none)'}

OTHER EXISTING THEME NAMES (avoid creating a near-duplicate of these):
{', '.join(other) if other else '(none)'}

Your task:
- If the current name ACCURATELY describes the body of work above, respond with action="keep".
- If the name is misleading, generic, or echoes a stale label that doesn't match the actual content, propose a better name derived from the content itself.
- A good name is a concrete noun phrase that someone reading only the content would agree describes it (e.g. "FY28 revenue trajectory" or "founder succession planning"), NOT a generic label ("strategy", "finance") and NOT a label borrowed from these instructions.
- Brevity matters: 2-6 words.

Respond with ONLY valid JSON, no markdown fences:
{{"action": "keep" | "rename", "proposed_name": "<new name, or empty if keep>", "reason": "<one short sentence>"}}
"""


def ask_haiku(prompt: str) -> dict:
    import anthropic
    client = anthropic.Anthropic(api_key=get_api_key())
    resp = client.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=250,
        temperature=0,
        system="You audit theme names against their actual content. Be conservative — only rename when the mismatch is clear.",
        messages=[{"role": "user", "content": prompt}],
    )
    raw = "".join(b.text for b in resp.content if hasattr(b, "text")).strip()
    if "```" in raw:
        raw = raw.replace("```json", "").replace("```", "").strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {"action": "keep", "proposed_name": "", "reason": f"Parse failed: {raw[:100]}"}


# ── Apply rename ───────────────────────────────────────────────────────────

def apply_rename(conn: sqlite3.Connection, old: str, new: str):
    """
    Transactional rename:
      1. Migrate theme_states row (merge if `new` already exists).
      2. Rewrite themes_json and theme_classifications_json in every affected reflection.
    """
    cur = conn.cursor()
    cur.execute("BEGIN")
    try:
        # 1. theme_states: handle collision (new already exists) vs simple rename
        existing_new = cur.execute(
            "SELECT theme FROM theme_states WHERE theme = ?", (new,)
        ).fetchone()
        if existing_new:
            # Drop the old row; reflections will be remapped to the new theme.
            cur.execute("DELETE FROM theme_states WHERE theme = ?", (old,))
        else:
            cur.execute(
                "UPDATE theme_states SET theme = ?, updated_at = CURRENT_TIMESTAMP WHERE theme = ?",
                (new, old),
            )

        # 2. Rewrite per-reflection JSON fields
        rows = cur.execute(
            "SELECT id, themes_json, theme_classifications_json FROM reflections WHERE themes_json LIKE ?",
            (f'%"{old}"%',),
        ).fetchall()
        for rid, tj, cj in rows:
            try:
                themes = json.loads(tj or "[]")
            except Exception:
                themes = []
            new_themes = []
            for t in themes:
                t_repl = new if t == old else t
                if t_repl not in new_themes:  # dedupe in case both old+new were present
                    new_themes.append(t_repl)

            try:
                cls = json.loads(cj or "{}")
            except Exception:
                cls = {}
            if old in cls:
                # Carry state classification over; if new already had one, keep new's.
                cls.setdefault(new, cls[old])
                del cls[old]

            cur.execute(
                "UPDATE reflections SET themes_json = ?, theme_classifications_json = ? WHERE id = ?",
                (json.dumps(new_themes), json.dumps(cls), rid),
            )

        conn.commit()
        return len(rows)
    except Exception:
        conn.rollback()
        raise


# ── Main ───────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="Actually perform renames (default is dry-run)")
    ap.add_argument("--min-count", type=int, default=5, help="Skip themes with fewer than this many reflections")
    ap.add_argument("--theme", help="Audit only this single theme (exact name)")
    ap.add_argument("--limit", type=int, default=12, help="Sample size per theme passed to Haiku")
    args = ap.parse_args()

    if not DB.exists():
        print(f"DB not found: {DB}")
        sys.exit(1)

    conn = sqlite3.connect(str(DB))
    themes = list_themes(conn)
    if args.theme:
        themes = [(t, c) for (t, c) in themes if t == args.theme]
        if not themes:
            print(f"No theme named {args.theme!r}")
            sys.exit(1)
    else:
        themes = [(t, c) for (t, c) in themes if c >= args.min_count]

    all_names = [t for (t, _) in list_themes(conn)]
    print(f"Auditing {len(themes)} themes (mode={'APPLY' if args.apply else 'dry-run'})...\n")

    proposals = []
    for theme, count in themes:
        corpus = fetch_theme_corpus(conn, theme, limit=args.limit)
        if corpus["n_reflections"] == 0:
            continue
        prompt = build_retitle_prompt(theme, corpus, all_names)
        verdict = ask_haiku(prompt)
        action = verdict.get("action", "keep")
        proposed = (verdict.get("proposed_name") or "").strip()
        reason = verdict.get("reason", "")

        if action == "rename" and proposed and proposed != theme:
            proposals.append((theme, proposed, reason, count))
            print(f"✗ RENAME ({count:>3} reflections)")
            print(f"    from: {theme}")
            print(f"    to:   {proposed}")
            print(f"    why:  {reason}")
        else:
            print(f"✓ KEEP   ({count:>3}) {theme}")
        print()

    print("=" * 70)
    print(f"Proposed: {len(proposals)} rename(s) out of {len(themes)} themes audited")

    if not proposals:
        return

    if not args.apply:
        print("\nDry-run. Re-run with --apply to perform these renames.")
        return

    print("\nApplying...")
    for old, new, _why, _count in proposals:
        affected = apply_rename(conn, old, new)
        print(f"  ✓ {old!r} → {new!r} ({affected} reflection(s) updated)")
    print("Done.")


if __name__ == "__main__":
    main()
