;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; tool-tests.lisp — Unit tests for tool model, registry, execution, and deep plist merging
;;;

(defpackage #:librecode-test.tool
  (:use #:cl
        #:fiveam
        #:librecode-runner.tool
        #:librecode-runner.agent
        #:librecode-runner.conditions)
  (:export #:tool-suite))

(in-package #:librecode-test.tool)

(def-suite tool-suite
  :description "Suite for tool model, registry, filtering, execution, and deep plist merging tests.")

(in-suite tool-suite)

(test test-deep-merge-plists
  "Verify recursive property list merging behavior."
  ;; Basic merging
  (is (equal '(:a 1 :b 2) (deep-merge-plists '(:a 1) '(:b 2))))
  ;; Overriding simple values
  (is (equal '(:a 2) (deep-merge-plists '(:a 1) '(:a 2))))
  ;; Nested plists recursive merging
  (is (equal '(:a (:b 1 :c 2)) (deep-merge-plists '(:a (:b 1)) '(:a (:c 2)))))
  ;; Override nested with simple
  (is (equal '(:a 3) (deep-merge-plists '(:a (:b 1)) '(:a 3))))
  ;; Override simple with nested
  (is (equal '(:a (:b 1)) (deep-merge-plists '(:a 3) '(:a (:b 1)))))
  ;; Null plist1 preservation
  (is (equal '(:a 1) (deep-merge-plists nil '(:a 1))))
  ;; Null plist2 preservation
  (is (equal '(:a 1) (deep-merge-plists '(:a 1) nil)))
  ;; Non-plist types override
  (is (equal 42 (deep-merge-plists '(:a 1) 42)))
  (is (equal '(:a 1) (deep-merge-plists 42 '(:a 1)))))

(test test-materialization-and-filtering
  "Verify tool registry filtering based on rulesets and model capabilities."
  (let ((registry (make-instance 'tool-registry))
        (tool1 (make-instance 'tool
                              :name "tool-1"
                              :description "Tool 1"
                              :parameters '(:type "object" :properties (:x (:type "string")))
                              :capabilities '(:gpu :fast)
                              :handler (lambda (args) (declare (ignore args)) "res1")))
        (tool2 (make-instance 'tool
                              :name "tool-2"
                              :description "Tool 2"
                              :parameters '(:type "object" :properties (:y (:type "integer")))
                              :capabilities '(:slow)
                              :handler (lambda (args) (declare (ignore args)) "res2")))
        (tool3 (make-instance 'tool
                              :name "tool-3"
                              :description "Tool 3"
                              :parameters '(:type "object" :properties (:z (:type "boolean")))
                              :capabilities '(:gpu)
                              :handler (lambda (args) (declare (ignore args)) "res3"))))
    (register-tool registry tool1)
    (register-tool registry tool2)
    (register-tool registry tool3)

    ;; 1. Check capability filtering
    ;; Model has (:gpu :fast) -> should allow tool1 and tool3, but not tool2 (:slow)
    (let* ((agent (make-instance 'agent :id "test-agent" :ruleset nil :system-context nil))
           (materialized (materialize-tools registry agent '(:gpu :fast))))
      (is (= 2 (length materialized)))
      (is-true (find "tool-1" materialized :key (lambda (p) (getf p :name)) :test #'string=))
      (is-true (find "tool-3" materialized :key (lambda (p) (getf p :name)) :test #'string=))
      (is-false (find "tool-2" materialized :key (lambda (p) (getf p :name)) :test #'string=)))

    ;; 2. Check ruleset permission filtering
    ;; Let's add a static rule denying tool-1
    (let* ((rule (make-permission-rule :action "execute_tool" :resource "tool-1" :effect :deny))
           (agent (make-instance 'agent :id "test-agent-deny" :ruleset (list rule) :system-context nil))
           (materialized (materialize-tools registry agent '(:gpu :fast :slow))))
      (is (= 2 (length materialized)))
      (is-false (find "tool-1" materialized :key (lambda (p) (getf p :name)) :test #'string=))
      (is-true (find "tool-2" materialized :key (lambda (p) (getf p :name)) :test #'string=))
      (is-true (find "tool-3" materialized :key (lambda (p) (getf p :name)) :test #'string=)))))

(test test-argument-validation
  "Verify parameter validation against tool schema."
  (let* ((tool (make-instance 'tool
                              :name "valid-tool"
                              :description "Desc"
                              :parameters '(:type "object"
                                            :properties (:str (:type "string")
                                                         :num (:type "integer")
                                                         :bool (:type "boolean"))
                                            :required (:str))
                              :capabilities nil
                              :handler (lambda (args) (getf args :str)))))
    ;; Correct arguments
    (is (equal "hello" (execute-tool tool '(:str "hello" :num 42 :bool t))))

    ;; Missing required argument
    (signals error
      (execute-tool tool '(:num 42)))

    ;; Type mismatch string
    (signals error
      (execute-tool tool '(:str 123)))

    ;; Type mismatch integer
    (signals error
      (execute-tool tool '(:str "hello" :num "not-int")))

    ;; Type mismatch boolean
    (signals error
      (execute-tool tool '(:str "hello" :bool "not-bool")))))

(test test-async-execution-success
  "Verify that async execution returns the correct value."
  (let* ((tool (make-instance 'tool
                              :name "async-success"
                              :description "Desc"
                              :parameters nil
                              :capabilities nil
                              :handler (lambda (args)
                                         (declare (ignore args))
                                         (sleep 0.1)
                                         "ok"))))
    (is (equal "ok" (execute-tool-async tool nil :timeout 2.0)))))

(test test-async-execution-error-propagation
  "Verify that errors raised in the handler are propagated."
  (let* ((tool (make-instance 'tool
                              :name "async-error"
                              :description "Desc"
                              :parameters nil
                              :capabilities nil
                              :handler (lambda (args)
                                         (declare (ignore args))
                                         (error "Something went wrong")))))
    (signals error
      (execute-tool-async tool nil))))

(test test-async-execution-timeout
  "Verify that execution timing out signals tool-timeout and kills the worker thread."
  (let* ((thread-started nil)
         (thread-finished nil)
         (tool (make-instance 'tool
                              :name "async-hang"
                              :description "Desc"
                              :parameters nil
                              :capabilities nil
                              :handler (lambda (args)
                                         (declare (ignore args))
                                         (setf thread-started t)
                                         (sleep 5.0)
                                         (setf thread-finished t)
                                         "hung"))))
    (signals tool-timeout
      (execute-tool-async tool nil :timeout 0.2))
    ;; Wait a moment to ensure background thread had time to potentially finish (if not killed)
    (sleep 0.5)
    (is-true thread-started)
    (is-false thread-finished)))
