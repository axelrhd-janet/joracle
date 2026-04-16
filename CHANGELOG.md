# Changelog
All notable changes to this project will be documented in this file.
Format for entries is <version-string> - release date.

## 0.1.0 - 2026-04-16
- Initial Go + go-ora implementation (pivoted from Rust + oracle-rs 0.1.7
  after protocol-parser incompatibilities on the target Oracle instance).
- C ABI: connect, disconnect, query, exec, begin, commit, rollback, build-dsn,
  free. All JSON-in/JSON-out.
- Janet wrapper via `ffi/defbind-alias` with kebab-case public API.
- Transactions route through `*sql.Tx` while open.
- NUMBER arbitrary-precision preserved as string (ERP zero-padding intact).

## 0.0.0 - 2026-04-16
- Created this project.
