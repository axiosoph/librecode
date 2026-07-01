;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; packages.lisp — Namespace layout for the librecode-model reference model
;;;

(in-package :cl-user)

(defpackage #:librecode-model
  (:use #:cl)
  (:documentation
   "Pure applicative reference model of the metaharness's core state machine
(work DAG, phases, deposits, gates, event log). Every transition is a total
function: state in, state out, illegal inputs returning an explicit rejection
value rather than signaling. This is the conformance-testable definition of
\"what correct means\" — not the runtime (the threaded CLOS harness in
src/runner and src/meta), which will later be replayed against it.")
  (:export
   ;; dag.lisp
   #:dag
   #:dag-p
   #:dag-node-specs
   #:make-dag
   #:dag-node
   #:make-dag-node
   #:dag-node-p
   #:dag-node-id
   #:dag-node-dependencies
   #:find-dag-node
   #:dag-node-ids
   #:dag-layers

   ;; state-machine.lisp
   #:deposit
   #:deposit-p
   #:deposit-validation-state
   #:deposit-gate-mode
   #:deposit-phase
   #:node-state
   #:node-state-p
   #:node-state-id
   #:node-state-status
   #:node-state-phase
   #:node-state-deposit
   #:model-state
   #:model-state-p
   #:model-state-dag
   #:model-state-node-states
   #:model-state-events
   #:initial-state
   #:find-node-state
   #:rejected-p
   #:rejection-reason
   #:dispatch
   #:land
   #:gate-check
   #:quarantine
   #:discharge
   #:skip
   #:escalate
   #:transition-event
   #:replay

   ;; invariants.lisp
   #:phase-monotonic-p
   #:no-pending-proven-p
   #:tamper-evident-p
   #:dag-preserved-p
   #:schedule-correct-p))
