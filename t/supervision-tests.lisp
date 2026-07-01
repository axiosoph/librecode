;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; supervision-tests.lisp — Unit tests for child harness process supervision
;;;

(defpackage #:librecode-test.supervision
  (:use #:cl #:fiveam)
  (:export #:supervision-suite))
(in-package #:librecode-test.supervision)

(def-suite supervision-suite :description "Test child harness processes supervision")
(in-suite supervision-suite)

(test dummy-supervision-test
  (is-true t))
