# joracle

Oracle database driver for Janet. Native C module wrapping a Go shared
library that uses `go-ora` — a pure Go Oracle driver implementing the TNS
protocol directly. No Oracle Instant Client required.

**joracle is a driver for `jsql`. It cannot be used standalone.**

---

## History

Initially specced around Rust + `oracle-rs` 0.1.7. oracle-rs is a solo
project (~30 commits, 15 stars) and its TNS protocol parser choked on
basic query responses (`SELECT 1 FROM DUAL` → "buffer underflow: need 1
bytes but only 0 available") against a live Oracle 12.1+ instance.
Connect worked; parsing any response did not.

Pivoted to Go + `go-ora` (`github.com/sijms/go-ora/v2`, >2M downloads,
actively maintained by Oracle-employee Sijms). Same Oracle database
answered `SELECT 1 FROM DUAL` on the first try after the switch.

The C ABI surface between Janet and the shared library stayed identical —
only the implementation language behind `libjoracle.so` changed.

---

## Status

**Works:**
- Connect / disconnect (`database/sql` pool per handle, `db.Ping()` on open)
- Query with positional binds (`:1`, `:2`) — verified against live EVA DB
- Exec returning `rows_affected`
- Transactions (begin / commit / rollback) route queries through `*sql.Tx`
  while active
- DSN builder via `go-ora.BuildUrl` (URL-encodes, accepts options map)
- URL roundtrip tests (basic / encoded / options)
- NUMBER precision preserved as strings (ERP zero-padding intact)

**Outstanding:**
- Live transaction roundtrip (begin → exec → commit/rollback on real table)
- DATE / TIMESTAMP return format verification (RFC3339 expected)
- TLS / Wallet connection options (passed through but not tested)
- LOB streaming for very large values
- REF CURSOR / Collection / Vector output types
- Named binds (`:name` → `{:name val}`) — lives at jsql layer, not here

---

## Interdependencies

```
your-app.janet
    └── jsql                    ← generic interface (required)
        └── joracle             ← this library (Janet + native module)
            └── libjoracle.so   ← Go shared library (cgo-exported)
                └── go-ora      ← pure Go TNS implementation
                    └── Oracle Database (12.1+)
```

Once jsql exists, the intended wiring:

```janet
(import joracle)
(import jsql)
(jsql/register-driver :oracle joracle/driver)
```

joracle does NOT try to `require "jsql"` on import — keeps `(import joracle)`
silent when jsql is absent.

### Why Go?

Janet has a GC; so does Go. The two heaps are kept disjoint:

- Go owns all `*sql.DB` / `*sql.Tx` values and stores them in a Go-side
  `map[int64]*connEntry` guarded by `sync.Mutex`.
- Janet only holds opaque `int64` handles (keys into that map).
- No Go pointers ever cross the FFI boundary.
- Return strings are allocated via `C.CString` (malloc, not Go heap) and
  freed by Janet via `joracle_free`.
- Input strings via `C.GoString` are copied into Go memory, so the Janet
  bytes stay owned by Janet's GC.

---

## Driver Output Contract (stable ABI for jsql)

Do not change without coordinated jsql update. jsql relies on these shapes.

| Function                  | Return                                               |
|---------------------------|------------------------------------------------------|
| `(connect opts)`          | `{:driver :oracle :handle <i64>}`                    |
| `(disconnect conn)`       | `true`                                               |
| `(query conn sql params)` | `@[@{"COLNAME" value ...} ...]` — mutable array of mutable tables, string keys, JSON-primitive values |
| `(exec conn sql params)`  | `@{"rows_affected" <integer>}`                       |
| `(begin conn)`            | `true` (opens `*sql.Tx`, routes following query/exec through it) |
| `(commit conn)`           | `true`                                               |
| `(rollback conn)`         | `true`                                               |
| `(build-dsn opts)`        | go-ora URL string (`oracle://...`)                   |

Values inside a row are limited to: string, number, boolean, nil,
base64-string (for BLOB/RAW), RFC3339-string (for DATE/TIMESTAMP).
No Janet-specific types leak through — safe for jsql to reshape.

Errors raise Janet conditions carrying the Go-side error message.

---

## Project Structure

```
joracle/
├── project.janet
├── joracle/init.janet      ← Janet wrapper + FFI bindings
├── joracle.go              ← cgo-exported Go shared library source
├── go.mod / go.sum         ← Go dependencies (go-ora)
├── justfile                ← build / test / install recipes
├── libjoracle.so           ← built artifact
├── libjoracle.h            ← cgo-generated header (not used by Janet)
├── test/basic.janet        ← jpm test: build-dsn roundtrip
└── examples/live.janet     ← manual live-DB test (ORA_* env vars)
```

---

## Go Layer

C-ABI exports (via cgo `//export` directives, all JSON-in, JSON-out):

```go
joracle_build_dsn(opts_json *C.char) *C.char
joracle_free(p *C.char)
joracle_connect(opts_json *C.char) *C.char              // → {"ok": <id>}
joracle_disconnect(id C.longlong) *C.char
joracle_query(id, sql, params *C.char) *C.char          // → {"ok": [rows]}
joracle_exec(id, sql, params *C.char) *C.char           // → {"ok": {"rows_affected": n}}
joracle_begin / joracle_commit / joracle_rollback(id C.longlong) *C.char
```

Every non-`free` export returns `{"ok": ...}` or `{"error": "..."}`.

### Build

```
just build      # go build -buildmode=c-shared -o libjoracle.so .
just test       # build + jpm test
just deps       # go mod tidy
```

---

## Type Mapping (Oracle → go-ora → JSON → Janet)

| Oracle Type              | go-ora                    | JSON       | Janet    |
|--------------------------|---------------------------|------------|----------|
| VARCHAR2 / CHAR / CLOB   | string                    | string     | string   |
| NUMBER (integer, small)  | int64 / string            | number/str | same     |
| NUMBER (float)           | float64                   | number     | number   |
| NUMBER (arbitrary prec.) | string (preserved)        | string     | string   |
| DATE / TIMESTAMP         | time.Time                 | RFC3339    | string   |
| TIMESTAMP WITH TZ        | time.Time                 | RFC3339    | string   |
| BLOB / RAW               | []byte → base64           | string     | string   |
| BOOLEAN (23c+)           | bool                      | boolean    | boolean  |
| NULL                     | nil                       | null       | nil      |
| JSON (21c+)              | driver-dependent          | pass-thru  | same     |

For NUMBER without explicit scale, go-ora keeps the textual form.
ERP zero-padded identifiers (e.g. `"0271931906"`) survive roundtrips intact.
Type coercion to int/float belongs in jsql, not joracle.

---

## Connection Options

Passed as a Janet table to `connect` (and `build-dsn`):

| Key        | Type   | Required | Description                           |
|------------|--------|----------|---------------------------------------|
| `:host`    | string | yes      | Oracle host                           |
| `:port`    | number | yes      | Port (typically 1521)                 |
| `:service` | string | yes      | Oracle service name                   |
| `:user`    | string | yes      | Username                              |
| `:password`| string | yes      | Password                              |
| `:options` | table  | no       | Extra URL params, passed through to go-ora `BuildUrl` |

Recognized `:options` (string→string, go-ora-specific):
- `:SSL` / `:SSL_VERIFY` — `"TRUE"` / `"FALSE"`
- `:WALLET` — path to Oracle Wallet directory
- `:TIMEOUT` / `:CONNECT_TIMEOUT` — seconds
- `:TRACE_FILE` — path for TNS trace

See go-ora docs for the complete list; values pass through verbatim.

---

## Requirements

**Build-time:**
- Go toolchain ≥ 1.22 (current: 1.26.1)
- cgo compiler (gcc on Linux)
- Janet ≥ 1.41, jpm

**Runtime:**
- `libjoracle.so` on Janet module lookup path (~23 MB, bundles Go runtime)
- Nothing else — no Instant Client, no Go runtime, no external libs
