;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; tool.lisp — Stub definition for tool execution and registries
;;;

(in-package #:librecode-runner.tool)

(defclass tool ()
  ())

(defclass tool-registry ()
  ())

(defun register-tool (registry tool)
  (declare (ignore registry tool))
  nil)

(defun materialize-tools (registry)
  (declare (ignore registry))
  nil)

(defun execute-tool (tool arguments)
  (declare (ignore tool arguments))
  nil)
