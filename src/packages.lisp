;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; packages.lisp — Namespace layouts for librecode modules
;;;

(in-package :cl-user)

(eval-when (:compile-toplevel :load-toplevel :execute)
  #+sbcl (require :sb-concurrency))

(defpackage #:librecode-runner.conditions
  (:use #:cl)
  (:documentation "Custom serious conditions for error handling and recovery in the librecode execution harness.")
  (:export #:harness-failure
           #:harness-failure-exit-code
           #:harness-failure-message
           #:harness-failure-process-id
           
           #:provider-error
           #:provider-error-message
           #:provider-error-endpoint
           #:provider-error-provider
           
           #:context-overflow
           #:context-overflow-message
           #:context-overflow-budget
           #:context-overflow-requested
           
           #:tool-timeout
           #:tool-timeout-message
           #:tool-timeout-tool-id
           #:tool-timeout-duration
           
           #:process-hang
           #:process-hang-message
           #:process-hang-process-id
           
           #:protocol-invariant-violation
           #:protocol-invariant-violation-message
           #:protocol-invariant-violation-invariant
           
           #:gate-failure
           #:gate-failure-message
           #:gate-failure-command
           #:gate-failure-exit-code
           
           #:denied-error
           #:denied-error-message
           #:denied-error-action
           #:denied-error-resource
           
           ;; Restarts
           #:retry-with-backup-provider
           #:compact-and-retry
           #:skip-and-continue
           #:retry-tool))

(defpackage #:librecode-runner.audit
  (:use #:cl)
  (:documentation "Thread-safe, append-only S-expression and JSONL audit trail logging.")
  (:export #:write-audit-event
           #:start-audit-logger
           #:stop-audit-logger
           #:init-audit-logger
           #:shutdown-audit-logger))

(defpackage #:librecode-runner.protocol
  (:use #:cl)
  (:documentation "Event loop, run coordinator with wake coalescing, and mailbox messaging.")
  (:export #:run-coordinator
           #:wake-session
           #:interrupt-session
           #:session-stopping-p
           #:make-mailbox
           #:send-message
           #:receive-message
           #:flush-mailbox
           #:*session-mailbox*
           #:*active-worker-mailboxes*
           #:register-worker-mailbox
           #:unregister-worker-mailbox
           #:*active-worker-threads*
           #:*active-worker-threads-lock*
           #:register-worker-thread
           #:unregister-worker-thread
           #:*event-broadcast-hook*
           #:broadcast-event
           #:join-thread-with-timeout
           #:with-session-context-captured
           #:failure-relay
           #:with-failure-relay
           #:failure-descriptor
           #:failure-descriptor-type
           #:failure-descriptor-message
           #:failure-descriptor-initargs
           #:condition-to-descriptor
           #:descriptor-to-condition))

(defpackage #:librecode-runner.event-store
  (:use #:cl)
  (:documentation "Durable event sourcing and SQLite integration.")
  (:export #:init-db
           #:connect-db
           #:with-transaction
           #:with-immediate-transaction
           #:commit-event
           #:apply-projectors
           #:*workspace-root*
           #:*db*
           #:alist-p
           #:plist-p))

(defpackage #:librecode-runner.agent
  (:use #:cl)
  (:documentation "CLOS-based agent models and rule/permission enforcement.")
  (:export #:agent
           #:agent-id
           #:agent-ruleset
           #:agent-system-context
           #:permission-rule
           #:make-permission-rule
           #:permission-rule-action
           #:permission-rule-resource
           #:permission-rule-effect
           #:evaluate-permissions
           #:check-permission
           #:*interactive-p*
           #:*current-session-id*
           #:*project-id*
           #:resolve-permission-request
           #:*pending-requests*
           #:*pending-requests-lock*
           #:permission-request
           #:permission-request-id
           #:permission-request-action
           #:permission-request-resource
           #:permission-request-decision
           #:permission-request-resolved-p))

(defpackage #:librecode-runner.session
  (:use #:cl)
  (:documentation "Session state representation, turn loop status, and two-phase input admission.")
  (:export #:session
           #:session-id
           #:session-state
           #:admit-input
           #:promote-input
           #:promote-pending-inputs))

(defpackage #:librecode-runner.runner
  (:use #:cl #:librecode-runner.conditions)
  (:documentation "LLM turn execution, provider interfacing, and SSE streaming.")
  (:export #:execute-provider-turn
           #:*backup-provider-url*
           #:*worker-marker*))

(defpackage #:librecode-runner.compaction
  (:use #:cl)
  (:documentation "Context compaction engine and baseline resets.")
  (:export #:compact-context))

(defpackage #:librecode-runner.tool
  (:use #:cl)
  (:documentation "Tool registry, capability filtering, and settlement.")
  (:export #:tool
           #:tool-name
           #:tool-description
           #:tool-parameters
           #:tool-capabilities
           #:tool-handler
           #:tool-registry
           #:register-tool
           #:materialize-tools
           #:execute-tool
           #:execute-tool-async
           #:deep-merge-plists))

(defpackage #:librecode-runner.http
  (:use #:cl)
  (:documentation "HTTP server bridge for remote control and SSE coordination.")
  (:export #:start-http-bridge
           #:stop-http-bridge
           #:*max-compact-attempts*))

;; --- metaharness layer ---

(defpackage #:librecode-meta.multiplexer
  (:use #:cl)
  (:documentation "Abstract terminal multiplexer management protocol.")
  (:export #:multiplexer
           #:mux-create-session
           #:mux-send-command
           #:mux-kill-session))

(defpackage #:librecode-meta.multiplexer-tmux
  (:use #:cl)
  (:documentation "Tmux-specific implementation of the terminal multiplexer protocol.")
  (:export #:tmux-multiplexer))

(defpackage #:librecode-meta.harness
  (:use #:cl)
  (:documentation "Supervised child harness interface.")
  (:export #:harness
           #:harness-spawn
           #:harness-destroy
           #:harness-inject-conditioning))

(defpackage #:librecode-meta.harness-opencode
  (:use #:cl)
  (:documentation "Adapter for spawning and interacting with external OpenCode TypeScript harnesses.")
  (:export #:opencode-harness))

(defpackage #:librecode-meta.harness-librecode
  (:use #:cl)
  (:documentation "Adapter for spawning and interacting with self-hosted librecode-runner child harnesses.")
  (:export #:librecode-harness))

(defpackage #:librecode-meta.campaign
  (:use #:cl)
  (:documentation "Campaign scheduler, DAG execution engine, and progress realigner.")
  (:export #:campaign
           #:campaign-dag
           #:run-campaign))

(defpackage #:librecode-meta.gate
  (:use #:cl)
  (:documentation "Campaign validation gate DSL and subprocess runner.")
  (:export #:run-gate
           #:defgate))

(defpackage #:librecode-meta.council
  (:use #:cl)
  (:documentation "Multi-seat council coordination, assent verification, and consensus rule evaluation.")
  (:export #:council
           #:convene-council
           #:validate-assent))

(defpackage #:librecode-meta.conditioning
  (:use #:cl)
  (:documentation "Persona layout compilation and prompt delivery hooks.")
  (:export #:compose-conditioning))

(defpackage #:librecode-meta.metaharness
  (:use #:cl)
  (:documentation "Metaharness orchestrator entry point, campaign loop supervisor, and signal gates.")
  (:export #:start-metaharness
           #:stop-metaharness))
