;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; session.lisp — Stub definition for session management and inputs
;;;

(in-package #:librecode-runner.session)

(defclass session ()
  ((id :initarg :id :reader session-id)
   (state :initarg :state :accessor session-state)))

(defun admit-input (session input)
  (declare (ignore session input))
  nil)

(defun promote-input (session input)
  (declare (ignore session input))
  nil)
