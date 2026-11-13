#!/bin/bash
#
# eval-sandbox.sh — run this build against a frozen copy of the data.
#
# An eval that scores a build has to read a corpus that does not move underneath it. Alfred's
# real databases change every few minutes as messages arrive, so two runs of identical code
# against ~/.alfred produce different scores, and the delta — the only thing an eval exists to
# produce — becomes noise. This script takes one snapshot, then starts the build against a
# throwaway copy of it on a second port, with ALFRED_EVAL set so the instance cannot email,
# message, push or write to Notion.
#
#   ./scripts/eval-sandbox.sh snapshot   # freeze the current data (do this once, re-do rarely)
#   ./scripts/eval-sandbox.sh start      # fresh copy of the snapshot + server on $PORT
#   ./scripts/eval-sandbox.sh status
#   ./scripts/eval-sandbox.sh stop
#   ./scripts/eval-sandbox.sh reset      # stop, wipe the working copy, start again
#
# The real ~/.alfred is read exactly once, by `snapshot`, with sqlite's own backup API so a
# live database is copied consistently. Nothing else here ever writes to it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="${ALFRED_SANDBOX:-$HOME/.alfred-sandbox}"
SNAPSHOT="$SANDBOX/snapshot"
WORK="$SANDBOX/work"
CONFIG_DIR="$SANDBOX/config"
PORT="${ALFRED_EVAL_PORT:-8081}"
BIN="$ROOT/.build/release/alfred"
PIDFILE="$SANDBOX/alfred.pid"
LOGFILE="$SANDBOX/alfred.log"

REAL_DATA="$HOME/.alfred"
REAL_CONFIG="$HOME/.config/alfred"

green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }

die() { red "✗ $1"; exit 1; }

cmd_snapshot() {
    [ -d "$REAL_DATA" ] || die "no data directory at $REAL_DATA"
    rm -rf "$SNAPSHOT"
    mkdir -p "$SNAPSHOT"

    # Databases through sqlite's backup API: a plain cp of a live db with a hot WAL can land
    # a torn copy, and a corpus that is subtly broken is worse than no corpus.
    local n=0
    for db in "$REAL_DATA"/*.db; do
        [ -e "$db" ] || continue
        local name; name="$(basename "$db")"
        if sqlite3 "$db" ".backup '$SNAPSHOT/$name'" 2>/dev/null; then
            n=$((n + 1))
        else
            red "  ! could not back up $name (skipped)"
        fi
    done

    # Everything else that is state rather than a database.
    for item in "$REAL_DATA"/*.json "$REAL_DATA"/*.jsonl "$REAL_DATA"/*.md; do
        [ -e "$item" ] || continue
        cp -p "$item" "$SNAPSHOT/" 2>/dev/null || true
    done
    for dir in agents skills tenets analyses decisions signal_history; do
        [ -d "$REAL_DATA/$dir" ] && cp -R "$REAL_DATA/$dir" "$SNAPSHOT/$dir" 2>/dev/null || true
    done

    # Config, with the port moved and the sandbox marked. The API keys come along: the eval
    # needs them to call models. Everything that could reach a PERSON is blocked by ALFRED_EVAL.
    mkdir -p "$CONFIG_DIR"
    if [ -f "$REAL_CONFIG/config.json" ]; then
        if command -v jq >/dev/null 2>&1; then
            # Both keys: the server reads api.port, app.port is legacy but still present.
            jq --argjson p "$PORT" '.api.port = $p | .app.port = $p' \
                "$REAL_CONFIG/config.json" > "$CONFIG_DIR/config.json"
        else
            die "jq is required to rewrite the sandbox port (brew install jq)"
        fi
    else
        die "no config at $REAL_CONFIG/config.json"
    fi

    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$SNAPSHOT/.taken_at"
    green "✓ snapshot: $n databases + state → $SNAPSHOT"
    dim "  taken $(cat "$SNAPSHOT/.taken_at") · config → $CONFIG_DIR/config.json (port $PORT)"
}

cmd_start() {
    [ -d "$SNAPSHOT" ] || die "no snapshot yet — run: $0 snapshot"
    [ -x "$BIN" ] || die "no release binary at $BIN — run: swift build -c release"
    if is_running; then
        dim "already running (pid $(cat "$PIDFILE")) on port $PORT"; return 0
    fi
    if lsof -i ":$PORT" >/dev/null 2>&1; then
        die "port $PORT is already in use by something else"
    fi

    # Fresh working copy every start: an eval that inherits the last run's writes is not
    # measuring this build, it is measuring this build plus history.
    rm -rf "$WORK"
    cp -R "$SNAPSHOT" "$WORK"

    ALFRED_DIR="$WORK" ALFRED_CONFIG_DIR="$CONFIG_DIR" ALFRED_EVAL=1 \
        "$BIN" server > "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"

    for _ in $(seq 1 25); do
        sleep 0.4
        if curl -s "http://127.0.0.1:$PORT/api/health?passcode=$(passcode)" | grep -q '"ok"'; then
            green "✓ sandbox up on $PORT (pid $(cat "$PIDFILE"))"
            dim "  data: $WORK"
            dim "  log:  $LOGFILE"
            grep -m1 '📁' "$LOGFILE" 2>/dev/null | sed 's/^/  /' || true
            return 0
        fi
    done
    red "✗ did not come up — last lines of $LOGFILE:"
    tail -15 "$LOGFILE" || true
    exit 1
}

cmd_stop() {
    if is_running; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        sleep 1
        rm -f "$PIDFILE"
        green "✓ stopped"
    else
        dim "not running"
    fi
}

cmd_status() {
    if is_running; then
        green "running — pid $(cat "$PIDFILE"), port $PORT"
        curl -s "http://127.0.0.1:$PORT/api/health?passcode=$(passcode)" | sed 's/^/  /'
        echo
    else
        dim "not running"
    fi
    [ -f "$SNAPSHOT/.taken_at" ] && dim "snapshot taken $(cat "$SNAPSHOT/.taken_at")"
    return 0
}

cmd_reset() { cmd_stop; rm -rf "$WORK"; cmd_start; }

is_running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

passcode() {
    jq -r '.app.passcode // .api.passcode // empty' "$CONFIG_DIR/config.json" 2>/dev/null
}

case "${1:-}" in
    snapshot) cmd_snapshot ;;
    start)    cmd_start ;;
    stop)     cmd_stop ;;
    status)   cmd_status ;;
    reset)    cmd_reset ;;
    *)
        echo "usage: $0 {snapshot|start|stop|status|reset}"
        echo
        echo "  snapshot   freeze ~/.alfred into $SNAPSHOT (sqlite backup API)"
        echo "  start      fresh copy of the snapshot, server on port $PORT, ALFRED_EVAL=1"
        echo "  stop       stop the sandbox instance"
        echo "  status     is it up, and how old is the snapshot"
        echo "  reset      stop, wipe the working copy, start clean"
        exit 1
        ;;
esac
