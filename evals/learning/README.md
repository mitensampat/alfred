# Learning-signal classifier eval

A replay eval for the Haiku prompt in `classifyExchangeSignals`
(see `Sources/Agents/Learning/WorkflowLearningService.swift`).

It exists because that prompt was producing shallow procedural narration
("User is expressing a preference for…") instead of durable beliefs
("Prefers high-impact summaries over comprehensive tactical detail"). The eval
is the contract that keeps the prompt honest as it evolves.

## What it does

1. **Reads the live prompt** straight out of `WorkflowLearningService.swift`
   (regex on the `let prompt = """…"""` block). The eval can never silently
   drift from production.
2. **Runs each fixture** through Haiku at `temperature=0` (deterministic-ish).
3. **Scores each output** with rule-based checks that mirror the Swift hard
   filters (`isShallowNarration`, `isTransactionalMessage` — see `scorers.py`).
   Plus per-fixture expectations (`require_type`, `forbid_types`).
4. **Diffs against `baselines/latest.json`** so you can see whether a prompt
   change regressed any fixtures.

## Run it

```bash
# First-time seed from your real learning_events
python3 evals/learning/seed_fixtures.py

# Run the eval (prints failures by default; --verbose prints everything)
python3 evals/learning/run.py

# After you're happy with the score, lock it in as the regression baseline
python3 evals/learning/run.py --save-baseline

# Only run a subset
python3 evals/learning/run.py --filter seed_12
```

API key comes from `$ANTHROPIC_API_KEY`, falling back to
`ai.anthropic_api_key` in `~/.config/alfred/config.json`.

## Two fixture files

- `fixtures_pinned.jsonl` — **committed.** Synthetic regression cases written by
  hand. Safe for git (no PII). Pin a fixture here whenever you want a specific
  behavior locked in across machines.
- `fixtures_seed.jsonl` — **gitignored.** Auto-seeded from your local
  `workflow_learning.db` via `seed_fixtures.py`. Contains real names/emails —
  keep local. Lets each developer eval against their own corpus.

The runner loads both transparently.

## Adding fixtures (how this evolves)

Whenever you spot a real-world bad capture in `/api/memory/all` — or a *good*
capture you want to lock in — add it as a pinned fixture:

1. Open `fixtures_pinned.jsonl`. Each line is one exchange:
   ```json
   {
     "id": "case_shallow_summary",
     "user_message": "summarize WhatsApp from CRED today, first and fastest",
     "assistant_response": "<the assistant's actual reply, or empty>",
     "source_event_type": "chat_preference",
     "notes": "Was being captured as 'User is expressing a preference for…'. Must NOT classify as preference — it's a one-off task.",
     "expectations": {
       "require_type": null,
       "forbid_types": ["preference", "fact"]
     }
   }
   ```
2. Run `python3 evals/learning/run.py --filter case_shallow_summary` to verify
   the current prompt handles it.
3. Once the fixture passes, `--save-baseline` to lock it.

### Expectation fields

- `require_type` (optional): exactly one of `correction|preference|reinforcement|fact|none`.
  At least one emitted signal must match.
- `forbid_types` (optional): list of types that must NOT appear. Use this when
  Haiku is over-classifying a one-off ask as a durable preference.
- (no expectations) → only the hard filters apply (no shallow narration, no
  transactional content in `preference`/`fact`). A clean pass with no
  expectations still means "the prompt didn't produce garbage."

### Good fixture-writing instinct

- Anything you'd be sad to see show up in `/api/memory/all` → add as a fixture
  with `forbid_types`.
- Anything that *should* produce a durable belief → add with `require_type` and
  inspect the content manually for voice.
- Edge cases worth pinning: subtle corrections, sarcasm, multi-intent messages,
  long rambling thoughts, one-word replies.

## When prompt changes drift

If you change the prompt structure (e.g. rename the function, change the
template variable, switch JSON shape), update:

- `extract_classify_prompt()` in `run.py` — the regex.
- `render_prompt()` in `run.py` — interpolation behavior.
- `scorers.py` — keep the Python filters in lockstep with Swift
  `isShallowNarration` / `isTransactionalMessage`.

The eval is intentionally low-magic. If it breaks loudly, that's the point.

## Files

- `run.py` — the runner (entry point).
- `scorers.py` — rule-based scorers, mirror of Swift hard filters.
- `seed_fixtures.py` — one-time bootstrap from `~/.alfred/workflow_learning.db`.
- `fixtures_pinned.jsonl` — synthetic, committed regression cases.
- `fixtures_seed.jsonl` — seeded from your local DB; gitignored (PII).
- `baselines/latest.json` — last `--save-baseline` snapshot (committed).
- `baselines/last_run.json` — most recent run, gitignored.
