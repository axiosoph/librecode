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

    (let* ((port (librecode-test.mock-provider:get-free-port))
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
               (librecode-test.mock-provider:with-mock-provider
                   (mock-port :path "/provider-stream"
                              :connection-close t
                              :responder (lambda (request call-index)
                                           (declare (ignore request call-index))
                                           (list (list :content "Hello response!"))))
                 (unwind-protect
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
                          (setf librecode-runner.runner::*provider-url* old-provider-url)))
                   (ignore-errors (bt:destroy-thread sse-thread))))))
        (stop-http-bridge)))))

(test test-http-prompt-endpoint
  "Test POST /session/:id/prompt and GET /session/:id/event routing."
  (setf hunchentoot:*dispatch-table* nil)
  (librecode-test.event-store::with-tmp-sandbox (dir)
    ;; Initialize schema in librecode.db and close connection immediately
    (let* ((db-path (merge-pathnames "librecode.db" dir))
           (init-db (librecode-runner.event-store:connect-db db-path)))
      (unwind-protect
           (librecode-runner.event-store:init-db init-db)
        (sqlite:disconnect init-db)))

    (let* ((port (librecode-test.mock-provider:get-free-port))
           (url-base (format nil "http://127.0.0.1:~A" port))
           (session-id nil))
      ;; Start the HTTP bridge
      (start-http-bridge :port port :address "127.0.0.1" :db-path "librecode.db" :workspace-root dir)
      (sleep 0.2)
      (unwind-protect
           (progn
             ;; Create session
             (let* ((payload (com.inuoe.jzon:stringify
                              (alexandria:plist-hash-table `("agent_id" "test-agent"))))
                    (res (dexador:post (format nil "~A/session" url-base)
                                       :headers '(("Content-Type" . "application/json"))
                                       :content payload
                                       :keep-alive nil))
                    (parsed (com.inuoe.jzon:parse res)))
               (is (not (null (gethash "session_id" parsed))))
               (setf session-id (gethash "session_id" parsed)))

             ;; Test GET /session/:id/event (alias of stream) and POST /session/:id/prompt
             (let* ((sse-url (format nil "~A/session/~A/event" url-base session-id))
                    (sse-events (librecode-runner.protocol:make-mailbox :name "sse-test-events-2"))
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

               ;; Now prompt the session using mock LLM endpoint.
               (librecode-test.mock-provider:with-mock-provider
                   (mock-port :path "/provider-stream"
                              :connection-close t
                              :responder (lambda (request call-index)
                                           (declare (ignore request call-index))
                                           (list (list :content "Prompt response!"))))
                 (unwind-protect
                      ;; Use setf to globally update provider url so the spawned coordinate thread sees it
                      (let ((old-provider-url librecode-runner.runner::*provider-url*))
                        (unwind-protect
                             (progn
                               (setf librecode-runner.runner::*provider-url* (format nil "http://127.0.0.1:~A/provider-stream" mock-port))
                               ;; Trigger POST /session/:id/prompt
                               (let* ((prompt-payload (com.inuoe.jzon:stringify
                                                       (alexandria:plist-hash-table
                                                        `("id" "prompt-test-id"
                                                          "prompt" ,(alexandria:plist-hash-table '("text" "Hello bot"))
                                                          "resume" t))))
                                      (prompt-res (dexador:post (format nil "~A/session/~A/prompt" url-base session-id)
                                                                :headers '(("Content-Type" . "application/json"))
                                                                :content prompt-payload
                                                                :keep-alive nil))
                                      (prompt-parsed (com.inuoe.jzon:parse prompt-res)))
                                 (is (not (null (gethash "data" prompt-parsed))))
                                 (let ((data-obj (gethash "data" prompt-parsed)))
                                   (is (equal "prompt-test-id" (gethash "id" data-obj)))
                                   (is (equal session-id (gethash "session_id" data-obj)))
                                   (is (equal "Hello bot" (gethash "text" (gethash "prompt" data-obj)))))

                                 ;; Read events from sse-events mailbox
                                 (let* ((evt-open-str (librecode-runner.protocol:receive-message sse-events :timeout 4.0))
                                        (evt-open (and evt-open-str (com.inuoe.jzon:parse evt-open-str)))
                                        (evt1-str (librecode-runner.protocol:receive-message sse-events :timeout 4.0))
                                        (evt1 (and evt1-str (com.inuoe.jzon:parse evt1-str))))
                                   (is (not (null evt-open)))
                                   (is (equal "open" (gethash "event" evt-open)))
                                   (is (not (null evt1)))
                                   (is (equal "session_start" (gethash "event" evt1))))))
                          (setf librecode-runner.runner::*provider-url* old-provider-url)))
                   (ignore-errors (bt:destroy-thread sse-thread))))))
        (stop-http-bridge)))))

(test test-http-step-cap
  "Test that the session drive loop terminates at max-steps and withholds tools on the last step."
  (setf hunchentoot:*dispatch-table* nil)
  (librecode-test.event-store::with-tmp-sandbox (dir)
    ;; Initialize schema in librecode.db and close connection immediately
    (let* ((db-path (merge-pathnames "librecode.db" dir))
           (init-db (librecode-runner.event-store:connect-db db-path)))
      (unwind-protect
           (librecode-runner.event-store:init-db init-db)
        (sqlite:disconnect init-db)))

    (let* ((port (librecode-test.mock-provider:get-free-port))
           (url-base (format nil "http://127.0.0.1:~A" port))
           (session-id nil)
           (provider-calls-count 0)
           (bodies-list nil))

      ;; Register a mock tool
      (let ((tool (make-instance 'librecode-runner.tool:tool
                                 :name "mock-tool"
                                 :description "Mock Tool"
                                 :parameters '(:type "object" :properties (:input (:type "string")))
                                 :capabilities nil
                                 :handler (lambda (args) (declare (ignore args)) "mock-res"))))
        (librecode-runner.tool:register-tool librecode-runner.runner::*tool-registry* tool))

      (unwind-protect
           (progn
             ;; Start the HTTP bridge
             (start-http-bridge :port port :address "127.0.0.1" :db-path "librecode.db" :workspace-root dir)
             (sleep 0.2)

             ;; Create session
             (let* ((payload (com.inuoe.jzon:stringify
                              (alexandria:plist-hash-table
                               `("agent_id" "test-agent"
                                 "ruleset" ,(vector (alexandria:plist-hash-table
                                                     `("action" "execute_tool"
                                                       "resource" "*"
                                                       "effect" "allow")))))))
                    (res (dexador:post (format nil "~A/session" url-base)
                                       :headers '(("Content-Type" . "application/json"))
                                       :content payload
                                       :keep-alive nil))
                    (parsed (com.inuoe.jzon:parse res)))
               (is (not (null (gethash "session_id" parsed))))
               (setf session-id (gethash "session_id" parsed)))

             ;; Set up mock provider that always returns tool calls.
             (librecode-test.mock-provider:with-mock-provider
                 (mock-port :path "/provider-stream"
                            :connection-close t
                            :responder (lambda (request call-index)
                                         (push (hunchentoot:raw-post-data :force-text t :request request) bodies-list)
                                         (setf provider-calls-count call-index)
                                         (list (list :tool-calls
                                                     (list (list :id (format nil "call-~A" call-index)
                                                                 :name "mock-tool" :arguments "{}"))))))
               (let ((old-provider-url librecode-runner.runner::*provider-url*))
                 (unwind-protect
                      (progn
                        (setf librecode-runner.runner::*provider-url* (format nil "http://127.0.0.1:~A/provider-stream" mock-port))

                        ;; Admit prompt
                        (let* ((prompt-payload (com.inuoe.jzon:stringify
                                                (alexandria:plist-hash-table
                                                 `("prompt_id" "prompt-test-cap"
                                                   "prompt_text" "Keep calling tool please"
                                                   "delivery_mode" "STEER"))))
                               (admit-res (dexador:post (format nil "~A/session/~A/admit" url-base session-id)
                                                        :headers '(("Content-Type" . "application/json"))
                                                        :content prompt-payload
                                                        :keep-alive nil)))
                          (is (not (null admit-res))))

                        ;; We want to run with max_steps = 3.
                        (let* ((wake-payload (com.inuoe.jzon:stringify
                                              (alexandria:plist-hash-table
                                               `("provider" "mock-provider"
                                                 "model" "mock-model"
                                                 "max_steps" 3))))
                               (wake-thread
                                 (bt:make-thread
                                  (lambda ()
                                    (handler-case
                                        (dexador:post (format nil "~A/session/~A/wake" url-base session-id)
                                                      :headers '(("Content-Type" . "application/json"))
                                                      :content wake-payload
                                                      :keep-alive nil)
                                      (error (c) (format nil "error: ~A" c)))))))
                          ;; Wait up to 3 seconds for the wake thread to finish
                          (let ((finished (loop for i from 1 to 30
                                                while (bt:thread-alive-p wake-thread)
                                                do (sleep 0.1)
                                                finally (return (not (bt:thread-alive-p wake-thread))))))
                            (if finished
                                (bt:join-thread wake-thread)
                                (progn
                                  (bt:destroy-thread wake-thread)
                                  (error "Wake session hung! Step cap failed to terminate."))))

                          ;; Let's inspect provider-calls-count
                          (is (= 3 provider-calls-count))

                          ;; Inspect the bodies of each call
                          (is (= 3 (length bodies-list)))
                          (let* ((body1 (com.inuoe.jzon:parse (third bodies-list)))
                                 (body2 (com.inuoe.jzon:parse (second bodies-list)))
                                 (body3 (com.inuoe.jzon:parse (first bodies-list))))
                            ;; 1st and 2nd should have tools
                            (is-true (gethash "tools" body1))
                            (is-true (gethash "tools" body2))
                            ;; 3rd (final) should NOT have tools
                            (is-false (gethash "tools" body3)))))
                   (setf librecode-runner.runner::*provider-url* old-provider-url)))))
        (progn
          (stop-http-bridge)
          (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
            (remhash "mock-tool" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))))))
