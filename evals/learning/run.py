#!/usr/bin/env python3
"""
Replay eval for the learning-signal classifier prompt.

What this does:
1. Loads fixtures from fixtures.jsonl (real user/assistant exchanges).
2. Extracts the live Haiku prompt directly from
   Sources/Agents/Learning/WorkflowLearningService.swift — single source of truth.
3. Runs each fixture through Haiku at temperature 0 (deterministic).
4. Scores each output against the hard filters from scorers.py +
   per-fixture expectations.
5. Prints a scorecard and writes baselines/latest.json. If a previous
   baseline exists, prints the delta (regression detection).

Usage:
    python evals/learning/run.py                     # full eval
    python evals/learning/run.py --filter id_prefix  # subset
    python evals/learning/run.py --save-baseline     # also overwrite baseline
    python evals/learning/run.py --add               # interactively append a fixture

To add a new fixture when you spot a real-world bad capture:
    python evals/learning/run.py --add

Env:
    ANTHROPIC_API_KEY    Falls back to ai.anthropic_api_key in ~/.config/alfred/config.json.
"""

from __future__ import annotations  # py3.9-friendly union syntax

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).parent
ROOT = HERE.parent.parent
SWIFT_FILE = ROOT / "Sources/Agents/Learning/WorkflowLearningService.swift"
FIXTURES_PINNED = HERE / "fixtures_pinned.jsonl"   # checked in: synthetic regression cases
FIXTURES_SEED = HERE / "fixtures_seed.jsonl"       # gitignored: real exchanges (PII)
BASELINE = HERE / "baselines/latest.json"

# Import the scorers from the sibling module
sys.path.insert(0, str(HERE))
from scorers import score_fixture  # noqa: E402


# ── Prompt extraction ───────────────────────────────────────────────────────

def extract_classify_prompt() -> str:
    # Pulls the `let prompt = (triple-quote) ... (triple-quote)` block from
    # classifyExchangeSignals. The eval MUST run against the live Swift prompt,
    # otherwise it's testing fiction.
    src = SWIFT_FILE.read_text()
    # Find the classifyExchangeSignals function, then its first `let prompt = """ ... """`
    match = re.search(
        r"func classifyExchangeSignals\b.*?let prompt = \"\"\"\n(.*?)\n\s*\"\"\"",
        src,
        re.DOTALL,
    )
    if not match:
        raise RuntimeError(
            "Could not find prompt in classifyExchangeSignals. "
            "If you renamed the function or changed the prompt literal style, "
            "update extract_classify_prompt()."
        )
    return match.group(1)


def render_prompt(template: str, exchanges: list[dict]) -> str:
    """
    Mimic the Swift string interpolation: replace `\(exchangesList)` with the
    rendered exchanges block.
    """
    exchanges_block = "\n\n".join(
        f'Exchange {i+1}:\nUser: "{ex["user_message"][:200]}"\nAssistant: "{ex["assistant_response"][:200]}"'
        for i, ex in enumerate(exchanges)
    )
    return template.replace("\\(exchangesList)", exchanges_block)


# ── API client ──────────────────────────────────────────────────────────────

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


def run_haiku(prompt: str) -> str:
    import anthropic
    client = anthropic.Anthropic(api_key=get_api_key())
    resp = client.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=500,
        temperature=0,  # deterministic
        system="You classify chat exchanges for behavioral learning signals. Be precise and sensitive to subtle cues.",
        messages=[{"role": "user", "content": prompt}],
    )
    # Concatenate text blocks
    return "".join(b.text for b in resp.content if hasattr(b, "text"))


def parse_signals(raw: str) -> list[dict]:
    txt = raw.strip()
    # Strip code fences if Haiku wraps the JSON
    if "```" in txt:
        txt = txt.replace("```json", "").replace("```", "").strip()
    try:
        data = json.loads(txt)
    except json.JSONDecodeError:
        return []
    return data.get("signals", [])


# ── Eval loop ───────────────────────────────────────────────────────────────

def load_fixtures(filter_prefix: str | None) -> list[dict]:
    fixtures = []
    paths = [p for p in (FIXTURES_PINNED, FIXTURES_SEED) if p.exists()]
    if not paths:
        print(f"No fixtures found. Expected {FIXTURES_PINNED.name} and/or {FIXTURES_SEED.name}.")
        print("Run seed_fixtures.py to bootstrap from your local DB.")
        sys.exit(1)
    for path in paths:
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            f = json.loads(line)
            if filter_prefix and not f["id"].startswith(filter_prefix):
                continue
            fixtures.append(f)
    return fixtures


def run_eval(filter_prefix: str | None, verbose: bool) -> dict:
    template = extract_classify_prompt()
    fixtures = load_fixtures(filter_prefix)
    print(f"Loaded {len(fixtures)} fixtures. Running against live Haiku prompt...\n")

    results = []
    for fix in fixtures:
        # Each fixture is its own single-exchange batch (isolates per-fixture behavior).
        prompt = render_prompt(template, [fix])
        try:
            raw = run_haiku(prompt)
        except Exception as e:
            results.append({
                "id": fix["id"], "passed": False,
                "reasons": [f"API error: {e}"],
                "signals": [],
            })
            continue

        signals = parse_signals(raw)
        passed, reasons = score_fixture(signals, fix.get("expectations", {}))
        results.append({
            "id": fix["id"], "passed": passed, "reasons": reasons,
            "signals": signals, "user_message": fix["user_message"][:120],
        })

        if verbose or not passed:
            marker = "✓" if passed else "✗"
            print(f"{marker} {fix['id']}")
            print(f"   in:  {fix['user_message'][:140]}")
            for s in signals:
                t = s.get("type", "?")
                c = (s.get("content") or "")[:140]
                conf = s.get("confidence", "?")
                print(f"   out: [{t} conf={conf}] {c}")
            for r in reasons:
                print(f"   ⚠  {r}")
            print()

    n = len(results)
    passes = sum(1 for r in results if r["passed"])
    summary = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "fixtures": n,
        "passed": passes,
        "failed": n - passes,
        "pass_rate": (passes / n) if n else 0.0,
        "results": results,
    }
    return summary


def print_scorecard(summary: dict, baseline: dict | None):
    n = summary["fixtures"]
    passes = summary["passed"]
    rate = summary["pass_rate"]
    print("=" * 60)
    print(f"PASS {passes}/{n}  ({rate:.0%})")
    if baseline:
        prev_rate = baseline.get("pass_rate", 0.0)
        delta = rate - prev_rate
        sign = "+" if delta >= 0 else ""
        print(f"Baseline: {baseline['passed']}/{baseline['fixtures']} ({prev_rate:.0%})  "
              f"→ delta {sign}{delta:+.1%}")
        # ID-level diff
        prev_pass = {r["id"]: r["passed"] for r in baseline.get("results", [])}
        regressions = [r["id"] for r in summary["results"]
                       if r["id"] in prev_pass and prev_pass[r["id"]] and not r["passed"]]
        improvements = [r["id"] for r in summary["results"]
                        if r["id"] in prev_pass and not prev_pass[r["id"]] and r["passed"]]
        if regressions:
            print(f"REGRESSIONS ({len(regressions)}): {', '.join(regressions[:8])}"
                  + ("..." if len(regressions) > 8 else ""))
        if improvements:
            print(f"IMPROVEMENTS ({len(improvements)}): {', '.join(improvements[:8])}"
                  + ("..." if len(improvements) > 8 else ""))
    print("=" * 60)


def load_baseline() -> dict | None:
    if BASELINE.exists():
        try:
            return json.loads(BASELINE.read_text())
        except Exception:
            return None
    return None


def save_baseline(summary: dict):
    BASELINE.parent.mkdir(parents=True, exist_ok=True)
    BASELINE.write_text(json.dumps(summary, indent=2))
    print(f"Baseline saved → {BASELINE}")


def add_fixture_interactive():
    print("Add a new fixture. Paste content then end each field with EOF (Ctrl-D).")
    print("user_message:")
    user = sys.stdin.read().strip()
    print("\nassistant_response (or empty):")
    sys.stdin = open("/dev/tty")  # reopen after first read consumed stdin
    asst = input().strip() if False else ""  # keep simple — assistant optional
    notes = input("notes: ").strip() if False else ""
    require = input("require_type [correction|preference|reinforcement|fact|none|<blank>]: ").strip() or None
    forbid_raw = input("forbid_types (comma-separated, blank for none): ").strip()
    forbid = [t.strip() for t in forbid_raw.split(",") if t.strip()]

    next_id = f"manual_{int(datetime.now().timestamp())}"
    new_fix = {
        "id": next_id,
        "user_message": user,
        "assistant_response": asst,
        "source_event_type": "manual",
        "notes": notes,
        "expectations": {"require_type": require, "forbid_types": forbid},
    }
    # Pinned by default (synthetic, safe to commit). Real exchanges should go to fixtures_seed.jsonl manually.
    with FIXTURES_PINNED.open("a") as f:
        f.write(json.dumps(new_fix) + "\n")
    print(f"Appended fixture {next_id} to {FIXTURES_PINNED.name}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--filter", help="Only run fixtures whose id starts with this prefix")
    ap.add_argument("--verbose", "-v", action="store_true", help="Print every fixture (default: failures only)")
    ap.add_argument("--save-baseline", action="store_true", help="Overwrite baselines/latest.json with this run")
    ap.add_argument("--add", action="store_true", help="Interactively append a fixture and exit")
    args = ap.parse_args()

    if args.add:
        add_fixture_interactive()
        return

    summary = run_eval(args.filter, args.verbose)
    baseline = load_baseline()
    print_scorecard(summary, baseline)

    if args.save_baseline:
        save_baseline(summary)
    else:
        # Always save the most recent run to a side file for inspection
        latest_run = HERE / "baselines" / "last_run.json"
        latest_run.parent.mkdir(parents=True, exist_ok=True)
        latest_run.write_text(json.dumps(summary, indent=2))
        print(f"(Run saved to {latest_run}; pass --save-baseline to update the regression baseline.)")


if __name__ == "__main__":
    main()
