# Your Model — review, rating, and what to build

*Nov 2026. A review of `#model` (`/api/self-model`) against the goal you set: Alfred should
interpret you — beliefs, values, open questions — instead of asking you to feed and tidy it.*

---

## What the page is today

Six blocks: **To review** (move/merge proposals), **What moved this week**, **Beliefs**,
**Values**, **Open questions**, **Patterns Alfred sees**. Every row carries four verbs
(Sounds right · Not me · Reword · Delete) and Beliefs and Values each have an "Add" box.

Where each block's content comes from:

| Block | Source | Interpretation involved |
|---|---|---|
| Beliefs | the extractor's `mental_model_shifts` — the last 40 shifts in 180 days, chained by fuzzy string match, one facet per chain | none — the statement is one thread's raw "to" string |
| Values | `facet(kind: value)`, written only by the declared-beliefs import and the Add box | **none at all** |
| Open questions | `open_questions` from reflections in the last 14 days, first-seen-first, capped at 12 | none — dedupe by exact lowercase match |
| Patterns | Learning v2 rows, verbatim | none |
| To review | theme merges + stray-item moves | this part does judge, and well |

## The state of the data (measured on the live store, 12 Nov)

- **140 active beliefs**, 7 shown. 131 of them emergent, every one at confidence 0.65 —
  because confidence *is* `0.55 + 0.1 × shifts` and almost every chain is one shift long.
- **456 open questions.** 6 shown. **Zero** have ever been answered or dismissed, in the
  lifetime of the store.
- **7 values. All imported, none inferred.** Nothing in the codebase can ever produce one.
- **1,774 decisions** — the richest thing Alfred holds about you — read only by
  `GraduationService`'s lexical shortlist. Nothing else interprets them.
- **3 beliefs confirmed, 2 kept, ever.** The page is built around your judgement and has
  received almost none of it. That is the goal failing, measured.
- **36 stray-move proposals** queued in "To review" right now.
- "Patterns Alfred sees" currently lists 8 rows, of which **4 are the same instruction about
  muting one WhatsApp group**, plus `i want you to review what i got done last 7 days`.
- **Nothing reads the model.** `CoachingPromptBuilder`, the chat path, the briefing: zero
  references. Beliefs and values shape nothing Alfred ever says. Only the Desk uses the
  store, and only for themes.

## Rating

| | |
|---|---|
| Store, verdicts, merges, lineage, durability tag — the plumbing | **7 / 10** |
| Beliefs | 5 / 10 |
| UI clarity | 5 / 10 |
| Evidence and provenance (recorded, but never shown) | 4 / 10 |
| Does it conclude anything? | 3 / 10 |
| Maintenance burden it puts on you | 3 / 10 |
| Open questions | 2 / 10 |
| Patterns | 2 / 10 |
| Values | 1 / 10 |
| Is any of it used downstream? | 1 / 10 |
| **Overall, against your goal** | **4 / 10** |

The engineering is better than the thinking. It is a well-built display case for raw
extractions — and a curation chore that charges you for the privilege.

## The diagnosis, in one line

The pipeline is **extract → store → display**. There is no *interpret* stage. Every row you
see is a single thread's artifact, surfaced verbatim at thread granularity, and the way it
gets better is you editing it. Interpretation is the opposite: read all the evidence, conclude
something that no single thread says, and keep re-concluding as evidence arrives.

---

## What ought to be built

**1. A claim synthesis pass — the missing stage.**
Nightly or weekly, cluster the substrate (shifts, decisions, questions, chat corrections) by
subject, then one pass per cluster asks for *claims*: what this person believes (durable or
tactical), what they protect when two goods conflict, what they keep returning to unresolved.
A claim is stored with its evidence refs, support count, and first/last seen — and is
**recomputed** every pass, so wording sharpens and dead claims fade instead of 131 fragments
freezing in place.
The one rule that removes most of today's noise: **a claim surfaces only with support from
≥2 independent days or sources.** A single thread never gets to be a belief.

**2. Values inferred from trade-offs.**
A value is what you choose *against something else*, which is exactly what a decision records.
Mine the 1,774 decisions for conflicts and note which side consistently loses. Three grades:
*confirmed* (declared + behavioural evidence), *aspiration* (declared, no evidence —
`GraduationService` already does this for beliefs), and the new one, *proposed* (observed with
no declaration). That makes Values an output instead of a form.

**3. Open questions: cluster, promote, close, age out.**
A question that recurs across ≥3 reflections or ≥2 workspaces is live; the rest stay
browsable substrate. When a later decision or belief answers one, the pass **closes it with
the answer and the evidence** — Alfred concluding, not asking. No new evidence in 60 days:
archived silently. 456 becomes roughly 8, each one real.

**4. Tension detection.** Belief against belief, declared value against observed decision,
what you say against what you ship. Entirely missing today, and the most valuable thing an
interpreter can offer. A handful of these would earn the page on their own.

**5. Make the model an input.** Inject the curated registers (durable beliefs, values, live
questions — ~400 tokens) into the coaching and chat prompts, the way Learning v2 patterns are
already injected. Then interpretation pays for itself, and wrong claims get corrected in the
flow of use rather than in a curation session.

**6. Confidence that means something.** Evidence count × independence × recency, not
`0.55 + 0.1n`. It drives the Wiki's ordering today, so a flat 0.65 makes that ordering random.

**7. One-tap feedback that actually changes the next pass.** Two verbs, not four: *Not me*
(suppresses the claim **and** the evidence pattern behind it, so the pass can't re-derive it
under a new id — today it can) and *Say it better* (your wording becomes canonical). Both
recorded as learning events the synthesis pass reads.

**8. Page restructure.** Lead with **What Alfred concluded this week** — new and changed
claims, each with its evidence. Then Beliefs · Values · Open questions · Tensions, every row
showing *why* (support count, a representative quote and date). Merges and strays move to a
maintenance screen; they are housekeeping, not self-knowledge.

**9. Fix or drop "Patterns Alfred sees."** Verbatim chat lines, four of them the same mute
instruction, is not a pattern. Either synthesize them or remove the block.

---

## Suggested order

| Phase | What | Why here |
|---|---|---|
| **0** | Stop the noise: dedupe Patterns, cluster + cap questions, show evidence on each row, fix the mismatched counts in the header | days, no new machinery, the page stops embarrassing itself |
| **1** | Claim store + belief synthesis (replaces the shift-chain path, one-time migration keeping anything you confirmed) | the core of the whole idea |
| **2** | Inject the registers into coaching + chat prompts | the payoff; also where errors become visible |
| **3** | Values from trade-offs + grading declared values | the biggest gap against your goal |
| **4** | Question clustering, auto-close, aging | turns 456 into ~8 |
| **5** | Tensions | the thing only an interpreter can do |

## What I need you to decide

1. **Replace or run alongside?** I'd replace the shift-chain beliefs in Phase 1 and migrate
   anything you confirmed or kept. The alternative is two belief sets while we compare.
2. **Cost and cadence.** A weekly pass over ~30 clusters is tens of model calls; nightly is
   7× that. Weekly on a mid-size model is my pick.
3. **Should Alfred propose values**, or only grade the ones you declared? Proposing is the
   real win and the one most likely to feel presumptuous when it misses.
4. **Closing questions silently** when the evidence answers them, or always showing you the
   close for a nod?
5. **How hard should the model steer Alfred's voice** once it is injected — light context, or
   strong enough that you can feel it in the briefing?
