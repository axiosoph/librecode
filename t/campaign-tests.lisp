;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; campaign-tests.lisp — Unit tests for campaign DAG scheduling
;;;

(defpackage #:librecode-test.campaign
  (:use #:cl #:fiveam)
  (:export #:campaign-suite))
(in-package #:librecode-test.campaign)

(def-suite campaign-suite :description "Test campaign scheduling and DAG")
(in-suite campaign-suite)

(test dummy-campaign-test
  (is-true t))
