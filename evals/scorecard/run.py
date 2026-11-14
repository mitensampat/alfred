#!/usr/bin/env python3
"""
Run the Tier 1 scorecard against a build and report the delta.

    python3 evals/scorecard/run.py                    # sandbox on 8081, diff vs baseline
    python3 evals/scorecard/run.py --target live      # read-only against the running install
    python3 evals/scorecard/run.py --feature claims   # one row, while iterating
    python3 evals/scorecard/run.py --save-baseline    # accept these numbers as the new floor
    python3 evals/scorecard/run.py --json             # machine-readable, for a commit comment

Exit status: 0 clean · 1 regression or drift · 2 a check itself broke.

The absolute score is the less interesting half of the output. A feature that scored 94 last
build and 71 this one, when the change was meant to touch something else, is the whole reason
this exists.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "checks"))

from harness import (                                        # noqa: E402
    FEATURES, FEATURE_NAMES, REGISTRY, Target, calibrate,
    load_baseline, metric_drift, run_checks, save_baseline, score,
)

# Importing the modules is what populates the registry.
import checks.model      # noqa: F401,E402
import checks.work       # noqa: F401,E402
import checks.system     # noqa: F401,E402
import checks.source     # noqa: F401,E402

ROOT = HERE.parent.parent
BASELINE_DIR = HERE / "baselines"

# Below this, a live calibration is measuring the instrument rather than the system.
LIVE_CALIBRATION_MIN_SPAN = 30 * 60

C = {
    "dim": "\033[2m", "red": "\033[0;31m", "green": "\033[0;32m",
    "yellow": "\033[0;33m", "bold": "\033[1m", "off": "\033[0m",
}


def paint(s, c):
    return f"{C[c]}{s}{C['off']}" if sys.stdout.isatty() else s


def read_config(config_dir: Path) -> dict:
    p = config_dir / "config.json"
    try:
        return json.loads(p.read_text())
    except Exception:                                        # noqa: BLE001
        return {}


def build_target(mode: str, base_url: str | None) -> Target:
    now = None
    if mode == "sandbox":
        sandbox = Path(os.environ.get("ALFRED_SANDBOX", Path.home() / ".alfred-sandbox"))
        data_dir = sandbox / "work"
        cfg = read_config(sandbox / "config")
        port = (cfg.get("api") or {}).get("port") or 8081
        # The snapshot's own timestamp is the clock for a frozen corpus.
        taken = sandbox / "snapshot" / ".taken_at"
        if taken.exists():
            now = taken.read_text().strip() or None
    else:
        data_dir = Path(os.environ.get("ALFRED_DIR", Path.home() / ".alfred"))
        cfg = read_config(Path(os.environ.get("ALFRED_CONFIG_DIR",
                                              Path.home() / ".config/alfred")))
        port = (cfg.get("api") or {}).get("port") or 8080
    passcode = ((cfg.get("api") or {}).get("passcode")
                or (cfg.get("app") or {}).get("passcode") or "")
    base = base_url or f"http://127.0.0.1:{port}"
    return Target(base, passcode, data_dir, mode, now=now)


def binary_version() -> str:
    src = (ROOT / "Sources/App/main.swift")
    if src.exists():
        import re
        m = re.search(r'static let version\s*=\s*"([^"]+)"', src.read_text())
        if m:
            return m.group(1)
    return "unknown"


def report(results, metrics, sc, drift, baseline, target, quiet=False):
    base_feat = (baseline or {}).get("features", {})
    saved = (baseline or {}).get("saved_at", "never")
    print()
    print(paint(f"Alfred scorecard · tier 1 · {target.mode} · v{binary_version()}", "bold"))
    if target.mode == "sandbox":
        print(paint(f"corpus frozen at {target.now} — ages are reckoned from there", "dim"))
    if sc.get("first_run"):
        print(paint("baseline: none yet — this run is the reference, nothing is a regression",
                    "dim"))
    else:
        print(paint(f"baseline: {saved}"
                    + (f" (v{baseline.get('version')})" if baseline.get("version") else ""),
                    "dim"))
    print()

    width = max(len(n) for _, n in FEATURES)
    for key, name in FEATURES:
        now = sc["features"].get(key)
        if now is None:
            print(f"  {name.ljust(width)}   {paint('— not covered', 'dim')}")
            continue
        before = base_feat.get(key)
        counts = sc["counts"][key]
        arrow = "  —  "
        if before is not None:
            d = round(now - before, 1)
            if d > 0.05:
                arrow = paint(f" ▲{abs(d):>4.0f}", "green")
            elif d < -0.05:
                arrow = paint(f" ▼{abs(d):>4.0f}", "red")
        shown = f"{before:>5.0f} → {now:>3.0f}" if before is not None else f"      {now:>3.0f}"
        tail = f"{counts['pass']}/{counts['pass'] + counts['fail'] + counts['error']}"
        if counts["skip"]:
            tail += paint(f"  +{counts['skip']} n/a", "dim")
        col = "green" if now == 100 else ("yellow" if now >= 75 else "red")
        print(f"  {name.ljust(width)}   {paint(shown, col)}{arrow}   {tail}")

    print("  " + "─" * (width + 28))
    o_now, o_before = sc["overall"], (baseline or {}).get("overall")
    shown = f"{o_before:>5.0f} → {o_now:>3.0f}" if o_before is not None else f"      {o_now:>3.0f}"
    print(f"  {'overall'.ljust(width)}   {paint(shown, 'bold')}")
    print()

    if sc["regressions"]:
        print(paint(f"{len(sc['regressions'])} regression(s) — worse than the baseline", "red"))
        for r, was in sc["regressions"]:
            before = "new" if was is None else was
            print(f"    {r.check.id}  {paint(f'{before} → {r.violations}', 'red')}")
            print(f"      {r.check.title}")
            if r.detail:
                print(paint(f"      {r.detail}", "dim"))
        print()

    if sc["fixed"]:
        print(paint(f"{len(sc['fixed'])} fixed since the baseline", "green"))
        for r, was in sc["fixed"]:
            print(f"    {r.check.id}  {was} → 0   {r.check.title}")
        print()

    if sc["known"] and not quiet:
        label = (f"{len(sc['known'])} open issue(s) — recorded, not yet a regression"
                 if sc.get("first_run")
                 else f"{len(sc['known'])} known, unchanged — scars, not regressions")
        print(paint(label, "yellow"))
        for r, was in sc["known"]:
            print(f"    {r.check.id}  {r.violations}   {r.check.title}")
            if r.detail:
                print(paint(f"      {r.detail}", "dim"))
        print()

    real_drift = [d for d in drift if d[3] != "new"]
    if real_drift:
        print(paint(f"{len(real_drift)} metric(s) outside tolerance", "yellow"))
        for name, before, now, _ in real_drift:
            print(f"    {name}  {before} → {now}")
        print()
    new_metrics = [d for d in drift if d[3] == "new"]
    if new_metrics and not quiet:
        print(paint(f"{len(new_metrics)} new metric(s) recorded", "dim"))
        print()

    if sc["errors"]:
        print(paint(f"{len(sc['errors'])} check(s) failed to run", "red"))
        for r in sc["errors"]:
            print(f"    {r.check.id}: {r.error}")
        print()

    if target.http_errors:
        print(paint("endpoints that did not answer:", "dim"))
        for p, e in target.http_errors.items():
            print(paint(f"    {p}  {e}", "dim"))
        print()

    if not sc["regressions"] and not real_drift and not sc["errors"]:
        print(paint("no regressions against the baseline.", "green"))
        print()


def warm(args, seconds: float = 3.0) -> None:
    """
    Let a freshly started instance finish writing before anything is measured.

    Reading /api/v2/todos and /api/desk is not passive: the first pass over a corpus collapses
    duplicate promises and dismisses what it has superseded. Measuring before that has happened
    records a halfway state that no later run will reproduce.
    """
    import time as _t
    t = build_target(args.target, args.base_url)
    for path in ("/api/v2/todos", "/api/desk"):
        t.get(path)
    _t.sleep(seconds)


def do_calibrate(args, baseline_path: Path) -> int:
    """
    Measure the band rather than guess it.

    The rule is simple and the discipline is the hard part: run the SAME build, unchanged, N
    times. Whatever spread you see is noise by definition, because nothing causing it was under
    your control. Against the sandbox that spread should be zero — a frozen corpus and a fixed
    binary have nothing left to vary — and a zero band is the useful outcome, because it means
    any later movement is signal. Against the live install it will not be zero, and runs taken
    seconds apart measure the instrument rather than the system: space them with --interval.
    """
    import subprocess
    import time as _t
    started = _t.time()
    runs = []
    for i in range(args.calibrate):
        if i and args.interval:
            print(paint(f"  waiting {args.interval}s …", "dim"), flush=True)
            _t.sleep(args.interval)
        if args.target == "sandbox" and not args.no_reset:
            # Each run starts from a fresh copy, because the instance under test WRITES to its
            # own working copy — a first pass dedupes and dismisses to-dos before any check
            # reads them. Calibrating against one long-lived instance measures a state that has
            # already settled, calls the spread zero, and never exercises the path where that
            # settling happens. Resetting is what makes the number mean "same build, same
            # corpus, twice".
            subprocess.run([str(ROOT / "scripts/eval-sandbox.sh"), "reset"],
                           capture_output=True, check=False)
            warm(args)
        target = build_target(args.target, args.base_url)
        results, metrics = run_checks(target, args.feature, args.check)
        sc = score(results, {})
        runs.append((results, metrics))
        print(paint(f"  run {i + 1}/{args.calibrate}: overall {sc['overall']}", "dim"), flush=True)

    bands, unstable = calibrate(runs)
    moved = {k: v for k, v in bands.items() if v["band"]}

    print()
    print(paint(f"calibration · {args.target} · {args.calibrate} runs of an unchanged build",
                "bold"))
    print()
    if unstable:
        print(paint(f"{len(unstable)} check(s) did not hold still — these are not usable as "
                    f"invariants until they do", "red"))
        for cid, vals in sorted(unstable.items()):
            print(f"    {cid}  {vals}")
        print()
    if moved:
        print(paint(f"{len(moved)} metric(s) with a measurable band", "yellow"))
        for name, b in sorted(moved.items(), key=lambda kv: -kv[1]["band"]):
            print(f"    {name:<28} ±{b['band']}   observed {b['observed']}")
        print()
    else:
        print(paint(f"every one of {len(bands)} metrics returned the same value every time — "
                    f"measured noise is zero", "green"))
        print(paint("  so any later movement is the build, not the weather", "dim"))
        print()

    results, metrics = runs[-1]
    sc = score(results, {})

    # A live band measured in one sitting is worse than no band at all. The thing it is supposed
    # to capture — the corpus moving as messages arrive and passes run — happens over hours, so
    # three runs ninety seconds apart record a near-zero spread, write it down as the truth, and
    # then cry regression on the first honest run tomorrow. The sandbox has no such problem: its
    # corpus is frozen by construction, so a short calibration measures the whole of the noise.
    span = _t.time() - started
    if args.target == "live" and span < LIVE_CALIBRATION_MIN_SPAN and not args.accept_short:
        print(paint(f"not writing live bands: these {args.calibrate} runs spanned "
                    f"{span / 60:.0f} min", "yellow"))
        print(paint(f"  live noise is a question about hours, not minutes. Re-run with, say,"
                    f"\n    ./scripts/eval.sh --live --calibrate 4 --interval 900"
                    f"\n  or pass --accept-short if you really want this spread recorded.",
                    "dim"))
        save_baseline(baseline_path, results, metrics, sc, binary_version())
        print(paint(f"baseline values updated (bands left alone) → "
                    f"{baseline_path.relative_to(ROOT)}", "green"))
        return 0 if not unstable else 1

    save_baseline(baseline_path, results, metrics, sc, binary_version(), bands=bands)
    print(paint(f"bands written → {baseline_path.relative_to(ROOT)}", "green"))
    return 0 if not unstable else 1


def gate_line(sc, drift, baseline) -> str:
    real = [d for d in drift if d[3] != "new"]
    before = (baseline or {}).get("overall")
    arrow = f"{before} → {sc['overall']}" if before is not None else f"{sc['overall']}"
    bits = [f"scorecard {arrow}"]
    bits.append(f"{len(sc['regressions'])} regression(s)" if sc["regressions"] else "no regressions")
    if real:
        bits.append(f"{len(real)} metric drift")
    if sc["fixed"]:
        bits.append(f"{len(sc['fixed'])} fixed")
    if sc["errors"]:
        bits.append(f"{len(sc['errors'])} broken check(s)")
    return " · ".join(bits)


def main() -> int:
    ap = argparse.ArgumentParser(description="Alfred tier-1 scorecard")
    ap.add_argument("--target", choices=("sandbox", "live"), default="sandbox")
    ap.add_argument("--base-url", default=None, help="override the HTTP base")
    ap.add_argument("--feature", default=None, help="one feature key, e.g. claims")
    ap.add_argument("--check", default=None, help="substring of a check id")
    ap.add_argument("--baseline", default=None, help="baseline file (default per target)")
    ap.add_argument("--save-baseline", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--quiet", action="store_true", help="hide known issues and new metrics")
    ap.add_argument("--list", action="store_true", help="list the checks and exit")
    ap.add_argument("--calibrate", type=int, metavar="N", default=0,
                    help="run N times against an unchanged build and measure the noise band")
    ap.add_argument("--interval", type=int, default=0, metavar="SECONDS",
                    help="wait between calibration runs (live noise needs spacing to appear)")
    ap.add_argument("--accept-short", action="store_true",
                    help="write live bands even from a short calibration")
    ap.add_argument("--no-reset", action="store_true",
                    help="calibrate without resetting between runs (measures a settled instance)")
    ap.add_argument("--gate", action="store_true",
                    help="one line, for the Golden Path: verdict only")
    args = ap.parse_args()

    if args.list:
        for key, name in FEATURES:
            cs = [c for c in REGISTRY if c.feature == key]
            print(f"{name} ({len(cs)})")
            for c in cs:
                extra = "" if c.targets == ("sandbox", "live") else f"   [{'/'.join(c.targets)}]"
                print(f"    {c.id:<42} {c.title}{extra}")
        return 0

    baseline_path = Path(args.baseline) if args.baseline else BASELINE_DIR / f"{args.target}.json"
    baseline = load_baseline(baseline_path)

    if args.calibrate:
        return do_calibrate(args, baseline_path)

    target = build_target(args.target, args.base_url)
    results, metrics = run_checks(target, args.feature, args.check)
    if not results:
        print("no checks matched", file=sys.stderr)
        return 2
    sc = score(results, baseline)
    drift = metric_drift(metrics, baseline)

    if args.gate:
        line = gate_line(sc, drift, baseline)
        clean = not sc["regressions"] and not [d for d in drift if d[3] != "new"] and not sc["errors"]
        print(paint(line, "green" if clean else "red"))
        for r, was in sc["regressions"]:
            print(f"    {r.check.id}  {'new' if was is None else was} → {r.violations}  "
                  f"{r.check.title}")
        for name, before, now, _ in [d for d in drift if d[3] != "new"]:
            print(f"    {name}  {before} → {now}")
        return 0 if clean else 1

    if args.json:
        print(json.dumps({
            "target": args.target,
            "version": binary_version(),
            "overall": sc["overall"],
            "features": sc["features"],
            "regressions": [{"id": r.check.id, "was": w, "now": r.violations,
                             "title": r.check.title, "detail": r.detail}
                            for r, w in sc["regressions"]],
            "known": [{"id": r.check.id, "now": r.violations} for r, _ in sc["known"]],
            "fixed": [{"id": r.check.id, "was": w} for r, w in sc["fixed"]],
            "drift": [{"metric": n, "was": b, "now": a, "why": k} for n, b, a, k in drift],
            "errors": [{"id": r.check.id, "error": r.error} for r in sc["errors"]],
        }, indent=2))
    else:
        report(results, metrics, sc, drift, baseline, target, args.quiet)

    if args.save_baseline:
        if args.feature or args.check:
            print("refusing to save a partial run as the baseline", file=sys.stderr)
            return 2
        save_baseline(baseline_path, results, metrics, sc, binary_version())
        if not args.json:
            print(paint(f"baseline saved → {baseline_path.relative_to(ROOT)}", "green"))
        return 0

    if sc["errors"]:
        return 2
    if sc["regressions"] or [d for d in drift if d[3] != "new"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
