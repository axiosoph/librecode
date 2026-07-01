;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; campaign-tests.lisp — Unit tests for campaign DAG scheduling
;;;

(defpackage #:librecode-test.campaign
  (:use #:cl #:fiveam)
  (:import-from #:librecode-meta.campaign
                #:campaign-node
                #:make-campaign-node
                #:campaign-node-id
                #:campaign-dag
                #:make-campaign-dag
                #:campaign-dag-nodes
                #:campaign-dag-layers
                #:compute-kahn-layers)
  (:export #:campaign-suite))
(in-package #:librecode-test.campaign)

(def-suite campaign-suite :description "Test campaign scheduling and DAG")
(in-suite campaign-suite)

(test test-kahn-linear
  (let* ((n1 (make-campaign-node :id "A" :dependencies nil))
         (n2 (make-campaign-node :id "B" :dependencies '("A")))
         (n3 (make-campaign-node :id "C" :dependencies '("B")))
         (layers (compute-kahn-layers (list n1 n2 n3))))
    (is (= 3 (length layers)))
    (is (equal '("A") (aref layers 0)))
    (is (equal '("B") (aref layers 1)))
    (is (equal '("C") (aref layers 2)))))

(test test-kahn-branching
  (let* ((n1 (make-campaign-node :id "A" :dependencies nil))
         (n2 (make-campaign-node :id "B" :dependencies '("A")))
         (n3 (make-campaign-node :id "C" :dependencies '("A")))
         (n4 (make-campaign-node :id "D" :dependencies '("B" "C")))
         (layers (compute-kahn-layers (list n1 n2 n3 n4))))
    (is (= 3 (length layers)))
    (is (equal '("A") (aref layers 0)))
    ;; Deterministically sorted alphabetically: "B" comes before "C"
    (is (equal '("B" "C") (aref layers 1)))
    (is (equal '("D") (aref layers 2)))))

(test test-kahn-cycle-detection
  (let* ((n1 (make-campaign-node :id "A" :dependencies '("C")))
         (n2 (make-campaign-node :id "B" :dependencies '("A")))
         (n3 (make-campaign-node :id "C" :dependencies '("B"))))
    (signals librecode-runner.conditions:protocol-invariant-violation
      (compute-kahn-layers (list n1 n2 n3)))))

(test test-kahn-independent
  (let* ((n1 (make-campaign-node :id "A" :dependencies nil))
         (n2 (make-campaign-node :id "B" :dependencies nil))
         (layers (compute-kahn-layers (list n1 n2))))
    (is (= 1 (length layers)))
    ;; Deterministically sorted alphabetically: "A" comes before "B"
    (is (equal '("A" "B") (aref layers 0)))))

(test test-kahn-unresolved-dependency
  (let ((n1 (make-campaign-node :id "A" :dependencies '("NON-EXISTENT"))))
    (signals librecode-runner.conditions:protocol-invariant-violation
      (compute-kahn-layers (list n1)))))


