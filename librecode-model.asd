;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; librecode-model.asd — ASDF system definition for librecode-model
;;;
;;; Pure applicative reference model of the metaharness's core state machine
;;; (roadmap workstream A). Dependency-free by design: it is a specification,
;;; not the runtime, and must never acquire a dependency on librecode-runner or
;;; librecode-meta (see docs/model.md, "the conformance seam").
;;;

(asdf:defsystem #:librecode-model
  :description "Pure applicative reference model of the metaharness state machine."
  :author "nrd"
  :license "MIT"
  :serial t
  :components
  ((:module "src"
    :components
    ((:module "model"
      :components
      ((:file "packages")
       (:file "dag")
       (:file "state-machine")
       (:file "invariants")))))))
