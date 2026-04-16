package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	go_ora "github.com/sijms/go-ora/v2"
)

// Janet holds only opaque int64 handles. Go owns every *sql.DB / *sql.Tx and
// keeps them alive in `connections` so the Go GC never reclaims them behind
// Janet's back. Strings returned to Janet are allocated with C.CString (malloc
// arena, not Go heap) and freed by Janet via joracle_free.

type connEntry struct {
	db *sql.DB
	tx *sql.Tx // nil when no explicit transaction is active
}

var (
	connections = make(map[int64]*connEntry)
	connMu      sync.Mutex
	nextID      int64
)

func toC(s string) *C.char {
	return C.CString(s)
}

func okJSON(v interface{}) *C.char {
	b, err := json.Marshal(map[string]interface{}{"ok": v})
	if err != nil {
		return errJSON(fmt.Sprintf("marshal ok: %v", err))
	}
	return toC(string(b))
}

func errJSON(msg string) *C.char {
	b, _ := json.Marshal(map[string]string{"error": msg})
	return toC(string(b))
}

func wrap(f func() (interface{}, error)) *C.char {
	v, err := f()
	if err != nil {
		return errJSON(err.Error())
	}
	return okJSON(v)
}

func decodeJSON(s string, into interface{}) error {
	dec := json.NewDecoder(strings.NewReader(s))
	dec.UseNumber()
	return dec.Decode(into)
}

// normalizeParam converts json.Number to int64 (no decimal) or float64 so
// go-ora's bind code sees numeric Go types, not strings.
func normalizeParam(v interface{}) interface{} {
	if n, ok := v.(json.Number); ok {
		if strings.ContainsAny(n.String(), ".eE") {
			if f, err := n.Float64(); err == nil {
				return f
			}
		}
		if i, err := n.Int64(); err == nil {
			return i
		}
		if f, err := n.Float64(); err == nil {
			return f
		}
		return n.String()
	}
	return v
}

func extractStr(m map[string]interface{}, key string) (string, error) {
	v, ok := m[key]
	if !ok {
		return "", fmt.Errorf("missing field: %s", key)
	}
	s, ok := v.(string)
	if !ok {
		return "", fmt.Errorf("field %s must be a string, got %T", key, v)
	}
	return s, nil
}

func extractPort(m map[string]interface{}) (int, error) {
	v, ok := m["port"]
	if !ok {
		return 0, fmt.Errorf("missing field: port")
	}
	switch x := v.(type) {
	case json.Number:
		i, err := x.Int64()
		if err != nil {
			return 0, fmt.Errorf("port: %w", err)
		}
		return int(i), nil
	case float64:
		return int(x), nil
	default:
		return 0, fmt.Errorf("port must be a number, got %T", v)
	}
}

func extractOptions(m map[string]interface{}) map[string]string {
	out := map[string]string{}
	raw, ok := m["options"].(map[string]interface{})
	if !ok {
		return out
	}
	for k, v := range raw {
		if s, ok := v.(string); ok {
			out[k] = s
		}
	}
	return out
}

//export joracle_free
func joracle_free(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}

//export joracle_build_dsn
func joracle_build_dsn(optsJSON *C.char) *C.char {
	return wrap(func() (interface{}, error) {
		var opts map[string]interface{}
		if err := decodeJSON(C.GoString(optsJSON), &opts); err != nil {
			return nil, fmt.Errorf("json: %w", err)
		}
		host, err := extractStr(opts, "host")
		if err != nil {
			return nil, err
		}
		port, err := extractPort(opts)
		if err != nil {
			return nil, err
		}
		service, err := extractStr(opts, "service")
		if err != nil {
			return nil, err
		}
		user, err := extractStr(opts, "user")
		if err != nil {
			return nil, err
		}
		password, err := extractStr(opts, "password")
		if err != nil {
			return nil, err
		}
		return go_ora.BuildUrl(host, port, service, user, password, extractOptions(opts)), nil
	})
}

//export joracle_connect
func joracle_connect(optsJSON *C.char) *C.char {
	return wrap(func() (interface{}, error) {
		var opts map[string]interface{}
		if err := decodeJSON(C.GoString(optsJSON), &opts); err != nil {
			return nil, fmt.Errorf("json: %w", err)
		}
		host, err := extractStr(opts, "host")
		if err != nil {
			return nil, err
		}
		port, err := extractPort(opts)
		if err != nil {
			return nil, err
		}
		service, err := extractStr(opts, "service")
		if err != nil {
			return nil, err
		}
		user, err := extractStr(opts, "user")
		if err != nil {
			return nil, err
		}
		password, err := extractStr(opts, "password")
		if err != nil {
			return nil, err
		}
		url := go_ora.BuildUrl(host, port, service, user, password, extractOptions(opts))
		db, err := sql.Open("oracle", url)
		if err != nil {
			return nil, fmt.Errorf("sql.Open: %w", err)
		}
		if err := db.Ping(); err != nil {
			_ = db.Close()
			return nil, fmt.Errorf("ping: %w", err)
		}
		id := atomic.AddInt64(&nextID, 1)
		connMu.Lock()
		connections[id] = &connEntry{db: db}
		connMu.Unlock()
		return id, nil
	})
}

func takeConn(id int64) (*connEntry, error) {
	connMu.Lock()
	defer connMu.Unlock()
	e, ok := connections[id]
	if !ok {
		return nil, fmt.Errorf("invalid handle: %d", id)
	}
	return e, nil
}

//export joracle_disconnect
func joracle_disconnect(id C.longlong) *C.char {
	return wrap(func() (interface{}, error) {
		connMu.Lock()
		e, ok := connections[int64(id)]
		if !ok {
			connMu.Unlock()
			return nil, fmt.Errorf("invalid handle: %d", id)
		}
		delete(connections, int64(id))
		connMu.Unlock()

		if e.tx != nil {
			_ = e.tx.Rollback()
		}
		if err := e.db.Close(); err != nil {
			return nil, fmt.Errorf("close: %w", err)
		}
		return true, nil
	})
}

// valueToJSON converts a database/sql scanned value into something JSON can
// represent without losing information for the common Oracle types.
func valueToJSON(v interface{}) interface{} {
	switch x := v.(type) {
	case nil:
		return nil
	case []byte:
		return base64.StdEncoding.EncodeToString(x)
	case time.Time:
		return x.Format(time.RFC3339Nano)
	default:
		return x
	}
}

//export joracle_query
func joracle_query(id C.longlong, sqlPtr, paramsPtr *C.char) *C.char {
	return wrap(func() (interface{}, error) {
		entry, err := takeConn(int64(id))
		if err != nil {
			return nil, err
		}
		var params []interface{}
		if err := decodeJSON(C.GoString(paramsPtr), &params); err != nil {
			return nil, fmt.Errorf("params: %w", err)
		}
		for i := range params {
			params[i] = normalizeParam(params[i])
		}

		sqlText := C.GoString(sqlPtr)
		var rows *sql.Rows
		if entry.tx != nil {
			rows, err = entry.tx.Query(sqlText, params...)
		} else {
			rows, err = entry.db.Query(sqlText, params...)
		}
		if err != nil {
			return nil, fmt.Errorf("query: %w", err)
		}
		defer rows.Close()

		cols, err := rows.Columns()
		if err != nil {
			return nil, fmt.Errorf("columns: %w", err)
		}

		result := []map[string]interface{}{}
		for rows.Next() {
			vals := make([]interface{}, len(cols))
			ptrs := make([]interface{}, len(cols))
			for i := range vals {
				ptrs[i] = &vals[i]
			}
			if err := rows.Scan(ptrs...); err != nil {
				return nil, fmt.Errorf("scan: %w", err)
			}
			row := make(map[string]interface{}, len(cols))
			for i, c := range cols {
				row[c] = valueToJSON(vals[i])
			}
			result = append(result, row)
		}
		if err := rows.Err(); err != nil {
			return nil, fmt.Errorf("rows: %w", err)
		}
		return result, nil
	})
}

//export joracle_exec
func joracle_exec(id C.longlong, sqlPtr, paramsPtr *C.char) *C.char {
	return wrap(func() (interface{}, error) {
		entry, err := takeConn(int64(id))
		if err != nil {
			return nil, err
		}
		var params []interface{}
		if err := decodeJSON(C.GoString(paramsPtr), &params); err != nil {
			return nil, fmt.Errorf("params: %w", err)
		}
		for i := range params {
			params[i] = normalizeParam(params[i])
		}

		sqlText := C.GoString(sqlPtr)
		var res sql.Result
		if entry.tx != nil {
			res, err = entry.tx.Exec(sqlText, params...)
		} else {
			res, err = entry.db.Exec(sqlText, params...)
		}
		if err != nil {
			return nil, fmt.Errorf("exec: %w", err)
		}
		n, _ := res.RowsAffected()
		return map[string]interface{}{"rows_affected": n}, nil
	})
}

//export joracle_begin
func joracle_begin(id C.longlong) *C.char {
	return wrap(func() (interface{}, error) {
		entry, err := takeConn(int64(id))
		if err != nil {
			return nil, err
		}
		connMu.Lock()
		defer connMu.Unlock()
		if entry.tx != nil {
			return nil, fmt.Errorf("transaction already in progress on handle %d", id)
		}
		tx, err := entry.db.Begin()
		if err != nil {
			return nil, fmt.Errorf("begin: %w", err)
		}
		entry.tx = tx
		return true, nil
	})
}

//export joracle_commit
func joracle_commit(id C.longlong) *C.char {
	return wrap(func() (interface{}, error) {
		entry, err := takeConn(int64(id))
		if err != nil {
			return nil, err
		}
		connMu.Lock()
		defer connMu.Unlock()
		if entry.tx == nil {
			return nil, fmt.Errorf("no transaction to commit on handle %d", id)
		}
		err = entry.tx.Commit()
		entry.tx = nil
		if err != nil {
			return nil, fmt.Errorf("commit: %w", err)
		}
		return true, nil
	})
}

//export joracle_rollback
func joracle_rollback(id C.longlong) *C.char {
	return wrap(func() (interface{}, error) {
		entry, err := takeConn(int64(id))
		if err != nil {
			return nil, err
		}
		connMu.Lock()
		defer connMu.Unlock()
		if entry.tx == nil {
			return nil, fmt.Errorf("no transaction to rollback on handle %d", id)
		}
		err = entry.tx.Rollback()
		entry.tx = nil
		if err != nil {
			return nil, fmt.Errorf("rollback: %w", err)
		}
		return true, nil
	})
}

func main() {}
