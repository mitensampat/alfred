# The reference scorecard — Tier 1

*Changing feature A should not quietly regress feature B. This is the layer that notices.*

```bash
./scripts/eval.sh                     # sandbox on 8081, diff against the baseline
./scripts/eval.sh --live              # read-only against the running install on 8080
./scripts/eval.sh --feature claims    # one row, while iterating
./scripts/eval.sh --save-baseline     # accept these numbers as the new floor
./scripts/eval.sh --list              # everything that is checked, in English
```

A full run is **73 checks across 16 features in about five seconds**, with no model calls and no
API cost. Exit status is `0` clean, `1` a regression or metric drift, `2` a check itself broke.

## What a Tier 1 check is

It is not a unit test. It never builds a scenario. It looks at the state a real build produced
from a real corpus and asks whether that state is self-consistent — every closure points at a
commitment that exists, every claim cites the evidence the gate promised to require, every intent
the classifier can emit has a branch in the executor.

That is why it catches regressions in features nobody touched. The evidence of the breakage is in
the data, whatever code put it there.

Three ideas carry the design:

**A check reports a violation count, not a boolean.** "Fourteen commitments have more than one
closure row" is a more useful thing to carry forward than `FAIL`, because the number is what the
next run compares against.

**A violation that predates the baseline is *known*, not a failure.** Real databases carry scars
from bugs fixed months ago — this install had fourteen double-counted closures, all from March
and April, none since the November fix. A check that is red on day one is a check that gets
ignored by day three. Known violations still lower the score, because the score should be honest,
but only an *increase* is reported as a regression and only an increase sets a non-zero exit.

**Numbers with no right answer are metrics, not checks.** There is no correct number of fronts.
There is a correct way for that number to behave: it should not halve because someone changed the
self-model. Metrics carry a tolerance (a fraction of the baseline, with an absolute floor so that
3 → 4 is not an incident) and are reported as drift.

## Sandbox or live

Default is the sandbox: `scripts/eval-sandbox.sh` snapshots `~/.alfred` through sqlite's backup
API and runs this build on port 8081 against a **fresh copy** with `ALFRED_EVAL=1`, so the
instance cannot email, message, push or write to Notion. Two runs of the same build return
identical numbers — the property the delta depends on.

`--live` reads the running install instead. Every check is read-only and databases are read from
a copy, so a live run cannot change what it is scoring. Use it to check the real system; use the
sandbox when you care about the delta.

A handful of checks declare `targets=("live",)` and are skipped in the sandbox, shown as `n/a`.
Connector freshness is the clearest case: "the newest message is less than 24h old" is true of a
live system and false of any snapshot older than a day, so asserting it against frozen data would
measure nothing but the passage of time. Full Disk Access is the same — the sandbox runs the bare
binary rather than the signed app bundle, so iMessage is structurally unavailable there.

## Adding a check

Checks live in `checks/`, grouped by area: `model.py` (claims, questions, tensions, values,
hygiene), `work.py` (commitments, closures, to-dos, Desk, people), `system.py` (connectors,
briefing, learning, injection, cadences), `source.py` (invariants about the code itself).

```python
@check("claims", "claims.evidence_floor", "every synthesized claim cites >= 2 evidence items")
def _(t: Target):
    rows = t.sql("self_model.db", "SELECT id, evidence_json FROM self_facet WHERE ...")
    thin = [i for i, e in rows if len(json.loads(e or "[]")) < 2]
    f = bad(len(thin), f"{len(thin)} below the floor")
    f.metrics.update(metric("claims.active", len(rows)))
    return f
```

The title is the invariant stated in plain English, because it is what prints when the check goes
red and the person reading it may be you in four months.

**Write one for every regression you actually hit.** That is how the scorecard grows, and it is
the only growth rule worth having: it becomes a record of the bugs this project has really had,
not a list of things that seemed worth asserting.

Three checks assert against constants also written in the Swift source — the prompt-context
budget, the claim support floor, the proposal expiry. One of them (`injection.budget_matches_source`)
checks that the constant here still matches the constant there, so the two cannot drift apart in
silence. Prefer that pattern over duplicating a number and hoping.

## What is not here

Tier 1 only. It reads state; it does not judge content. A briefing that returns a well-formed
summary of nothing passes every check in this directory. Tier 2 (replay against fixtures at
temperature 0, generalising `evals/learning/`) and Tier 3 (a judge model against a rubric) are
described in `docs/proposals/eval-scorecard.md` and are not built.

So: a green scorecard means nothing broke structurally. It does not mean the output got better,
and after a prompt change it is weaker evidence than after a code change.
