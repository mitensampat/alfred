# linux type-check

Type-checks every Swift source on Linux, for sessions without a Mac.

```bash
SWIFT_BIN=/path/to/swift/usr/bin tools/linux-typecheck/typecheck.sh
```

It prints any errors and exits non-zero if there are some. It checks types only: it does not build or run the app, and the Mac-only files it swaps for stand-ins (`ZZ_Shims.swift`) are not checked. Never add `ZZ_Shims.swift` to the package.
