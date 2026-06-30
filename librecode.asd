;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; librecode.asd — ASDF system definition for librecode
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
               #:hunchentoot)
  :serial t
  :components
   ((:file "src/packages")
    (:file "src/runner/conditions")
    (:file "src/runner/protocol")
    (:file "src/runner/event-store")
    (:file "src/runner/agent")
    (:file "src/runner/session")
    (:file "src/runner/tool")
    (:file "src/runner/runner")
    (:file "src/runner/compaction")
    (:file "src/runner/audit")))

(asdf:defsystem #:librecode-meta
  :description "OpenCode multi-agent campaign coordinator metaharness."
  :author "nrd"
  :license "MIT"
  :depends-on (#:librecode-runner)
  :serial t
  :components
  ((:file "src/meta/multiplexer")
   (:file "src/meta/multiplexer-tmux")
   (:file "src/meta/harness")
   (:file "src/meta/harness-opencode")
   (:file "src/meta/harness-librecode")
   (:file "src/meta/campaign")
   (:file "src/meta/gate")
   (:file "src/meta/council")
   (:file "src/meta/conditioning")
   (:file "src/meta/metaharness")))
