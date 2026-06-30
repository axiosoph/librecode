;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; harness.lisp — Stub definition for supervised child harness interface
;;;

(in-package #:librecode-meta.harness)

(defclass harness ()
  ())

(defgeneric harness-spawn (harness &key &allow-other-keys))
(defgeneric harness-destroy (harness &key &allow-other-keys))
(defgeneric harness-inject-conditioning (harness conditioning &key &allow-other-keys))
