;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; conditions.lisp — Custom conditions for the librecode runner
;;;

(in-package #:librecode-runner.conditions)

(define-condition harness-failure (serious-condition)
  ((exit-code
    :initarg :exit-code
    :reader harness-failure-exit-code
    :initform nil
    :type (or null integer)
    :documentation "The exit code returned by the child harness process, if available.")
   (message
    :initarg :message
    :reader harness-failure-message
    :initform "No error message provided."
    :type string
    :documentation "Details on the failure returned from the child harness.")
   (process-id
    :initarg :process-id
    :reader harness-failure-process-id
    :initform nil
    :type (or null integer string)
    :documentation "The process identifier of the failed child harness."))
  (:report (lambda (condition stream)
             (format stream "Harness Failure [process-id: ~A]: Child harness process terminated abnormally.~%~
                             What failed: Child harness runner execution loop.~%~
                             Why: ~A (exit-code: ~A)~%~
                             Where: Subprocess monitor layer."
                     (or (harness-failure-process-id condition) "unknown")
                     (harness-failure-message condition)
                     (or (harness-failure-exit-code condition) "N/A"))))
  (:documentation "Signal that a managed child harness process terminated unexpectedly, exited with an error, or timed out during execution."))

(define-condition provider-error (serious-condition)
  ((message
    :initarg :message
    :reader provider-error-message
    :initform "Unknown API error."
    :type string
    :documentation "The error message or payload returned by the LLM provider API.")
   (endpoint
    :initarg :endpoint
    :reader provider-error-endpoint
    :initform "unknown"
    :type string
    :documentation "The network endpoint or API route that was called.")
   (provider
    :initarg :provider
    :reader provider-error-provider
    :initform "unknown"
    :type string
    :documentation "The name of the LLM provider (e.g. Anthropic, OpenAI)."))
  (:report (lambda (condition stream)
             (format stream "Provider Error [provider: ~A, endpoint: ~A]: LLM API request failed.~%~
                             What failed: LLM model turn execution network request.~%~
                             Why: ~A~%~
                             Where: HTTP/SSE streaming connection client boundary."
                     (provider-error-provider condition)
                     (provider-error-endpoint condition)
                     (provider-error-message condition))))
  (:documentation "Signal an API failure, connection drop, or rate limit threshold hit from the LLM provider."))

(define-condition context-overflow (serious-condition)
  ((message
    :initarg :message
    :reader context-overflow-message
    :initform "Token limit exceeded."
    :type string
    :documentation "Details on what exceeded the context limits.")
   (budget
    :initarg :budget
    :reader context-overflow-budget
    :initform 0
    :type integer
    :documentation "The maximum allowable token budget for the model context.")
   (requested
    :initarg :requested
    :reader context-overflow-requested
    :initform 0
    :type integer
    :documentation "The total number of tokens requested by the prompt session."))
  (:report (lambda (condition stream)
             (format stream "Context Overflow: Input context exceeds token budget.~%~
                             What failed: Token boundary compilation limit.~%~
                             Why: Requested token count ~A exceeds budget limit of ~A.~%~
                             Details: ~A~%~
                             Where: Context compaction and prompting engine."
                     (context-overflow-requested condition)
                     (context-overflow-budget condition)
                     (context-overflow-message condition))))
  (:documentation "Signal that the assembled session context history exceeds the maximum token budget of the target LLM provider."))

(define-condition tool-timeout (serious-condition)
  ((message
    :initarg :message
    :reader tool-timeout-message
    :initform "Tool execution limit exceeded."
    :type string
    :documentation "Details on the tool execution timeout.")
   (tool-id
    :initarg :tool-id
    :reader tool-timeout-tool-id
    :initform "unknown"
    :type string
    :documentation "The unique identifier of the tool being executed.")
   (duration
    :initarg :duration
    :reader tool-timeout-duration
    :initform 0
    :type number
    :documentation "The duration limit (in seconds) that was exceeded."))
  (:report (lambda (condition stream)
             (format stream "Tool Timeout [tool-id: ~A]: Tool exceeded execution duration limit.~%~
                             What failed: Materialized tool thread execution.~%~
                             Why: Execution exceeded duration limit of ~A seconds.~%~
                             Details: ~A~%~
                             Where: Worker thread pool and tool settlement engine."
                     (tool-timeout-tool-id condition)
                     (tool-timeout-duration condition)
                     (tool-timeout-message condition))))
  (:documentation "Signal that a running tool failed to settle within its allowed execution time limit."))

(define-condition process-hang (serious-condition)
  ((message
    :initarg :message
    :reader process-hang-message
    :initform "Process ceased emitting events."
    :type string
    :documentation "Reasoning/diagnostics for detecting the hang state.")
   (process-id
    :initarg :process-id
    :reader process-hang-process-id
    :initform nil
    :type (or null integer string)
    :documentation "The process identifier of the hanging child harness."))
  (:report (lambda (condition stream)
             (format stream "Process Hang [process-id: ~A]: Subprocess ceased emitting events without terminating.~%~
                             What failed: Child harness event streaming hook.~%~
                             Why: ~A~%~
                             Where: Metaharness supervision loop check."
                     (or (process-hang-process-id condition) "unknown")
                     (process-hang-message condition))))
  (:documentation "Signal that a child process is active in the OS but has stopped producing output or events on its coordination interfaces."))

(define-condition protocol-invariant-violation (serious-condition)
  ((message
    :initarg :message
    :reader protocol-invariant-violation-message
    :initform "Core safety invariant check failed."
    :type string
    :documentation "The specific violation message.")
   (invariant
    :initarg :invariant
    :reader protocol-invariant-violation-invariant
    :initform "unknown"
    :type string
    :documentation "The identifier or label of the violated invariant (e.g. I1, I2, etc.)."))
  (:report (lambda (condition stream)
             (format stream "Protocol Invariant Violation [invariant: ~A]: Core coordination safety rule violated.~%~
                             What failed: Coordination protocol validation check.~%~
                             Why: ~A~%~
                             Where: Run coordinator or council consensus validator."
                     (protocol-invariant-violation-invariant condition)
                     (protocol-invariant-violation-message condition))))
  (:documentation "Signal that an invariant constraint has been violated in the campaign, council, or coordinator layers."))

(define-condition journal-invariant-violation (serious-condition)
  ((message
    :initarg :message
    :reader journal-invariant-violation-message
    :initform "Replayed journal trajectory failed a crown-jewel invariant."
    :type string
    :documentation "The specific violation message.")
   (invariant
    :initarg :invariant
    :reader journal-invariant-violation-invariant
    :initform "unknown"
    :type string
    :documentation "The name of the librecode-model invariant predicate that returned NIL."))
  (:report (lambda (condition stream)
             (format stream "Journal Invariant Violation [invariant: ~A]: Replayed trajectory is log-integrity-compromised.~%~
                             What failed: ~A~%~
                             Why: A syntactically valid journal folded, via TRANSITION-EVENT, to a state history this invariant forbids.~%~
                             Where: RUN-CAMPAIGN's resume boot-gate, before any node dispatch."
                     (journal-invariant-violation-invariant condition)
                     (journal-invariant-violation-message condition))))
  (:documentation "Signal that a replayed journal's folded trajectory violates one of librecode-model's crown-jewel invariants -- refuse to resume rather than continue past a corrupted or tampered log."))

(define-condition gate-failure (serious-condition)
  ((message
    :initarg :message
    :reader gate-failure-message
    :initform "Command verification exited with non-zero code."
    :type string
    :documentation "The diagnostic output or error description.")
   (command
    :initarg :command
    :reader gate-failure-command
    :initform "unknown"
    :type string
    :documentation "The gate verification command that failed to execute.")
   (exit-code
    :initarg :exit-code
    :reader gate-failure-exit-code
    :initform nil
    :type (or null integer)
    :documentation "The non-zero exit code returned by the gate process."))
  (:report (lambda (condition stream)
             (format stream "Gate Failure [command: ~S]: Campaign validation gate failed.~%~
                             What failed: Worktree/boundary gate check.~%~
                             Why: ~A (exit-code: ~A)~%~
                             Where: Metaharness gate runner layer."
                     (gate-failure-command condition)
                     (gate-failure-message condition)
                     (or (gate-failure-exit-code condition) "unknown"))))
  (:documentation "Signal that a project-specific validation gate, shell command hook, or Nickel contract verification failed."))

(define-condition denied-error (serious-condition)
  ((message
    :initarg :message
    :reader denied-error-message
    :initform "Access denied by permission policy."
    :type string
    :documentation "Details on why permission was denied.")
   (action
    :initarg :action
    :reader denied-error-action
    :initform "unknown"
    :type string
    :documentation "The requested action or tool invocation (e.g. write_file).")
   (resource
    :initarg :resource
    :reader denied-error-resource
    :initform "unknown"
    :type string
    :documentation "The target resource filepath or command line on which the action was attempted."))
  (:report (lambda (condition stream)
             (format stream "Denied Error: Access denied for action ~S on resource ~S.~%~
                             What failed: Tool permission check.~%~
                             Why: ~A~%~
                             Where: CLOS wildcard permission evaluation engine."
                     (denied-error-action condition)
                     (denied-error-resource condition)
                     (denied-error-message condition))))
  (:documentation "Signal that a tool action was rejected by the permission ruleset policy."))
