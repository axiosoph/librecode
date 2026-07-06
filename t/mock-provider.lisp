;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; mock-provider.lisp — Shared Hunchentoot mock-provider fixture for tests
;;;
;;; Every suite that exercises a live SSE-streaming turn needs a small local
;;; HTTP server standing in for an LLM provider. Before this fixture, each
;;; suite hand-rolled its own acceptor + hunchentoot:*dispatch-table* closure
;;; (http-tests, session-tests, child-tests, harness-tests, provider-tests
;;; all did this independently). WITH-MOCK-PROVIDER consolidates that setup
;;; into one place while keeping every test's genuine HTTP round-trip (SSE
;;; streaming included) -- it consolidates the dispatch/acceptor boilerplate,
;;; not the transport itself.

(defpackage #:librecode-test.mock-provider
  (:use #:cl)
  (:export #:with-mock-provider
           #:get-free-port))

(in-package #:librecode-test.mock-provider)

(defun get-free-port ()
  "Find a free port on localhost by binding then immediately releasing a socket."
  (let ((socket (usocket:socket-listen "127.0.0.1" 0)))
    (unwind-protect
         (usocket:get-local-port socket)
      (usocket:socket-close socket))))

(defun %sse-write (stream string)
  (write-sequence (flexi-streams:string-to-octets string :external-format :utf-8) stream)
  (force-output stream))

(defun %tool-call-chunk-json (calls)
  "Build the `data: {...}` line for a tool_calls delta from CALLS, a list of
(:id :name :arguments &optional :index) plists; :index defaults to CALLS
position."
  (format nil "data: {\"choices\": [{\"delta\": {\"tool_calls\": [~{~A~^, ~}]}}]}~%"
          (loop for call in calls
                for i from 0
                collect (format nil "{\"index\": ~D, \"id\": ~S, \"function\": {\"name\": ~S, \"arguments\": ~S}}"
                                (or (getf call :index) i)
                                (getf call :id)
                                (getf call :name)
                                (getf call :arguments)))))

(defun %run-actions (stream actions)
  "Execute scripted ACTIONS in order against STREAM, ending with a
`data: [DONE]` marker unless the bare keyword :NO-DONE appears in ACTIONS.
Each action is one of:
  (:content TEXT)      -- one delta chunk carrying TEXT
  (:tool-calls CALLS)  -- one delta chunk carrying CALLS (see %TOOL-CALL-CHUNK-JSON)
  (:raw JSON-STRING)   -- one chunk with JSON-STRING written verbatim (e.g. an error frame)
  (:call THUNK)        -- call THUNK with no arguments (mailbox waits, capture side effects)"
  (let ((suppress-done nil))
    (dolist (action actions)
      (if (eq action :no-done)
          (setf suppress-done t)
          (destructuring-bind (kind &optional payload) action
            (ecase kind
              (:content (%sse-write stream (format nil "data: {\"choices\": [{\"delta\": {\"content\": ~S}}]}~%" payload)))
              (:tool-calls (%sse-write stream (%tool-call-chunk-json payload)))
              (:raw (%sse-write stream (format nil "data: ~A~%" payload)))
              (:call (funcall payload))))))
    (unless suppress-done
      (%sse-write stream (format nil "data: [DONE]~%")))))

(defun call-with-mock-provider (port path host method connection-close responder thunk)
  "Function backing WITH-MOCK-PROVIDER; see its docstring for the contract."
  (let* ((call-index 0)
         (lock (bt:make-lock "mock-provider-call-index"))
         (acceptor (make-instance 'hunchentoot:easy-acceptor :port port :address host))
         (dispatcher
           (lambda (request)
             (when (and (equal (hunchentoot:script-name request) path)
                        (= (hunchentoot:acceptor-port (hunchentoot:request-acceptor request)) port)
                        (or (null method) (eq (hunchentoot:request-method request) method)))
               (let* ((this-index (bt:with-lock-held (lock) (incf call-index)))
                      (actions (funcall responder request this-index)))
                 (lambda ()
                   (setf (hunchentoot:content-type*) "text/event-stream")
                   (when connection-close
                     (setf (hunchentoot:header-out "Connection") "close"))
                   (let ((stream (hunchentoot:send-headers)))
                     (%run-actions stream actions)
                     "")))))))
    (push dispatcher hunchentoot:*dispatch-table*)
    (unwind-protect
         (progn
           (hunchentoot:start acceptor)
           (funcall thunk))
      (hunchentoot:stop acceptor)
      (setf hunchentoot:*dispatch-table* (delete dispatcher hunchentoot:*dispatch-table*)))))

(defmacro with-mock-provider ((port-var &key (path "/stream") (host "127.0.0.1") method connection-close responder) &body body)
  "Bind PORT-VAR to a fresh local port, start an ephemeral Hunchentoot
acceptor there, install a single dispatcher matching PATH (and PORT-VAR's
own acceptor port -- never a different one sharing the process-global
*dispatch-table*), if METHOD is given that request method too, and if
CONNECTION-CLOSE is non-nil send a `Connection: close` response header
(some callers rely on the mock forcing connection closure to signal
end-of-stream to their HTTP client), run BODY with the mock provider live,
then always tear the acceptor and dispatcher back down on exit.

RESPONDER is called once per matching request as
(funcall RESPONDER request call-index), where CALL-INDEX starts at 1 and
increments once per matched request (in place of each caller's own
lock-and-counter closure). It runs synchronously before headers are sent,
so it may inspect REQUEST's headers/body to branch the response -- and must
return a list of actions describing what to stream back; see %RUN-ACTIONS."
  (let ((thunk (gensym "THUNK")))
    `(let ((,port-var (get-free-port)))
       (flet ((,thunk () ,@body))
         (call-with-mock-provider ,port-var ,path ,host ,method ,connection-close ,responder #',thunk)))))
