;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; http-tests.lisp — Unit and integration tests for the HTTP bridge and SSE stream
;;;

(defpackage #:librecode-test.http
  (:use #:cl #:fiveam #:librecode-runner.http)
  (:export #:http-suite))

(in-package #:librecode-test.http)

(def-suite http-suite
  :description "Suite for Clack HTTP server bridge and SSE coordination endpoints.")

(in-suite http-suite)

(defun get-free-port ()
  (+ 20000 (random 5000)))

(defun query-test-db (dir sql &rest args)
  (let* ((db-path (merge-pathnames "librecode.db" dir))
         (db (librecode-runner.event-store:connect-db db-path)))
    (unwind-protect
         (apply #'sqlite:execute-single db sql args)
      (sqlite:disconnect db))))

(test test-http-endpoints
  "Test all REST and SSE coordination endpoints on a running HTTP bridge server."
  (setf hunchentoot:*dispatch-table* nil)
  (librecode-test.event-store::with-tmp-sandbox (dir)
    ;; Initialize schema in librecode.db and close connection immediately
    (let* ((db-path (merge-pathnames "librecode.db" dir))
           (init-db (librecode-runner.event-store:connect-db db-path)))
      (unwind-protect
           (librecode-runner.event-store:init-db init-db)
        (sqlite:disconnect init-db)))

    (let* ((port (get-free-port))
           (url-base (format nil "http://127.0.0.1:~A" port))
           (session-id nil))
      ;; Start the HTTP bridge
      (start-http-bridge :port port :address "127.0.0.1" :db-path "librecode.db" :workspace-root dir)
      (sleep 0.2)
      (unwind-protect
           (progn
             ;; 1. Test POST /session
             (let* ((payload (com.inuoe.jzon:stringify
                              (alexandria:plist-hash-table
                               `("agent_id" "test-agent"
                                 "system_context" "System instructions go here"
                                 "ruleset" ,(vector (alexandria:plist-hash-table
                                                     `("action" "execute_tool"
                                                       "resource" "shell"
                                                       "effect" "allow")))))))
                    (res (dexador:post (format nil "~A/session" url-base)
                                       :headers '(("Content-Type" . "application/json"))
                                       :content payload
                                       :keep-alive nil))
                    (parsed (com.inuoe.jzon:parse res)))
               (is (not (null (gethash "session_id" parsed))))
               (setf session-id (gethash "session_id" parsed))

               ;; Verify it was created in the DB
               (is (equal "test-agent" (query-test-db dir "SELECT agent_id FROM session_state WHERE session_id = ?" session-id)))
               (is (equal "System instructions go here" (query-test-db dir "SELECT baseline_text FROM context_epoch WHERE session_id = ?" session-id)))
               (is (equal "allow" (query-test-db dir "SELECT effect FROM permission_saved WHERE action = 'execute_tool' AND resource = 'shell'"))))

             ;; 2. Test POST /session/:id/admit
             (let* ((payload (com.inuoe.jzon:stringify
                              (alexandria:plist-hash-table
                               `("prompt_id" "prompt-1"
                                 "prompt_text" "Hello world!"
                                 "delivery_mode" "STEER"))))
                    (res (dexador:post (format nil "~A/session/~A/admit" url-base session-id)
                                       :headers '(("Content-Type" . "application/json"))
                                       :content payload
                                       :keep-alive nil))
                    (parsed (com.inuoe.jzon:parse res)))
               (is (equal "pending" (gethash "status" parsed)))
               ;; Verify it is in the session_input table
               (is (equal "PENDING" (query-test-db dir "SELECT status FROM session_input WHERE id = 'prompt-1'"))))

             ;; 3. Test POST /session/:id/promote
             (let* ((payload (com.inuoe.jzon:stringify
                              (alexandria:plist-hash-table
                               `("prompt_id" "prompt-1"))))
                    (res (dexador:post (format nil "~A/session/~A/promote" url-base session-id)
                                       :headers '(("Content-Type" . "application/json"))
                                       :content payload
                                       :keep-alive nil))
                    (parsed (com.inuoe.jzon:parse res)))
               (is (eq t (gethash "promoted" parsed)))
               ;; Verify status is now PROMOTED
               (is (equal "PROMOTED" (query-test-db dir "SELECT status FROM session_input WHERE id = 'prompt-1'")))
               ;; Verify it is visible in history
               (is (equal "Hello world!" (query-test-db dir "SELECT content FROM session_history WHERE id = 'prompt-1'"))))

             ;; 4. Test GET /session/:id/history
             (let* ((res (dexador:get (format nil "~A/session/~A/history" url-base session-id)
                                      :keep-alive nil))
                    (parsed (com.inuoe.jzon:parse res)))
               (is (vectorp parsed))
               (is (= 1 (length parsed)))
               (is (equal "prompt-1" (gethash "id" (elt parsed 0))))
               (is (equal "user" (gethash "role" (elt parsed 0))))
               (is (equal "Hello world!" (gethash "content" (elt parsed 0)))))

             ;; 5. Test GET /session/:id/stream and POST /session/:id/wake
             (let* ((sse-url (format nil "~A/session/~A/stream" url-base session-id))
                    (sse-events (librecode-runner.protocol:make-mailbox :name "sse-test-events"))
                    (sse-thread
                      (bt:make-thread
                       (lambda ()
                         (handler-case
                             (let ((stream (dexador:get sse-url :want-stream t :read-timeout 5 :keep-alive nil)))
                               (unwind-protect
                                    (loop
                                      (let ((line (read-line stream nil :eof)))
                                        (if (eq line :eof)
                                            (return)
                                            (when (alexandria:starts-with-subseq "data: " line)
                                              (let ((data (subseq line 6)))
                                                (librecode-runner.protocol:send-message sse-events data))))))
                                 (close stream)))
                           (error (c)
                             (librecode-runner.protocol:send-message sse-events (format nil "error: ~A" c))))))))
               ;; Sleep slightly to allow SSE connection to establish
               (sleep 0.2)

               ;; Now wake the session using mock LLM endpoint.
               (let* ((mock-port (get-free-port))
                      (mock-acceptor (make-instance 'hunchentoot:easy-acceptor :port mock-port))
                      (dispatcher (lambda (request)
                                    (when (equal (hunchentoot:script-name request) "/provider-stream")
                                      (lambda ()
                                        (setf (hunchentoot:content-type*) "text/event-stream")
                                        (setf (hunchentoot:header-out "Connection") "close")
                                        (let ((stream (hunchentoot:send-headers)))
                                          (write-sequence (flexi-streams:string-to-octets (format nil "data: {\"choices\": [{\"delta\": {\"content\": \"Hello response!\"}}]}~%") :external-format :utf-8) stream)
                                          (force-output stream)
                                          (write-sequence (flexi-streams:string-to-octets (format nil "data: [DONE]~%") :external-format :utf-8) stream)
                                          (force-output stream)
                                          ""))))))
                 (push dispatcher hunchentoot:*dispatch-table*)
                 (unwind-protect
                      (progn
                        (hunchentoot:start mock-acceptor)
                        ;; Use setf to globally update provider url so the spawned coordinate thread sees it
                        (let ((old-provider-url librecode-runner.runner::*provider-url*))
                          (unwind-protect
                               (progn
                                 (setf librecode-runner.runner::*provider-url* (format nil "http://127.0.0.1:~A/provider-stream" mock-port))
                                 ;; Trigger POST /session/:id/wake
                                 (let* ((wake-payload (com.inuoe.jzon:stringify
                                                       (alexandria:plist-hash-table
                                                        `("provider" "mock-provider"
                                                          "model" "mock-model"))))
                                        (wake-res (dexador:post (format nil "~A/session/~A/wake" url-base session-id)
                                                                :headers '(("Content-Type" . "application/json"))
                                                                :content wake-payload
                                                                :keep-alive nil))
                                        (wake-parsed (com.inuoe.jzon:parse wake-res)))
                                   (is (equal "woken" (gethash "status" wake-parsed)))

                                   ;; Read events from sse-events mailbox
                                   (let* ((evt-open-str (librecode-runner.protocol:receive-message sse-events :timeout 4.0))
                                          (evt-open (and evt-open-str (com.inuoe.jzon:parse evt-open-str)))
                                          (evt1-str (librecode-runner.protocol:receive-message sse-events :timeout 4.0))
                                          (evt1 (and evt1-str (com.inuoe.jzon:parse evt1-str)))
                                          (evt2-str (librecode-runner.protocol:receive-message sse-events :timeout 4.0))
                                          (evt2 (and evt2-str (com.inuoe.jzon:parse evt2-str)))
                                          (evt3-str (librecode-runner.protocol:receive-message sse-events :timeout 4.0))
                                          (evt3 (and evt3-str (com.inuoe.jzon:parse evt3-str))))
                                     (is (not (null evt-open)))
                                     (is (equal "open" (gethash "event" evt-open)))
                                     (is (not (null evt1)))
                                     (is (equal "session_start" (gethash "event" evt1)))
                                     (is (not (null evt2)))
                                     (is (equal "delta" (gethash "event" evt2)))
                                     (is (equal "Hello response!" (gethash "content" evt2)))
                                     (is (not (null evt3)))
                                     (is (equal "complete" (gethash "event" evt3))))))
                            (setf librecode-runner.runner::*provider-url* old-provider-url))))
                     (progn
                       (hunchentoot:stop mock-acceptor)
                       (setf hunchentoot:*dispatch-table* (delete dispatcher hunchentoot:*dispatch-table*))
                       (ignore-errors (bt:destroy-thread sse-thread)))))))
        (stop-http-bridge)))))
