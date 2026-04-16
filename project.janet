(declare-project
  :name "joracle"
  :description "Oracle driver for jsql (Go-backed via go-ora, pure TNS, no Instant Client)"
  :version "0.1.0"
  :license "MIT"
  :author "AxelRHD"
  :url "https://github.com/axelrhd-janet/joracle"
  :repo "git+https://github.com/axelrhd-janet/joracle")
  # TODO re-enable once jsql is published:
  # :dependencies [{:repo "https://github.com/axelrhd-janet/jsql"}])

(declare-source
  :prefix "joracle"
  :source ["joracle/init.janet" "libjoracle.so"])
