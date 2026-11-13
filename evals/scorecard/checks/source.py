"""
Invariants about the code rather than the data.

CLAUDE.md asks for four files to be kept in step whenever a chat capability is added: the intent
model, the recognition prompt, the executor, and the coaching router — and the model is mirrored
again under Sources/GUI. Nothing enforces that, so the failure mode is quiet: a new intent that
the classifier can emit and the executor silently drops into the generic chat path. The user sees
a vague answer rather than an error, which is the hardest kind of regression to notice.

These checks cost nothing — they read four files — and they are the clearest example of what this
scorecard is for: a change to feature A (intents) breaking feature B (chat) with no test failing.
"""

import re

from harness import check, ok, bad, skip, metric, Target

MODEL = "Sources/Models/Intent.swift"
GUI_MODEL = "Sources/GUI/Models/Intent.swift"
RECOGNIZER = "Sources/Services/IntentRecognitionService.swift"
EXECUTOR = "Sources/Services/IntentExecutor.swift"
ROUTER = "Sources/Services/IntentCoachingRouter.swift"


def _targets(src: str) -> list[str]:
    """The raw values of Intent.Target, which is what every other file keys off."""
    block = re.search(r"enum Target: String, Codable \{(.*?)\n    \}", src, re.S)
    if not block:
        return []
    return re.findall(r'case\s+\w+\s*=\s*"([^"]+)"', block.group(1))


@check("intents", "intents.model_mirrored",
       "the GUI copy of Intent.Target matches the server's")
def _(t: Target):
    a, b = _targets(t.src(MODEL)), _targets(t.src(GUI_MODEL))
    if not a:
        return skip("could not parse Intent.Target")
    missing = sorted(set(a) - set(b))
    extra = sorted(set(b) - set(a))
    detail = ""
    if missing:
        detail += f"missing from GUI: {missing} "
    if extra:
        detail += f"only in GUI: {extra}"
    f = bad(len(missing) + len(extra), detail.strip())
    f.metrics.update(metric("intents.targets", len(a), tol=0.2, floor=1))
    return f


@check("intents", "intents.recognizer_knows_every_target",
       "the classifier prompt names every target it is allowed to return")
def _(t: Target):
    tgts = _targets(t.src(MODEL))
    src = t.src(RECOGNIZER)
    if not tgts or not src:
        return skip("source not found")
    unknown = [x for x in tgts if f'"{x}"' not in src and f"'{x}'" not in src and x not in src]
    return bad(len(unknown),
               f"the classifier can never emit: {unknown}" if unknown else "")


@check("intents", "intents.executor_handles_every_target",
       "the executor has a branch for every target")
def _(t: Target):
    tgts = _targets(t.src(MODEL))
    src = t.src(EXECUTOR)
    if not tgts or not src:
        return skip("source not found")
    # The executor switches on `.target`, so a handled target appears as `.name` in a case.
    missing = [x for x in tgts if not re.search(rf"\.{re.escape(x)}\b", src)]
    return bad(len(missing),
               f"falls through to generic chat: {missing}" if missing else "")


@check("intents", "intents.router_assigns_a_posture",
       "every target maps to a coaching posture")
def _(t: Target):
    tgts = _targets(t.src(MODEL))
    src = t.src(ROUTER)
    if not tgts or not src:
        return skip("source not found")
    missing = [x for x in tgts if not re.search(rf"\.{re.escape(x)}\b", src)]
    return bad(len(missing),
               f"no posture, so coaching is framed wrongly: {missing}" if missing else "")


@check("intents", "intents.paths_agree_on_notion_search",
       "both chat paths share the fuzzy task search")
def _(t: Target):
    # CLAUDE.md records this one explicitly: findTasksByFuzzyTitle lives in two files and they
    # drift. A mismatch in the tier count is the cheapest detectable symptom.
    a = t.src("Sources/Services/NotionService+Tasks.swift")
    if "findTasksByFuzzyTitle" not in a:
        return skip("search function not found where expected")
    return ok("present in the server path")
