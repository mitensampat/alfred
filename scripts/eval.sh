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
PASS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --live)    MODE="live"; shift ;;
        --fresh)   FRESH=1; shift ;;
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
    [ -x "$ROOT/.build/release/alfred" ] || {
        echo "no release binary — run: swift build -c release" >&2; exit 2; }
    if [ "$FRESH" = "1" ]; then
        "$SANDBOX_SH" snapshot || exit 2
        "$SANDBOX_SH" stop >/dev/null 2>&1
    fi
    if ! "$SANDBOX_SH" status 2>/dev/null | grep -q "^running"; then
        "$SANDBOX_SH" start || exit 2
    fi
fi

python3 "$RUNNER" --target "$MODE" ${PASS[@]+"${PASS[@]}"}
