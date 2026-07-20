;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; provider-integration-tests.lisp — Real authenticated provider reach
;;;
;;; Proves the credential path end to end: an env-var-sourced secret set in
;;; the parent test process, inherited by a genuinely spawned run-child
;;; subprocess (never interpolated into its --eval argv), read there via
;;; uiop:getenv, threaded through configure-session :auth, and surfaced as
;;; an outbound `Authorization: Bearer <token>` header against a
;;; with-mock-provider stand-in whose host:port is asserted to differ from
;;; both of runner.lisp's hardcoded unauthenticated defaults.
;;;

(defpackage #:librecode-test.provider-integration
  (:use #:cl
        #:fiveam
        #:librecode-runner.child)
  (:export #:provider-integration-suite))

(in-package #:librecode-test.provider-integration)

(def-suite provider-integration-suite
  :description "Suite for real authenticated provider reach (child subprocess -> provider) integration tests.")

(in-suite provider-integration-suite)

(defparameter +auth-env-var+ "LIBRECODE_PROVIDER_API_KEY"
  "Env var name run-child reads its provider credential from.")

(test test-child-authenticated-provider-reach
  "run-child, spawned as a genuine subprocess with the credential only ever
reaching it via inherited environment (never argv), must configure the
session with :auth and cause execute-provider-turn to send an outbound
Authorization: Bearer <token> header to the session's configured
(non-default) endpoint."
  (let ((session-id "n4-auth-reach-session")
        (api-token "n4-integration-secret-token-do-not-log")
        (request-headers nil))
    (librecode-test.event-store::with-tmp-sandbox (dir)
      (let* ((target-dir (uiop:merge-pathnames* "target/" dir))
             (db-path "librecode-child.db"))
        (ensure-directories-exist target-dir)

        (librecode-test.mock-provider:with-mock-provider
            (port :path "/stream/chat/completions"
                  :method :post
                  :responder (lambda (request call-index)
                               (declare (ignore call-index))
                               (setf request-headers (hunchentoot:headers-in request))
                               (list (list :content "Task complete."))))
          (let* ((project-root (truename "./"))
                 (raw-registry (uiop:getenv "CL_SOURCE_REGISTRY"))
                 (paths (and raw-registry (uiop:split-string raw-registry :separator '(#\:))))
                 (clean-paths (remove-if (lambda (p) (or (null p) (string= p ""))) paths))
                 (directives (mapcar (lambda (p)
                                       (if (alexandria:ends-with-subseq "//" p)
                                           (list :tree (subseq p 0 (- (length p) 2)))
                                           (list :directory p)))
                                     clean-paths))
                 (source-registry-sexpr (append (list :source-registry)
                                                directives
                                                (list :ignore-inherited-configuration)))
                 (provider-url (format nil "http://127.0.0.1:~A/stream" port))
                 ;; The api-token never appears below -- only the env var
                 ;; NAME is referenced in this --eval string; the VALUE
                 ;; reaches the child solely through inherited environment.
                 (command (list "sbcl" "--noinform" "--non-interactive"
                                "--eval" "(require :sb-posix)"
                                "--eval" "(sb-posix:setenv \"CL_SOURCE_REGISTRY\" \"\" 1)"
                                "--eval" "(require :asdf)"
                                "--eval" (format nil "(asdf:initialize-source-registry '~S)" source-registry-sexpr)
                                "--eval" (format nil "(push (truename ~S) asdf:*central-registry*)" (namestring project-root))
                                "--eval" "(asdf:load-system :librecode-runner)"
                                "--eval" (format nil "(librecode-runner.child:run-child :workspace-root ~S :db-path ~S :provider-url ~S :model ~S :task ~S :session-id ~S)"
                                                 (namestring target-dir) db-path provider-url "mock-model" "say hello" session-id)))
                 (config (list :id session-id
                               :workspace-root target-dir
                               :command command))
                 (harness nil))

            (sb-posix:setenv +auth-env-var+ api-token 1)
            (unwind-protect
                 (progn
                   (setf harness (librecode-meta.harness:harness-spawn 'librecode-meta.harness::subprocess-harness config))
                   (is (typep harness 'librecode-meta.harness::subprocess-harness))
                   (let ((start-time (get-universal-time))
                         (timeout 15.0)
                         (landed-status nil))
                     (loop
                       (let* ((elapsed (- (get-universal-time) start-time))
                              (status (librecode-meta.harness:harness-status harness)))
                         (cond
                           ((member status '(:idle :error :terminated))
                            (setf landed-status status)
                            (return))
                           ((>= elapsed timeout)
                            (return))))
                       (sleep 0.1))
                     (unless (eq landed-status :idle)
                       (let ((events '()))
                         (loop
                           (let ((evt (librecode-meta.harness:harness-read-event harness :timeout 0.1)))
                             (if evt
                                 (push evt events)
                                 (return))))
                         (format t "~%--- Harness Exit Code: ~S, Error Message: ~S, Command: ~S, Received Events: ~S ---~%"
                                 (librecode-meta.harness::harness-exit-code harness)
                                 (librecode-meta.harness::harness-error-message harness)
                                 command
                                 (reverse events))))
                     (is (eq landed-status :idle)))

                   ;; Assert the outbound Authorization header carries the
                   ;; env-sourced token as a Bearer credential.
                   (is-true request-headers)
                   (is (equal (format nil "Bearer ~A" api-token)
                              (cdr (assoc :authorization request-headers))))

                   ;; Assert host:port explicitly differs from both
                   ;; hardcoded unauthenticated defaults -- not merely
                   ;; structurally distinct by construction.
                   (let ((received-host (cdr (assoc :host request-headers))))
                     (is-true received-host)
                     (is (not (equal "localhost:8080" received-host)))
                     (is (not (equal "localhost:8081" received-host)))))

              ;; Unconditionally unset the credential, regardless of outcome,
              ;; so no later suite in this just-test SBCL image observes it.
              (sb-posix:unsetenv +auth-env-var+)
              (when harness
                (librecode-meta.harness:harness-terminate harness)))))))))
