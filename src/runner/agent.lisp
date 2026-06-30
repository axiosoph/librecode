;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; agent.lisp — Stub definition for CLOS agents and rulesets
;;;

(in-package #:librecode-runner.agent)

(defclass agent ()
  ((id :initarg :id :reader agent-id)
   (ruleset :initarg :ruleset :reader agent-ruleset)
   (system-context :initarg :system-context :reader agent-system-context)))

(defclass permission-rule ()
  ((action :initarg :action :reader permission-rule-action)
   (resource :initarg :resource :reader permission-rule-resource)
   (effect :initarg :effect :reader permission-rule-effect)))

(defun evaluate-permissions (agent action resource)
  (declare (ignore agent action resource))
  nil)
