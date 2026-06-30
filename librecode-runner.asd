;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; librecode-runner.asd — ASDF system definition for librecode-runner
;;;

(asdf:defsystem #:librecode-runner
  :description "OpenCode coordination protocol runner."
  :author "nrd"
  :license "MIT"
  :depends-on (#:sqlite
               #:bordeaux-threads
               #:com.inuoe.jzon
               #:dexador
               #:trivial-signal
               #:cl-jschema
               #:clack
               #:hunchentoot
               #:clack-handler-hunchentoot)
  :serial t
  :components
  ((:module "src"
    :components
    ((:file "packages")
     (:module "runner"
      :components
      ((:file "conditions")
       (:file "protocol")
       (:file "event-store")
       (:file "agent")
       (:file "session")
       (:file "tool")
       (:file "runner")
       (:file "compaction")
       (:file "audit")
       (:file "http")))))))
