# A reference scorecard for Alfred

*Nov 2026. A proposal, not a build. The goal in one line: changing feature A should not quietly
regress feature B, and we should find that out before the change reaches main.*

---

## What exists today, and why it doesn't answer the question

| | What it does | What it can't tell us |
|---|---|---|
| `scripts/run_tests.sh` | ~12 suites of HTTP smoke tests — does the endpoint answer, is the shape right, does auth hold | Nothing about whether the *content* got worse. A briefing that returns 200 and says nothing passes. |
| `evals/learning/` | A real replay eval for one prompt: reads the live prompt out of the Swift source, runs fixtures through Haiku at temperature 0, scores with rules that mirror the production filters, diffs against a saved baseline | It covers one prompt out of roughly a dozen that matter, and nothing outside the learning classifier. |
| `scripts/eval_learning_system.sh` | Phase-by-phase manual checks for the v2 learning upgrade | One-off, written for one migration. |

So we have a good *pattern* (`evals/learning/`) and no *coverage*. This proposal is mostly
"do what that directory already does, for the features that matter, and roll the results into
one number per feature."

The honest statement of the current position: today the only thing standing between a change in
one feature and a silent regression in another is me reading the code and remembering to check.
That has already failed once this month — the claim-synthesis work archived belief fragments,
which would have demoted Desk fronts, and it was caught by accident rather than by a check.

## The three tiers

Most regressions are not subtle. They are counts going to zero, invariants breaking, and passes
stopping being idempotent. Those are free to detect. Only a thin top layer needs a model, and a
thinner one needs judgement.

**Tier 1 — invariants.** Deterministic assertions over the API and the databases. No model
calls, runs in seconds, catches most real regressions. Examples:

- every active claim cites ≥2 evidence items across ≥2 distinct days (the rule the synthesizer
  promises) — a violation means the gate broke
- no resolved question lacks both an answer and its evidence
- a tension's two sides are both live facets, and no tension points at itself
- `reconcileProposals` run twice changes nothing the second time
- no pending move proposal names a workspace that is not live
- front count sits inside a band (a change that halves it is a regression even if nothing errors)
- `promptContext()` is non-empty, inside its character budget, and contains its three sections
- every extracted to-do has at least one source link; no duplicate hash
- each connector's newest item is younger than its staleness threshold

**Tier 2 — replay.** The `evals/learning` pattern, applied per prompt: fixtures in, model at
temperature 0, rule-based scorers, baseline diff. The prompts worth covering, in order of how
much damage a silent regression does: claim synthesis, question closing, commitment extraction,
closure detection, intent recognition, tension finding, briefing composition.

**Tier 3 — judged.** A rubric and a judge model, only where a rule cannot express the quality.
"Is this a claim about the person rather than a summary of an event?" is a Tier 3 question.
Small (20–30 items), slower, noisier, run on demand rather than every build.

## The scorecard

One row per feature, scored 0–100, with the tier mix that suits it:

| Feature | T1 invariants | T2 replay | T3 judged |
|---|---|---|---|
| Ingestion & connectors | ●●● | — | — |
| Commitment extraction | ●● | ●●● | ● |
| Closure detection | ●● | ●●● | — |
| To-dos & Notion sync | ●●● | — | — |
| Chat intents | ● | ●●● | — |
| Briefing | ●● | ● | ●● |
| Self-model: claims | ●●● | ●●● | ●● |
| Self-model: questions | ●●● | ●● | ● |
| Tensions | ●● | ● | ●● |
| Values | ●● | ● | ● |
| Hygiene & stray queue | ●●● | — | — |
| Desk / Now / fronts | ●●● | — | ● |
| People | ●● | — | — |
| Learning v2 | ● | ●●● *(exists)* | — |
| Prompt injection | ●●● | — | ●● |
| Scheduler & cadences | ●●● | — | — |

**Scoring.** Each check is pass/fail (T1, T2) or 0–3 against a rubric (T3). A feature's score is
the weighted pass rate. The overall scorecard is the unweighted mean of feature scores, reported
alongside the per-feature table — one number is for the commit message, the table is for the
decision.

**The thing that actually matters is the delta.** An absolute score of 87 means nothing. A
feature that scored 94 last build and 71 this build, when the change was supposed to touch a
different feature, is the entire product of this system. The runner prints:

```
self-model: claims     94 → 71   ▼ 23   (4 fixtures newly failing)
desk / fronts          88 → 88     —
hygiene & stray queue  —  → 96    new
```

Nothing is "failing" in the CI sense except a drop beyond a feature's noise band.

## The part that needs building first: isolation

This is the one real obstacle, and it is worth stating plainly before anything else is planned.

Alfred reads and writes `~/.alfred` from **99 call sites across 43 files**. `ALFRED_DIR` is
honoured in exactly three newer services (`DeskService`, `SchedulePreferences`,
`ScheduleService`). So today an eval run would:

- read a live database that changes on its own, because new messages keep arriving — a score
  would drift between two runs of identical code, which destroys the delta that is the whole
  point
- mutate real data as it exercises write paths

The fix is mechanical, not clever: one `AlfredPaths` helper that resolves the data directory
(honouring `ALFRED_DIR`) and the config directory, and replacing those 99 sites with it. Then
the eval harness can:

1. snapshot the live databases into a scratch directory once, and commit the *shape* of that
   snapshot (not its contents) as the frozen corpus
2. start a second Alfred on port 8081 with `ALFRED_DIR` pointed at a fresh copy of the snapshot
3. run the scorecard against it, mutate freely, and throw the copy away

Without this, Tier 1 is limited to read-only checks against live data and the deltas stay noisy.
With it, two runs of the same build produce the same score, which is the property everything
else depends on.

## Determinism and noise

- Everything model-facing runs at temperature 0.
- Tier 3 judged items run N=3 and report the median plus spread; a delta inside the spread is
  not reported as a regression.
- Each feature gets a noise band measured empirically — run the scorecard three times against an
  unchanged build, and the observed spread *is* the band.
- Prompt changes are non-deterministic by nature. The scorecard reduces that, it does not remove
  it, and a single green run after a prompt change is weaker evidence than a single green run
  after a code change. The report should say so on the row.

## Fixtures and personal data

Keep the two-file policy `evals/learning` already uses, because it is right:

- `fixtures_pinned.jsonl` — committed, synthetic, no names, no thread content. Locks a behaviour
  in across machines.
- `fixtures_local.jsonl` — gitignored, seeded from the real databases. Each machine evals against
  its own corpus.

Every regression found in real data gets a de-identified pinned fixture written for it. That is
how the scorecard grows: it is a record of every bug we have actually hit.

## Running it

```bash
./scripts/eval.sh                      # tiers 1+2, all features, diff vs baseline
./scripts/eval.sh --tier 1             # seconds, no model calls
./scripts/eval.sh --feature self-model # one row, while iterating
./scripts/eval.sh --all                # include tier 3
./scripts/eval.sh --save-baseline      # after you accept the new numbers
```

Rough cost per full run: Tier 1 free and under a minute; Tier 2 roughly 50–70 model calls
(cents on Haiku/Sonnet, more if a pass uses Opus); Tier 3 another ~60 calls with N=3. So a
routine run is cheap and an `--all` run is not free but is far from expensive.

**Where it plugs in.** The Golden Path in `CLAUDE.md` gains a step between "verify" and "merge":
run `./scripts/eval.sh`, paste the delta table, and only merge on no unexplained regression.
This replaces nothing in the existing post-deploy checklist — that checklist proves the change
works; the scorecard proves nothing else broke.

## Build order

| Phase | What | Why here |
|---|---|---|
| **0** | `AlfredPaths` + `ALFRED_DIR` everywhere; snapshot/restore script; second instance on 8081 — **done, Nov 13** (see below) | nothing below is trustworthy without it |
| **1** | Tier 1 invariants for all 16 features + the runner, baseline format, delta report | the cheapest 80% of the value |
| **2** | Golden Path integration + noise-band calibration | makes it a habit rather than a tool |
| **3** | Tier 2 replay for claims, questions, extraction, intents (generalising `evals/learning/run.py`) | the content regressions Tier 1 cannot see |
| **4** | Tier 3 judged rows for claims, tensions, briefing, injection | the quality questions rules cannot express |

Phases 0–2 are the ones that change daily practice. Phases 3–4 can lag.

## What I need you to decide

1. **Is Phase 0 worth it?** Touching 99 call sites to get isolation is the price of scores that
   mean anything. The alternative is read-only Tier 1 against live data, which is cheaper, works
   next week, and gives noisier deltas forever.
2. **What's the bar?** Should an unexplained regression *block* a merge, or just print loudly and
   let me judge? Blocking is honest and will occasionally be annoying.
3. **Scope of the first cut.** All 16 features at Tier 1, or the five that have actually broken
   (self-model, hygiene, Desk, extraction, connectors) done properly first?
4. **Who runs it.** Every build, or only before a merge to main? Every build is better discipline
   and makes the noise band easy to measure.
5. **Tier 3 at all?** It is the only layer that can catch "the beliefs got blander", and the only
   one whose own score I would not fully trust.

---

## Phase 0, as built (Nov 13)

`AlfredPaths` resolves the data directory (`ALFRED_DIR`), the config directory
(`ALFRED_CONFIG_DIR`) and an eval flag (`ALFRED_EVAL`); 101 path expressions across 49 files now
go through it. `scripts/eval-sandbox.sh` snapshots the live databases with sqlite's backup API,
then starts this build on port 8081 against a **fresh copy** of that snapshot each time.

In eval mode the instance cannot reach anyone: the scheduler does not start, the Notion mirror
does not start, and email, WhatsApp sends and web push return early. The LaunchAgent is never
installed or rewritten. `/api/health` now reports `eval` and `data_dir`, so a harness can prove
which instance it is talking to before it writes anything — passing the right port is not proof,
since the port is a config value like any other.

Two things turned up on the way, both now fixed:

- the startup port guard tested a hardcoded 8080 before the config was loaded, so a second
  instance on another port exited as a "duplicate"; it now guards the port it is actually about
  to bind
- the server reads `api.port`, while `CLAUDE.md` documented `app.port` — the sandbox silently
  came up on the wrong port until that was found

Measured on the real install: a fresh sandbox run and the next one return identical state (22
values, same counts), and a write made inside the sandbox left `~/.alfred/self_model.db`
byte-identical. That is the property everything above depends on.
