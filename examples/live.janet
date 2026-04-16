(import ../joracle/init :as joracle)
# Not a jpm test — run manually with ORA_* env vars set:
#   janet examples/live.janet

(defn- env-or-die [name]
  (or (os/getenv name)
      (error (string name " not set — export ORA_HOST ORA_PORT ORA_SERVICE ORA_USER ORA_PASS"))))

(def opts
  {:host     (env-or-die "ORA_HOST")
   :port     (scan-number (env-or-die "ORA_PORT"))
   :service  (env-or-die "ORA_SERVICE")
   :user     (env-or-die "ORA_USER")
   :password (env-or-die "ORA_PASS")})

(printf "connecting to %s:%d/%s as %s ..." (opts :host) (opts :port) (opts :service) (opts :user))
(def conn (joracle/connect opts))
(printf " ok (handle=%d)" (conn :handle))

(print "\n-- SELECT 1 FROM DUAL")
(pp (joracle/query conn "SELECT 1 AS one FROM DUAL" []))

(print "\n-- SELECT with bind param (:1)")
(pp (joracle/query conn "SELECT :1 AS echoed FROM DUAL" [42]))

(print "\n-- SELECT SYSDATE")
(pp (joracle/query conn "SELECT SYSDATE AS now FROM DUAL" []))

(print "\n-- SELECT multi-column / multi-type")
(pp (joracle/query conn
  "SELECT 'hello' AS s, 3.14 AS f, 1 AS i, NULL AS n FROM DUAL" []))

(print "\ndisconnecting ...")
(joracle/disconnect conn)
(print "done")
