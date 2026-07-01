;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; failure-relay-tests.lisp — Unit tests for the failure-relay thread propagation primitive
;;;

(defpackage #:librecode-test.failure-relay
  (:use #:cl #:fiveam)
  (:export #:failure-relay-suite))
(in-package #:librecode-test.failure-relay)

(def-suite failure-relay-suite :description "Test failure relay primitive")
(in-suite failure-relay-suite)

(test dummy-failure-relay-test
  (is-true t))
