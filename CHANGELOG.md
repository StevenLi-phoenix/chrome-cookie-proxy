# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-10-29

### Added

- `chrome-cookie-proxy serve [--socket <path>] [--chrome-root <dir>] [--profile <name>]`: a local service that
  hands out Chrome cookies as a Netscape `cookies.txt` over a unix socket, so Full Disk Access and the
  "Chrome Safe Storage" keychain grant can live in one small signed binary instead of a Python interpreter.
- Socket hardening: the socket directory is created `0700` and must belong to the current user, the socket is
  `0600`, every connection's peer uid is checked with `getpeereid`, requests are capped at 8 KB and 5 seconds.
- Routes `GET /healthz` and `GET /v1/cookies/<set>`; the only compiled-in set is `youtube`
  (`youtube.com`, `google.com` and their subdomains).
- Chrome reader: picks the newest of `Default` and `Profile *` (like yt-dlp), reads `Network/Cookies` or
  `Cookies`, works on a private copy of the database including `-wal` and `-journal`, decrypts `v10` values
  (PBKDF2-SHA1 + AES-128-CBC) and verifies and strips the SHA256(host_key) prefix for schema version 24 and later.
- Errors are returned as a short code only (`keychain_denied`, `cookies_db_unreadable`, `no_profile`,
  `internal_error`); logs carry counts and the profile name, never cookie names, values or the keychain secret.
- launchd example in `deploy/`, README with the security model, and a test suite (vectors computed independently
  with Python `hashlib` and the `openssl` CLI, a fake Chrome root built through the SQLite C API, and
  socket end-to-end tests).
