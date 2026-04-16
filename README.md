# joracle

Oracle database driver for Janet, backed by a Go shared library that wraps
[`go-ora`](https://github.com/sijms/go-ora) — a pure-Go Oracle TNS driver.
**No Oracle Instant Client required**; the `.so` bundles everything.

joracle is a driver for `jsql` (the generic Janet SQL interface); it is not
meant to be used standalone in application code.

## Build

```
just build
```

Produces `libjoracle.so` via `go build -buildmode=c-shared`.

## Quickstart

```janet
(import joracle)

(def conn (joracle/connect
  {:host "10.49.84.102" :port 1521 :service "EVA"
   :user "scott" :password "tiger"}))

(defer (joracle/disconnect conn)
  (pp (joracle/query conn
        "SELECT LIEFERNR, SENDUNGSNR FROM V05AW FETCH NEXT 5 ROWS ONLY"
        [])))
```

In production you register joracle with jsql and use jsql's API:

```janet
(import joracle)
(import jsql)
(jsql/register-driver :oracle joracle/driver)
```

See `todo.md` for the full spec, driver output contract, and status.

## Test

```
just test       # build + jpm test (build-dsn roundtrip)
```

Live DB test (requires `ORA_HOST`, `ORA_PORT`, `ORA_SERVICE`, `ORA_USER`,
`ORA_PASS` in the environment):

```
janet examples/live.janet
```
