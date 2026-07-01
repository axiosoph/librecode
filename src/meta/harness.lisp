;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; harness.lisp — Stub definition for supervised child harness interface
;;;

(in-package #:librecode-meta.harness)

(defclass harness ()
  ((id :initarg :id :reader harness-id :type string)
   (config :initarg :config :reader harness-config)
   (status :initform :idle :accessor %harness-status)))

(defgeneric harness-spawn (type config)
  (:documentation "Spawns a new child harness instance of the specified TYPE and returns a harness instance."))

(defgeneric harness-prompt (instance prompt &key mode)
  (:documentation "Sends a prompt string to the harness. MODE is either :steer (inline steering input) or :queue (queued input for when the session goes idle)."))

(defgeneric harness-read-events (instance)
  (:documentation "Returns an input stream or queue of structured events/messages emitted by the harness."))

(defgeneric harness-send-command (instance command)
  (:documentation "Sends a control command to the harness (e.g. /clear, /compact, or tool approval)."))

(defgeneric harness-inject-conditioning (instance persona-text delivery-surface)
  (:documentation "Injects system prompt or behavior-conditioning text into the harness's native storage/surface."))

(defgeneric harness-status (instance)
  (:documentation "Queries the harness run state, returning :idle, :running, :error, or :terminated."))

(defgeneric harness-terminate (instance)
  (:documentation "Sends a termination signal to end the harness process gracefully."))

(defgeneric harness-prepare-workspace (harness-class-symbol repository-path target-directory)
  (:documentation "Prepares the isolated git worktree and storage directories before a harness instance is spawned."))

(defgeneric harness-cleanup-workspace (harness-class-symbol repository-path target-directory &key force)
  (:documentation "Cleans up the isolated workspace and worktree directory after execution completes. Specializes on class symbols."))

(defgeneric harness-destroy (instance &key &allow-other-keys)
  (:documentation "Legacy/compatibility alias for harness-terminate."))

(defmethod harness-destroy ((instance harness) &key &allow-other-keys)
  (harness-terminate instance))
