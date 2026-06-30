# librecode Developer Justfile
# Use inside the nix-shell environment for full dependency pathing.

# List all available recipes
default:
    @just --list

# Run the FiveAM and check-it test suite
test:
    sbcl --non-interactive \
         --eval '(require :asdf)' \
         --eval '(push (truename "./") asdf:*central-registry*)' \
         --eval '(asdf:test-system :librecode-test)'

# Verify compilation of all librecode systems
build:
    sbcl --non-interactive \
         --eval '(require :asdf)' \
         --eval '(push (truename "./") asdf:*central-registry*)' \
         --eval '(asdf:load-system :librecode-runner)' \
         --eval '(asdf:load-system :librecode-meta)'

# Run compiler lint checks (fails on warnings/errors within librecode files)
lint:
    sbcl --non-interactive \
         --eval '(require :asdf)' \
         --eval '(push (truename "./") asdf:*central-registry*)' \
         --eval '(handler-bind ((warning (lambda (c) \
                                           (when (and *compile-file-pathname* \
                                                      (search "/librecode/" (namestring *compile-file-pathname*))) \
                                             (format *error-output* "~&[LINT] Warning in ~A:~%~A~%" *compile-file-pathname* c) \
                                             (uiop:quit 1))))) \
                   (asdf:load-system :librecode-runner) \
                   (asdf:load-system :librecode-meta))'


# Start an interactive SBCL REPL with all packages loaded
repl:
    rlwrap sbcl --eval '(require :asdf)' \
                --eval '(push (truename "./") asdf:*central-registry*)' \
                --eval "(handler-bind ((warning #'muffle-warning)) (asdf:load-system :librecode-runner) (asdf:load-system :librecode-meta))"

# Clean system fasl compiler caches
clean:
    rm -rf ~/.cache/common-lisp/sbcl-*$(pwd)*

# Start the HTTP server bridge on specified PORT
run port="4096":
    sbcl --eval '(require :asdf)' \
         --eval '(push (truename "./") asdf:*central-registry*)' \
         --eval "(handler-bind ((warning #'muffle-warning)) (asdf:load-system :librecode-runner))" \
         --eval '(librecode-runner.http:start-http-bridge :port {{port}})' \
         --eval '(progn (format t "Server listening on port {{port}}...~%") (force-output))' \
         --eval '(loop (sleep 1))'


