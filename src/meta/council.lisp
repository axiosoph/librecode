;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; council.lisp — Stub definition for multi-seat council coordination
;;;

(in-package #:librecode-meta.council)

(defclass council ()
  ())

(defun convene-council (council &key &allow-other-keys)
  (declare (ignore council))
  nil)

(defun validate-assent (council assent &key &allow-other-keys)
  (declare (ignore council assent))
  nil)
