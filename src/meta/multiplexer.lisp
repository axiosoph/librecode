;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; multiplexer.lisp — Stub definition for abstract multiplexer protocol
;;;

(in-package #:librecode-meta.multiplexer)

(defclass multiplexer ()
  ())

(defgeneric mux-create-session (mux name &key &allow-other-keys))
(defgeneric mux-send-command (mux session command &key &allow-other-keys))
(defgeneric mux-kill-session (mux session &key &allow-other-keys))
