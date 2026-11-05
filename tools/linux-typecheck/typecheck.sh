#!/bin/bash
# Type-check Alfred's Swift sources on Linux (no Mac needed).
# Copies Sources to a temp dir, comments out Apple-only imports, drops the few Mac-only files
# (menu bar, GUI automation, Signal keychain, app entry point) and replaces them with the
# stand-ins in ZZ_Shims.swift, then runs `swiftc -typecheck`. Exit code 0 = no errors.
# It checks types only; it does not build or run the app.
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# swiftc must be on PATH (or set SWIFT_BIN to its bin directory). Swift 6.0 for Linux works.
[ -n "$SWIFT_BIN" ] && export PATH="$SWIFT_BIN:$PATH"
W="${TMPDIR:-/tmp}/alfred-linux-typecheck"; rm -rf $W; mkdir -p $W
cd "$REPO/Sources"
find . -name '*.swift' | grep -vE '^\./GUI/(Views|Models|Core)/' | grep -vE 'GUI/Services/(AlfredService|ClaudeAIService|CommitmentAnalyzer|GoogleCalendarService|HTTPServer|IntentExecutor|IntentRecognitionService|MultiCalendarService|NotificationService|NotionService\+Tasks)\.swift' > $W/files.txt
grep -E 'exclude' -A40 /home/user/alfred/Package.swift | grep -oE '"GUI/[^"]+"' | tr -d '"' > $W/excl.txt
while read f; do
  g=${f#./}
  if grep -qxF "$g" $W/excl.txt; then continue; fi
  skip=0; while read e; do case "$g" in "$e"/*) skip=1;; esac; done < $W/excl.txt
  [ $skip = 1 ] && continue
  mkdir -p $W/src/$(dirname $g)
  sed -E 's/^import (AppKit|UserNotifications|Cocoa|SwiftUI|ServiceManagement|ApplicationServices|Contacts|Security|CommonCrypto|Combine|CryptoKit)$/\/\/ (shim) &/; s/^import Foundation$/import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif/' "$f" > $W/src/$g
done < $W/files.txt
cp "$HERE/ZZ_Shims.swift" $W/src/
rm -rf $W/src/App $W/src/GUI/ViewModels $W/src/GUI/SlackTheme.swift; rm -f $W/src/Services/MenuBarController.swift $W/src/Services/WhatsAppGUIAutomation.swift $W/src/Services/MessageReaders/SignalReader.swift
python3 - "$W/src/Services/WebPushService.swift" <<'PY'
import sys,re
p=sys.argv[1]; L=open(p).read().split('\n')
head=L[:next(i for i,l in enumerate(L) if 'Send a push to a single subscriber' in l)]
start=next(i for i,l in enumerate(L) if l.startswith('// MARK: - Errors'))
tail=L[start:]
stub='''    private func loadSubscriptions() {}
    private func saveSubscriptions() {}
    func sendSingle(to subscription: PushSubscription, payload: PushPayload, vapidPublicKey: String, vapidPrivateKey: String, vapidSubject: String) async throws {}
    static func generateVAPIDKeys() -> (publicKey: String, privateKey: String) { ("", "") }
}'''
open(p,'w').write('\n'.join(head)+'\n'+stub+'\n'+'\n'.join(tail))
PY
cd $W/src && find . -name '*.swift' > ../list.txt
swiftc -typecheck -swift-version 5 -I "$HERE/shims" $(cat ../list.txt) > $W/out.txt 2>&1
grep -E "^[A-Za-z./_+-]+\.swift:[0-9]+:[0-9]+: error:" $W/out.txt
n=$(grep -cE '^[A-Za-z./_+-]+\.swift:[0-9]+:[0-9]+: error:' $W/out.txt)
echo "errors: $n"; [ "$n" = 0 ]
