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

# Start an interactive SBCL REPL with all packages loaded
repl:
    rlwrap sbcl --eval '(require :asdf)' \
                --eval '(push (truename "./") asdf:*central-registry*)' \
                --eval '(asdf:load-system :librecode-runner)' \
                --eval '(asdf:load-system :librecode-meta)'

# Validate campaign ledger deposits and state reconciliation logs via Nickel
validate-ledger:
    nickel export .ledger/deposits/validate_deposits.ncl
    nickel export .ledger/state/reconcile_log.ncl

# Clean system fasl compiler caches
clean:
    rm -rf ~/.cache/common-lisp/sbcl-*$(pwd)*
