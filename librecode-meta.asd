;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; librecode-meta.asd — ASDF system definition for librecode-meta
;;;

(asdf:defsystem #:librecode-meta
  :description "OpenCode multi-agent campaign coordinator metaharness."
  :author "nrd"
  :license "MIT"
  :depends-on (#:librecode-runner)
  :serial t
  :components
  ((:module "src"
    :components
    ((:module "meta"
      :components
      ((:file "multiplexer")
       (:file "multiplexer-tmux")
       (:file "harness")
       (:file "harness-subprocess")
       (:file "harness-opencode")
       (:file "harness-librecode")
       (:file "journal")
       (:file "campaign")
       (:file "gate")
       (:file "council")
       (:file "conditioning")
       (:file "metaharness")))))))
