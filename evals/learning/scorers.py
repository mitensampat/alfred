from __future__ import annotations
"""
Rule-based scorers for the learning-signal classifier output.

These MIRROR the hard filters in Sources/Agents/Learning/WorkflowLearningService.swift
(`isShallowNarration`, `isTransactionalMessage`). When you change the Swift filter,
update these too — the eval is a contract that the prompt produces output the runtime
filters won't drop.
"""

VALID_TYPES = {"correction", "preference", "reinforcement", "fact", "none"}

# Mirrors isShallowNarration() in WorkflowLearningService.swift
SHALLOW_PREFIXES = [
    "user is ", "user was ", "user wants ", "user wanted ",
    "user prefers ", "user preferred ", "user requested ", "user requests ",
    "user asked ", "user said ", "user expressed ", "user indicates ",
    "user is expressing ", "user is requesting ", "user is asking ",
    "user is sharing ", "user is confirming ", "indicates that ",
    "the user ",
]
SHALLOW_MARKERS = [
    "is expressing a preference",
    "is requesting",
    "suggesting preference",
]

# Mirrors isTransactionalMessage() in WorkflowLearningService.swift
TRANSACTIONAL_PREFIXES = [
    "block ", "show ", "show me", "summarize", "summarise", "list ",
    "add a ", "add task", "create ", "delete ", "remove ", "update ",
    "can you ", "could you ", "please ", "would you ", "will you ",
    "how am i", "how do i", "how is ", "how are ", "how was ",
    "what ", "when ", "where ", "why ", "who ", "which ",
    "do you ", "did you ", "are you ", "is there ", "is it ",
    "give me ", "tell me ", "find ", "look up ", "schedule ",
    "send ", "draft ", "write ", "remind me",
    "1)", "2)", "3)", "- ",
]
TEMPORAL_MARKERS = [
    "tomorrow at", "today at", "yesterday at",
    "next monday", "next tuesday", "next wednesday", "next thursday",
    "next friday", "next saturday", "next sunday",
    " at 9am", " at 10am", " at 11am", " at 12pm", " at 1pm", " at 2pm",
    " at 3pm", " at 4pm", " at 5pm", " at 6pm", " at 7pm", " at 8pm",
    " 9.30pm", " 10.30am", " 11.30am", " 5:45 pm", " 10:30",
    "due date", "this week", "by friday", "by monday",
]


def is_shallow_narration(text: str) -> bool:
    lower = text.strip().lower()
    if any(lower.startswith(p) for p in SHALLOW_PREFIXES):
        return True
    return any(m in lower for m in SHALLOW_MARKERS)


def is_transactional_message(text: str) -> bool:
    trimmed = text.strip()
    lower = trimmed.lower()
    if trimmed.endswith("?"):
        return True
    if any(lower.startswith(p) for p in TRANSACTIONAL_PREFIXES):
        return True
    return any(m in lower for m in TEMPORAL_MARKERS)


def score_signal(signal: dict, expectations: dict = None) -> tuple[bool, list[str]]:
    """
    Score a single Haiku-emitted signal. Returns (passed, failure_reasons).
    Empty failure list with passed=True means the signal is good.
    """
    expectations = expectations or {}
    reasons = []

    sig_type = signal.get("type", "")
    content = signal.get("content", "")
    confidence = signal.get("confidence", 0.0)

    if sig_type not in VALID_TYPES:
        reasons.append(f"invalid type '{sig_type}'")

    # type=none means model declined to extract — that's a valid choice
    if sig_type == "none":
        return (True, [])

    # Content quality checks
    if not content or len(content) < 5:
        reasons.append("content too short / empty")

    if is_shallow_narration(content):
        reasons.append(f"shallow narration: '{content[:80]}'")

    # Transactional check only applies to preference/fact (corrections/reinforcements
    # can legitimately be tied to a specific exchange).
    if sig_type in ("preference", "fact") and is_transactional_message(content):
        reasons.append(f"transactional content for type={sig_type}: '{content[:80]}'")

    if not isinstance(confidence, (int, float)) or not (0.0 <= confidence <= 1.0):
        reasons.append(f"invalid confidence {confidence}")

    # Expectation-driven checks (from fixtures.jsonl)
    forbid = expectations.get("forbid_types", []) or []
    if sig_type in forbid:
        reasons.append(f"type '{sig_type}' is in forbid_types {forbid}")

    require = expectations.get("require_type")
    if require and sig_type != require:
        reasons.append(f"expected type='{require}', got '{sig_type}'")

    return (len(reasons) == 0, reasons)


def score_fixture(haiku_signals: list, expectations: dict) -> tuple[bool, list[str]]:
    """
    Score the full set of signals returned for one fixture (one exchange).
    Pass = all signals pass + any global expectations met.
    """
    expectations = expectations or {}
    all_reasons = []
    all_passed = True

    if not haiku_signals:
        # No signals emitted at all — only OK if expectations allow it
        if expectations.get("require_type"):
            return (False, [f"no signals emitted; expected type='{expectations['require_type']}'"])
        return (True, [])

    for i, sig in enumerate(haiku_signals):
        ok, reasons = score_signal(sig, expectations)
        if not ok:
            all_passed = False
            for r in reasons:
                all_reasons.append(f"signal[{i}]: {r}")

    # Global: if expectations.require_type set, at least ONE signal must match
    require = expectations.get("require_type")
    if require:
        matched = any(s.get("type") == require for s in haiku_signals)
        if not matched:
            all_passed = False
            all_reasons.append(f"no signal matched required type='{require}'")

    return (all_passed, all_reasons)
