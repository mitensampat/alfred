#!/bin/bash
#
# eval.sh — score this build against the reference scorecard.
#
# Run it after a Golden Path deploy and before merging to main. The post-deploy checklist proves
# the change you made works; this proves nothing else broke while you made it.
#
#   ./scripts/eval.sh                     # tier 1, sandbox, diff against the baseline
#   ./scripts/eval.sh --live              # read-only against the running install on 8080
#   ./scripts/eval.sh --feature claims    # one row, while iterating
#   ./scripts/eval.sh --save-baseline     # accept these numbers as the new floor
#   ./scripts/eval.sh --fresh             # re-snapshot the data first (slow, rarely needed)
#   ./scripts/eval.sh --stale-ok          # score the binary as-is, even if the source moved
#   ./scripts/eval.sh --list              # what is actually checked
#
# Exit status: 0 clean · 1 regression or metric drift · 2 a check itself broke.
#
# By default this starts a sandbox instance against a frozen copy of ~/.alfred, so the run is
# reproducible and cannot write to anything real. --live skips the sandbox and reads the
# production instance directly; every check it runs there is read-only, and the handful that only
# make sense on a live system (connector freshness) run ONLY in that mode.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX_SH="$ROOT/scripts/eval-sandbox.sh"
RUNNER="$ROOT/evals/scorecard/run.py"

MODE="sandbox"
FRESH=0
STALE_OK=0
PASS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --live)    MODE="live"; shift ;;
        --fresh)   FRESH=1; shift ;;
        --stale-ok) STALE_OK=1; shift ;;
        --tier)
            if [ "${2:-1}" != "1" ]; then
                echo "only tier 1 exists so far — tiers 2 and 3 are not built" >&2
                exit 2
            fi
            shift 2 ;;
        *) PASS+=("$1"); shift ;;
    esac
done

if [ "$MODE" = "sandbox" ]; then
    BIN="$ROOT/.build/release/alfred"
    [ -x "$BIN" ] || {
        echo "no release binary — run: swift build -c release" >&2; exit 2; }

    # Refuse to score a binary older than the source it claims to represent.
    #
    # This has now cost two sittings. A baseline taken against a stale binary looks perfectly
    # healthy and is quietly meaningless: the numbers describe a build nobody is running, and
    # the first honest run afterwards reports a pile of regressions that are really just the
    # difference between the two. Worse, it is invisible — the version string comes from the
    # source tree, so a stale binary still prints the version you expect.
    if [ "$STALE_OK" != "1" ]; then
        NEWER=$(find "$ROOT/Sources" -newer "$BIN" \
                     \( -name '*.swift' -o -name '*.html' \) -print -quit 2>/dev/null)
        if [ -n "$NEWER" ]; then
            echo "✗ .build/release/alfred is older than the source — scoring it would describe" >&2
            echo "  a build nobody is running. First changed file found:" >&2
            echo "    ${NEWER#$ROOT/}" >&2
            echo "" >&2
            echo "  swift build -c release        # then re-run" >&2
            echo "  (or pass --stale-ok if you know the difference does not matter)" >&2
            exit 2
        fi
    fi
    if [ "$FRESH" = "1" ]; then
        "$SANDBOX_SH" snapshot || exit 2
        "$SANDBOX_SH" stop >/dev/null 2>&1
    fi
    if ! "$SANDBOX_SH" status 2>/dev/null | grep -q "^running"; then
        "$SANDBOX_SH" start || exit 2
    fi
fi

python3 "$RUNNER" --target "$MODE" ${PASS[@]+"${PASS[@]}"}
