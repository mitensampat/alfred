// signal-decrypt — isolated SQLCipher helper for Alfred's Signal (no-FDA) integration.
//
// Decrypts a SQLCipher-encrypted Signal db into a plaintext copy the main app can read
// with its normal sqlite. SQLCipher (and OpenSSL) are statically linked here ONLY, so
// the main Alfred binary never links SQLCipher and there is no symbol conflict.
//
//   usage: signal-decrypt <encrypted-src.sqlite> <plaintext-out.sqlite>
//   the 64-hex SQLCipher key is read from stdin (not argv, so it never hits `ps`).
//   exit 0 on success; non-zero + stderr message on failure.
#include "sqlite3.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fail(sqlite3 *db, const char *what) {
    fprintf(stderr, "signal-decrypt: %s: %s\n", what, db ? sqlite3_errmsg(db) : "");
    if (db) sqlite3_close(db);
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: signal-decrypt <src> <out>\n"); return 2; }
    const char *src = argv[1], *out = argv[2];

    char key[128] = {0};
    if (!fgets(key, sizeof(key), stdin)) { fprintf(stderr, "signal-decrypt: no key on stdin\n"); return 2; }
    key[strcspn(key, "\r\n")] = 0;                 // trim newline
    size_t n = strlen(key);
    if (n != 64) { fprintf(stderr, "signal-decrypt: key must be 64 hex chars (got %zu)\n", n); return 2; }

    remove(out);                                    // fresh plaintext copy each run

    sqlite3 *db = NULL;
    if (sqlite3_open(src, &db) != SQLITE_OK) return fail(db, "open src");

    char pragma[160];
    snprintf(pragma, sizeof(pragma), "PRAGMA key = \"x'%s'\";", key);
    if (sqlite3_exec(db, pragma, 0, 0, 0) != SQLITE_OK) return fail(db, "set key");
    if (sqlite3_exec(db, "PRAGMA cipher_compatibility = 4;", 0, 0, 0) != SQLITE_OK) return fail(db, "compat");

    // Confirm the key actually decrypts before exporting.
    if (sqlite3_exec(db, "SELECT count(*) FROM sqlite_master;", 0, 0, 0) != SQLITE_OK) return fail(db, "wrong key / decrypt failed");

    char attach[512];
    snprintf(attach, sizeof(attach), "ATTACH DATABASE '%s' AS plaintext KEY '';", out);
    if (sqlite3_exec(db, attach, 0, 0, 0) != SQLITE_OK) return fail(db, "attach out");
    if (sqlite3_exec(db, "SELECT sqlcipher_export('plaintext');", 0, 0, 0) != SQLITE_OK) return fail(db, "export");
    if (sqlite3_exec(db, "DETACH DATABASE plaintext;", 0, 0, 0) != SQLITE_OK) return fail(db, "detach");

    sqlite3_close(db);
    return 0;
}
