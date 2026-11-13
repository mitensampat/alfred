#!/usr/bin/env python3
"""
The scorecard harness: how a check is declared, how it reads Alfred, how a run is scored.

A check asserts something that must be true of Alfred's state. It is not a unit test — it never
constructs a scenario. It looks at the state a real build produced from a real corpus and asks
whether that state is self-consistent. That is why it can catch a regression in a feature nobody
touched: the evidence of the breakage is in the data, whatever code put it there.

Three ideas carry the whole thing:

1. A check reports a VIOLATION COUNT, not a boolean. "Four closures point at commitments that no
   longer exist" is a more useful thing to carry forward than "closure integrity: FAIL", because
   the number is what the next run compares against.

2. A violation that already existed when the baseline was taken is KNOWN, not a failure. Real
   databases carry scars from bugs fixed months ago, and a check that is red on day one is a
   check that gets ignored by day three. Known violations still lower the score — the score
   should be honest — but only an INCREASE blocks anything.

3. Numbers that have no right answer are METRICS, not checks. There is no correct number of
   fronts. There is a correct way for that number to behave: it should not halve because someone
   changed the self-model. Metrics carry a tolerance and are reported as drift.
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional

ROOT = Path(__file__).resolve().parent.parent.parent

# The scorecard's rows, in the order they print. The key is what a check attaches itself to.
FEATURES: list[tuple[str, str]] = [
    ("connectors", "Ingestion & connectors"),
    ("extraction", "Commitment extraction"),
    ("closure",    "Closure detection"),
    ("todos",      "To-dos & Notion sync"),
    ("intents",    "Chat intents"),
    ("briefing",   "Briefing"),
    ("claims",     "Self-model: claims"),
    ("questions",  "Self-model: questions"),
    ("tensions",   "Tensions"),
    ("values",     "Values"),
    ("hygiene",    "Hygiene & stray queue"),
    ("desk",       "Desk / Now / fronts"),
    ("people",     "People"),
    ("learning",   "Learning v2"),
    ("injection",  "Prompt injection"),
    ("cadences",   "Scheduler & cadences"),
]
FEATURE_NAMES = dict(FEATURES)


# ── What a check gives back ─────────────────────────────────────────────────

@dataclass
class Finding:
    violations: int = 0
    detail: str = ""
    skipped: Optional[str] = None
    metrics: dict[str, Any] = field(default_factory=dict)


def ok(detail: str = "") -> Finding:
    return Finding(0, detail)


def bad(n: int, detail: str = "") -> Finding:
    """n violations. n==0 is a pass, so a check can just count and return."""
    return Finding(max(0, int(n)), detail)


def skip(why: str) -> Finding:
    return Finding(0, "", skipped=why)


# ── The registry ────────────────────────────────────────────────────────────

@dataclass
class Check:
    feature: str
    id: str
    title: str
    fn: Callable[["Target"], Finding]
    targets: tuple[str, ...] = ("sandbox", "live")


REGISTRY: list[Check] = []


def check(feature: str, id: str, title: str, targets: tuple[str, ...] = ("sandbox", "live")):
    """
    Declare a check.

    `targets` exists because some invariants are only meaningful against the running install.
    "The newest WhatsApp message is less than a day old" is true of a live system and false of a
    frozen snapshot the moment the snapshot is a day old — asserting it in the sandbox would
    produce a failure that means nothing except that time passed.
    """
    if feature not in FEATURE_NAMES:
        raise ValueError(f"unknown feature {feature!r}")

    def wrap(fn):
        REGISTRY.append(Check(feature, id, title, fn, targets))
        return fn
    return wrap


def metric(name: str, value: Any, tol: float = 0.25, floor: int = 2) -> dict:
    """
    A number to watch rather than assert.

    `tol` is a fraction of the baseline; `floor` is the absolute slack below which a change is
    noise. Small counts move by one for entirely ordinary reasons, and a scorecard that cries
    about 3 → 4 is a scorecard that gets muted.
    """
    return {name: {"value": value, "tol": tol, "floor": floor}}


# ── Reading Alfred ──────────────────────────────────────────────────────────

class Target:
    """The instance under test: its HTTP surface, its databases, and its source tree."""

    def __init__(self, base: str, passcode: str, data_dir: Path, mode: str, timeout: int = 60):
        self.base = base.rstrip("/")
        self.passcode = passcode
        self.data_dir = Path(data_dir)
        self.mode = mode            # "sandbox" | "live"
        self.timeout = timeout
        self._http: dict[str, Any] = {}
        self._sql: dict[str, sqlite3.Connection] = {}
        self._src: dict[str, str] = {}
        self._scratch: Optional[Path] = None
        self.http_errors: dict[str, str] = {}

    # HTTP — cached, because a dozen checks read /api/desk and it is not a cheap endpoint.
    def get(self, path: str, **params) -> Any:
        key = path + "?" + urllib.parse.urlencode(sorted(params.items()))
        if key in self._http:
            return self._http[key]
        params = {"passcode": self.passcode, **params}
        url = f"{self.base}{path}?{urllib.parse.urlencode(params)}"
        try:
            with urllib.request.urlopen(url, timeout=self.timeout) as r:
                data = json.loads(r.read().decode("utf-8"))
        except Exception as e:                      # noqa: BLE001 — surfaced, not swallowed
            data = {"__error__": f"{type(e).__name__}: {e}"}
            self.http_errors[path] = data["__error__"]
        self._http[key] = data
        return data

    # SQLite — read from a copy, never from the file the instance is using.
    #
    # Opening the live file read-only looks safer and is in fact less reliable: a WAL database
    # needs a shared-memory file, and a read-only connection cannot create one, so every read
    # fails until the instance under test happens to have opened that database itself. Worse, a
    # read that does succeed sees whatever the server has flushed at that instant, so two checks
    # in the same run can disagree. Copying the file and its WAL once, at first use, gives every
    # check one consistent view and makes it structurally impossible to write to the original.
    def _connect(self, db: str) -> Optional[sqlite3.Connection]:
        src = self.data_dir / db
        if not src.exists():
            return None
        if self._scratch is None:
            import tempfile, atexit, shutil
            self._scratch = Path(tempfile.mkdtemp(prefix="alfred-scorecard-"))
            atexit.register(shutil.rmtree, self._scratch, True)
        import shutil
        dst = self._scratch / db
        shutil.copy2(src, dst)
        for suffix in ("-wal", "-shm"):
            side = Path(str(src) + suffix)
            if side.exists():
                shutil.copy2(side, Path(str(dst) + suffix))
        return sqlite3.connect(str(dst))

    def sql(self, db: str, query: str, args: tuple = ()) -> list[tuple]:
        if db not in self._sql:
            self._sql[db] = self._connect(db)  # type: ignore[assignment]
        conn = self._sql[db]
        if conn is None:
            raise FileNotFoundError(f"{db} not present in {self.data_dir}")
        return conn.execute(query, args).fetchall()

    def has_db(self, db: str) -> bool:
        return (self.data_dir / db).exists()

    def one(self, db: str, query: str, args: tuple = ()) -> Any:
        rows = self.sql(db, query, args)
        return rows[0][0] if rows else None

    # Source — for invariants about the code rather than the data.
    def src(self, rel: str) -> str:
        if rel not in self._src:
            p = ROOT / rel
            self._src[rel] = p.read_text(encoding="utf-8", errors="replace") if p.exists() else ""
        return self._src[rel]


# ── Running ─────────────────────────────────────────────────────────────────

@dataclass
class CheckResult:
    check: Check
    violations: int
    detail: str
    skipped: Optional[str]
    error: Optional[str]
    seconds: float


def run_checks(target: Target, only_feature: Optional[str] = None,
               only_id: Optional[str] = None) -> tuple[list[CheckResult], dict]:
    results: list[CheckResult] = []
    metrics: dict[str, Any] = {}
    for c in REGISTRY:
        if only_feature and c.feature != only_feature:
            continue
        if only_id and only_id not in c.id:
            continue
        if target.mode not in c.targets:
            results.append(CheckResult(c, 0, "", f"not meaningful against {target.mode}", None, 0.0))
            continue
        t0 = time.time()
        try:
            f = c.fn(target)
            results.append(CheckResult(c, f.violations, f.detail, f.skipped, None, time.time() - t0))
            metrics.update(f.metrics)
        except Exception as e:                      # noqa: BLE001
            # A check that throws is a broken check, and that is a result worth seeing rather
            # than a crash that takes the whole run with it.
            results.append(CheckResult(c, 0, "", None, f"{type(e).__name__}: {e}", time.time() - t0))
    return results, metrics


def score(results: list[CheckResult], baseline: dict) -> dict:
    """
    Per-feature scores, plus the three buckets that matter: regressions (worse than baseline),
    known violations (no worse), and errors.
    """
    base_checks = (baseline or {}).get("checks", {})
    # With no baseline there is nothing to regress against. Calling every pre-existing scar a
    # regression on the first run is how a new tool loses its credibility in one sitting.
    first_run = not base_checks
    per_feature: dict[str, dict] = {}
    regressions, known, errors, fixed = [], [], [], []

    for r in results:
        f = per_feature.setdefault(r.check.feature, {"pass": 0, "fail": 0, "skip": 0, "error": 0})
        if r.error:
            f["error"] += 1
            errors.append(r)
            continue
        if r.skipped:
            f["skip"] += 1
            continue
        was = base_checks.get(r.check.id, {}).get("violations")
        if r.violations == 0:
            f["pass"] += 1
            if was:
                fixed.append((r, was))
            continue
        f["fail"] += 1
        if not first_run and (was is None or r.violations > was):
            regressions.append((r, was))
        else:
            known.append((r, was))

    scores = {}
    for key, f in per_feature.items():
        denom = f["pass"] + f["fail"] + f["error"]
        scores[key] = round(100.0 * f["pass"] / denom, 1) if denom else None

    live = [v for v in scores.values() if v is not None]
    return {
        "features": scores,
        "counts": per_feature,
        "overall": round(sum(live) / len(live), 1) if live else None,
        "regressions": regressions,
        "known": known,
        "errors": errors,
        "fixed": fixed,
        "first_run": first_run,
    }


def metric_drift(metrics: dict, baseline: dict) -> list[tuple[str, Any, Any, str]]:
    """Metrics that moved further than their tolerance allows."""
    base = (baseline or {}).get("metrics", {})
    out = []
    for name, spec in sorted(metrics.items()):
        now = spec["value"]
        before = base.get(name, {}).get("value") if isinstance(base.get(name), dict) else base.get(name)
        if before is None:
            out.append((name, None, now, "new"))
            continue
        if not isinstance(now, (int, float)) or not isinstance(before, (int, float)):
            if now != before:
                out.append((name, before, now, "changed"))
            continue
        slack = max(abs(before) * spec.get("tol", 0.25), spec.get("floor", 2))
        if abs(now - before) > slack:
            out.append((name, before, now, "drift"))
    return out


def load_baseline(path: Path) -> dict:
    if path.exists():
        try:
            return json.loads(path.read_text())
        except Exception:                           # noqa: BLE001
            return {}
    return {}


def save_baseline(path: Path, results: list[CheckResult], metrics: dict,
                  scores: dict, version: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "saved_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "version": version,
        "overall": scores["overall"],
        "features": scores["features"],
        "checks": {
            r.check.id: {"violations": r.violations, "feature": r.check.feature}
            for r in results if not r.skipped and not r.error
        },
        "metrics": {k: {"value": v["value"]} for k, v in metrics.items()},
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
