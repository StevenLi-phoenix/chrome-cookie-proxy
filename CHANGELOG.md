# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0] - 2026-11-01

### Added

- `serve --allow-uid <uid>` (repeatable) lets more than the service's own uid connect: the allowed peer uid is now a set (the
  service's own uid is always in it). A rejected connection is logged with the offending uid and, when the set has more than one
  member, the allowed uids.
- `serve --socket-mode <octal>` sets the socket file's mode (default `0600`; up to `0777`, owner must keep read/write) so another
  user can `connect()` when the socket directory's ACL admits them.
- The startup log line lists `allowed_uids` and `socket_mode`.

### Unchanged

- Without the new options behavior is identical to 0.1.2: only the service's own uid is accepted, the socket is `0600`, a single-uid
  rejection logs the same line as before.

## [0.1.2] - 2026-10-29

### Added

- `chrome-cookie-proxy version` prints the version, so the deployed build can be checked over ssh.

## [0.1.1] - 2026-10-29

### Fixed

- A Chrome root that exists but cannot be opened (Full Disk Access missing or revoked, `EPERM`/`EACCES`) now
  answers `chrome_root_unreadable` instead of `no_profile`, so a revoked grant is not mistaken for a missing
  Chrome profile.

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
