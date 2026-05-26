#!/usr/bin/env python3
"""
Bootstrap fixtures.jsonl from real chat exchanges in workflow_learning.db.

Run once to seed; afterwards, add fixtures by hand (or via `run.py --add`).
Pulls the most recent chat_correction / chat_preference / user_context_fact /
reinforcement events and their assistant responses.

Each fixture starts with empty expectations — you annotate them after the
first eval run to lock in the behavior you want.
"""

import json
import os
import sqlite3
import sys
from pathlib import Path

HERE = Path(__file__).parent
DB = Path(os.path.expanduser("~/.alfred/workflow_learning.db"))
OUT = HERE / "fixtures_seed.jsonl"  # gitignored — real exchanges may contain PII
LIMIT = 30


def main(overwrite: bool = False):
    if OUT.exists() and not overwrite:
        print(f"{OUT} already exists. Pass --overwrite to replace, or hand-edit it.")
        sys.exit(1)

    if not DB.exists():
        print(f"DB not found: {DB}")
        sys.exit(1)

    conn = sqlite3.connect(str(DB))
    cur = conn.cursor()
    rows = cur.execute(
        """
        SELECT id, context, signal_value, metadata_json, event_type
        FROM learning_events
        WHERE event_type IN ('chat_correction','chat_preference','user_context_fact','reinforcement','direct_instruction')
        ORDER BY timestamp DESC
        LIMIT ?
        """,
        (LIMIT,),
    ).fetchall()

    fixtures = []
    for row in rows:
        ev_id, context, signal, meta_json, ev_type = row
        try:
            meta = json.loads(meta_json or "{}")
        except Exception:
            meta = {}
        assistant = meta.get("assistant_response", "") or ""
        fixtures.append({
            "id": f"seed_{ev_id}",
            "user_message": context or "",
            "assistant_response": assistant,
            "source_event_type": ev_type,
            "notes": "Auto-seeded. Add expectations as you learn what good output looks like.",
            "expectations": {
                # Set "require_type" to one of correction|preference|reinforcement|fact|none
                # to assert Haiku must classify this exchange that way.
                "require_type": None,
                # Set "forbid_types" to e.g. ["preference"] to assert it must NOT be a preference.
                "forbid_types": [],
            },
        })

    with OUT.open("w") as f:
        for fix in fixtures:
            f.write(json.dumps(fix) + "\n")

    print(f"Wrote {len(fixtures)} fixtures to {OUT}")


if __name__ == "__main__":
    main(overwrite="--overwrite" in sys.argv)
