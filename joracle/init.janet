(import json)

(defn- dirname [path]
  (def parts (string/split "/" path))
  (if (<= (length parts) 1) "." (string/join (array/slice parts 0 -2) "/")))

(defn- find-lib []
  (def here (or (dyn :current-file) ""))
  (def candidates
    [(string (dirname here) "/libjoracle.so")   # installed alongside init.janet
     "./libjoracle.so"                           # dev: project root as cwd
     "../libjoracle.so"
     "libjoracle.so"])
  (or (find |(os/stat $) candidates)
      (error "libjoracle.so not found — run `just build` from the project root")))

(ffi/context (find-lib))

(ffi/defbind-alias joracle_build_dsn  raw-build-dsn  :ptr  [opts :string])
(ffi/defbind-alias joracle_free       raw-free       :void [p :ptr])
(ffi/defbind-alias joracle_connect    raw-connect    :ptr  [opts :string])
(ffi/defbind-alias joracle_disconnect raw-disconnect :ptr  [id :s64])
(ffi/defbind-alias joracle_query      raw-query      :ptr  [id :s64 sql :string params :string])
(ffi/defbind-alias joracle_exec       raw-exec       :ptr  [id :s64 sql :string params :string])
(ffi/defbind-alias joracle_begin      raw-begin      :ptr  [id :s64])
(ffi/defbind-alias joracle_commit     raw-commit     :ptr  [id :s64])
(ffi/defbind-alias joracle_rollback   raw-rollback   :ptr  [id :s64])

(defn- encode [x] (string (json/encode x)))

(defn- read-and-free [ptr]
  (when (= ptr nil) (error "FFI call returned null pointer"))
  (def s (ffi/read :string (ffi/write :ptr ptr)))
  (raw-free ptr)
  s)

(defn- unwrap [ptr]
  (def decoded (json/decode (read-and-free ptr)))
  (if-let [msg (get decoded "error")]
    (error msg)
    (get decoded "ok")))

(defn build-dsn
  ``Builds a go-ora-style DSN URL from connection parameters.

  Note: this URL is for storage/display/logging — oracle-rs itself expects
  the EZConnect format (host:port/service) and separate user/password args,
  which `connect` builds internally. Think of `build-dsn` as a pretty-print
  helper, not something to pass back to `connect`.


  opts (table|struct) — required keys:
    :host     string  Oracle server hostname or IP
    :port     number  TCP port (typically 1521)
    :service  string  Oracle service name (e.g. "XEPDB1")
    :user     string  database username
    :password string  database password

  opts — optional:
    :options  table   extra URL parameters, all values must be strings.
                      Recognized keys (analogous to go-ora's BuildUrl):
                        :SSL_VERIFY       "TRUE" | "FALSE"  — verify TLS cert
                        :WALLET           path to Oracle Wallet directory
                        :CONNECT_TIMEOUT  seconds as string, e.g. "30"
                        :TRACE_FILE       path for debug trace output

  Returns the DSN string, e.g. "oracle://user:pass@host:1521/svc?SSL_VERIFY=TRUE".
  User, password, and service are URL-encoded automatically.``
  [opts]
  (unwrap (raw-build-dsn (encode opts))))

(defn connect
  ``Opens an Oracle connection.

  opts has the same shape as `build-dsn` accepts — see its docstring for the
  full list of required and optional keys.

  Returns a connection record {:driver :oracle :handle <i64>}. Pass this record
  to every other joracle function (query, exec, disconnect, begin, commit,
  rollback). The :handle is an opaque id into Rust-side state; do not mutate
  it, do not share across processes.

  Raises on connection failure (bad credentials, unreachable host, TLS
  mismatch, etc.) with the Rust-side error message as the condition.``
  [opts]
  (def id (unwrap (raw-connect (encode opts))))
  {:driver :oracle :handle id})

(defn disconnect
  ``Closes the Oracle connection and releases the handle.

  conn — connection record returned by `connect`.

  Returns true on success. Calling twice on the same conn raises an
  "invalid handle" error — this is intentional, not idempotent.``
  [conn]
  (unwrap (raw-disconnect (conn :handle))))

(defn query
  ``Executes a SELECT and returns all rows as an array of tables.

  conn   — connection record from `connect`
  sql    — SQL string with positional bind placeholders :1, :2, ...
  params — array/tuple of values to bind, in placeholder order.

  Janet → Oracle type mapping (for bind params):
    nil     → NULL
    boolean → BOOLEAN
    integer → NUMBER (i64 range)
    float   → BINARY_DOUBLE
    string  → VARCHAR2 / CLOB
    other   → JSON-stringified (fallback)

  Returns an array of tables. Keys are Oracle column names as STRINGS
  (usually uppercase unless the SQL quoted them). Values follow this
  oracle-rs Value → Janet mapping:

    NULL                       → nil
    VARCHAR2 / CHAR / CLOB     → string
    RAW / BLOB                 → base64-encoded string
    NUMBER (i64 range)         → integer
    NUMBER (float / BIN_FLOAT  → float
            / BIN_DOUBLE)
    NUMBER (full precision)    → string (debug repr — TODO: switch to Display)
    DATE / TIMESTAMP           → string (debug repr — TODO: ISO 8601)
    BOOLEAN                    → boolean
    JSON (21c+)                → decoded Janet value
    LOB / VECTOR / CURSOR /    → table with :_type and :_note placeholders
      COLLECTION                  (streaming/extraction not yet implemented)

  Raises on SQL errors, missing binds, or type mismatches.``
  [conn sql params]
  (unwrap (raw-query (conn :handle) sql (encode params))))

(defn exec
  ``Executes a DML statement (INSERT / UPDATE / DELETE / MERGE) or DDL.

  conn, sql, params — same as `query`.

  Returns a table {"rows_affected" n} where n is the number of rows
  modified (integer). For DDL statements n is 0.

  Does NOT commit — wrap in begin/commit or rely on auto-commit at
  connection close if your driver layer enables it.``
  [conn sql params]
  (unwrap (raw-exec (conn :handle) sql (encode params))))

(defn begin
  ``No-op kept for API parity with the jsql driver protocol.

  Oracle uses implicit transactions: a new transaction starts automatically
  on the first DML after a commit/rollback, so there is nothing to do here.
  Always returns true.``
  [conn]
  (unwrap (raw-begin (conn :handle))))

(defn commit
  "Commits the current transaction on this connection. Returns true."
  [conn]
  (unwrap (raw-commit (conn :handle))))

(defn rollback
  "Rolls back the current transaction on this connection. Returns true."
  [conn]
  (unwrap (raw-rollback (conn :handle))))

(def driver
  ``Driver protocol map — stable ABI consumed by jsql. Pass to jsql once it
  exists:

    (import joracle)
    (import jsql)
    (jsql/register-driver :oracle joracle/driver)

  Output shapes (connect → record, query → array of string-keyed tables,
  exec → {"rows_affected" n}, etc.) are load-bearing for jsql and must not
  change without a coordinated jsql update — see todo.md "Driver Output
  Contract".``
  {:connect    connect
   :disconnect disconnect
   :query      query
   :exec       exec
   :begin      begin
   :commit     commit
   :rollback   rollback
   :build-dsn  build-dsn})
