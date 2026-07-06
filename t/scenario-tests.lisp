;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; scenario-tests.lisp — The campaign's capstone scenario floor: a scripted
;;; model reads a file, edits it, runs a bash command that FAILS, receives the
;;; failure as an ordinary tool result (never a session-ending crash),
;;; corrects, and succeeds. This file covers the in-process variant, built on
;;; P6's shared WITH-MOCK-PROVIDER fixture; the real-subprocess and
;;; kill/resume variants of the same arc live in t/e2e-tests.lisp, extending
;;; its existing harness scaffolding.
;;;

(defpackage #:librecode-test.scenario
  (:use #:cl
        #:fiveam)
  (:export #:scenario-suite))

(in-package #:librecode-test.scenario)

(def-suite scenario-suite
  :description "Suite for the capstone read->edit->fail->correct->succeed scenario floor.")

(in-suite scenario-suite)

(defun tool-role-messages (body)
  "Return, in wire order, the tool-role message hash-tables from a parsed
request BODY's \"messages\" array (a JSON array, which com.inuoe.jzon parses
to a vector; COERCE keeps this responder agnostic to that representation
detail)."
  (remove-if-not (lambda (m) (equal "tool" (gethash "role" m)))
                  (coerce (gethash "messages" body) 'list)))

(test test-scenario-in-process-read-edit-fail-correct-succeed
  "Constraint [c7-in-process-full-arc]: a scripted model reads scenario.txt,
edits it via the edit tool, runs a bash command that FAILS, is handed that
failure as an ordinary next-turn tool result (never a session crash --
premises p7-edit-tool-schema / p7-bash-failure-becomes-tool-error), and only
THEN issues a different, corrective bash command that succeeds. The
responder branches on the inbound request body's tool-role message history
(premise p7-mock-provider-can-branch-on-tool-result-history), not on a raw
call counter, so the corrective step is provably driven by having observed
the failure: it cannot fire before a tool-role message containing \"Error:\"
exists in history."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (librecode-test.event-store::with-test-db (db dir)
      (let* ((session-id "scenario-in-process-sess")
             (scenario-file (uiop:merge-pathnames* "scenario.txt" dir))
             (decisions nil))
        ;; Seed the file the scripted model will read and then edit in place.
        (with-open-file (s scenario-file :direction :output
                                          :if-does-not-exist :create
                                          :if-exists :supersede)
          (write-string "TODO: fix me" s))

        (sqlite:execute-non-query db
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, 1, 'active', ?)"
          session-id "agent-1" (librecode-runner.event-store::current-timestamp-ms))
        ;; *current-session-id* is never bound on this in-process call path
        ;; (only RUN-COORDINATOR binds it, for the subprocess/http drive loop),
        ;; so only the run-tool-worker "execute_tool" permission gate applies.
        (sqlite:execute-non-query db
          "INSERT INTO permission_saved (project_id, action, resource, effect, timestamp)
           VALUES ('default', 'execute_tool', '*', 'allow', 123456)")

        (librecode-test.mock-provider:with-mock-provider
            (port :path "/stream/chat/completions"
                  :responder
                  (lambda (request call-index)
                    (declare (ignore call-index))
                    (let* ((body (com.inuoe.jzon:parse (hunchentoot:raw-post-data :force-text t :request request)))
                           (tool-msgs (tool-role-messages body))
                           (n (length tool-msgs))
                           (last-content (and tool-msgs (gethash "content" (car (last tool-msgs))))))
                      (cond
                        ((= n 0)
                         (push :read decisions)
                         (list (list :tool-calls
                                     (list (list :id "call-1" :name "read_file"
                                                 :arguments "{\"path\": \"scenario.txt\"}")))))
                        ((= n 1)
                         (push :edit decisions)
                         (list (list :tool-calls
                                     (list (list :id "call-2" :name "edit"
                                                 :arguments "{\"filePath\": \"scenario.txt\", \"oldString\": \"TODO: fix me\", \"newString\": \"DONE: fixed\"}")))))
                        ((= n 2)
                         (push :bash-fail decisions)
                         (list (list :tool-calls
                                     (list (list :id "call-3" :name "bash"
                                                 :arguments "{\"command\": \"ls missing-directory/\"}")))))
                        ((and (= n 3) (stringp last-content) (search "Error:" last-content))
                         (push :bash-correct decisions)
                         (list (list :tool-calls
                                     (list (list :id "call-4" :name "bash"
                                                 :arguments "{\"command\": \"mkdir -p missing-directory && ls missing-directory/\"}")))))
                        (t
                         (push :done decisions)
                         (list (list :content "Done!")))))))
          (let ((librecode-runner.runner::*provider-url* (format nil "http://127.0.0.1:~A/stream/chat/completions" port))
                (librecode-runner.protocol::*session-mailbox* (librecode-runner.protocol:make-mailbox)))
            ;; Drive the turn loop exactly like the real session drive loop
            ;; does (librecode-runner.http:call-with-session-drive-loop):
            ;; EXECUTE-PROVIDER-TURN returns T while tool calls keep the turn
            ;; going, NIL once the model settles on a plain-content reply.
            (loop while (librecode-runner.runner:execute-provider-turn session-id "mock-provider" "mock-model"))))

        (setf decisions (nreverse decisions))

        ;; The arc happened in the right order, exactly once each.
        (is (equal '(:read :edit :bash-fail :bash-correct :done) decisions))

        ;; The two bash commands actually differ -- the correction is a real
        ;; correction, not a repeat of the same failing command.
        (let ((tool-rows (sqlite:execute-to-list db
                          "SELECT content FROM session_history WHERE role = 'tool' ORDER BY created_at ASC")))
          (is (= 4 (length tool-rows)))
          (destructuring-bind (read-result edit-result bash-fail-result bash-correct-result) (mapcar #'first tool-rows)
            (is (equal "TODO: fix me" read-result))
            (is (search "Edit applied successfully" edit-result))
            (is (search "Error:" bash-fail-result))
            (is (not (search "Error:" bash-correct-result)))))

        ;; The edit really landed, and the correction really ran (its
        ;; side-effect -- the directory it was supposed to create -- exists).
        (is (equal "DONE: fixed" (uiop:read-file-string scenario-file)))
        (is (probe-file (uiop:merge-pathnames* "missing-directory/" dir)))))))
