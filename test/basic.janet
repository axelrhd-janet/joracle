(import ../joracle/init :as joracle)

# build-dsn delegates to go-ora's BuildUrl. These tests pin the observable
# output so we notice if the upstream format changes between go-ora versions.

(def dsn-basic
  (joracle/build-dsn
    {:host "db.example.com" :port 1521 :service "XEPDB1"
     :user "scott" :password "tiger"}))

(assert (string/has-prefix? "oracle://scott:tiger@db.example.com:1521/XEPDB1" dsn-basic)
        (string "basic dsn prefix mismatch: " dsn-basic))

(def dsn-encoded
  (joracle/build-dsn
    {:host "h" :port 1521 :service "s" :user "u" :password "p ss"}))

(assert (string/find "p%20ss@h:" dsn-encoded)
        (string "password space encoding failed: " dsn-encoded))

(def dsn-opts
  (joracle/build-dsn
    {:host "h" :port 1521 :service "s" :user "u" :password "p"
     :options {:SSL_VERIFY "TRUE" :CONNECT_TIMEOUT "30"}}))

(assert (and (string/find "SSL_VERIFY=TRUE" dsn-opts)
             (string/find "CONNECT_TIMEOUT=30" dsn-opts))
        (string "options serialization failed: " dsn-opts))

(print "joracle: build-dsn tests passed")
