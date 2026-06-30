;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; protocol.lisp — Stub definition for coordination protocol
;;;

(in-package #:librecode-runner.protocol)

(defun run-coordinator (key function)
  (declare (ignore key function))
  nil)

(defun make-mailbox (&key name)
  (declare (ignore name))
  nil)

(defun send-message (mailbox message)
  (declare (ignore mailbox message))
  nil)

(defun receive-message (mailbox &key timeout)
  (declare (ignore mailbox timeout))
  nil)
