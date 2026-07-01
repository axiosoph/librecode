;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; journal-tests.lisp — Unit tests for campaign journal tracking
;;;

(defpackage #:librecode-test.journal
  (:use #:cl #:fiveam)
  (:export #:journal-suite))
(in-package #:librecode-test.journal)

(def-suite journal-suite :description "Test campaign journal tracking")
(in-suite journal-suite)

(test dummy-journal-test
  (is-true t))
