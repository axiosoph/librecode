{ pkgs ? import <nixpkgs> {} }:

let
  sbclEnv = pkgs.sbcl.withPackages (ps: with ps; [
    bordeaux-threads
    sqlite
    com_dot_inuoe_dot_jzon
    dexador
    hunchentoot
    clack
    clack-handler-hunchentoot
    fiveam
    check-it
    trivial-signal
    cl-jschema
  ]);
in
pkgs.mkShell {
  buildInputs = with pkgs; [
    # Compiler & Lisp environment
    sbclEnv
    rlwrap
    cl-launch

    # System libraries required by Lisp CFFI libraries
    sqlite
    ncurses
    openssl
    pkg-config

    # Developer tools & dependencies
    git
    just
    tmux
    nickel
  ];

  shellHook = ''
    export PREDICATE_PLUGIN_SRC="/var/home/nrd/.gemini/antigravity-cli/plugins/predicate"
    # Ensure CFFI finds system libraries in Nix environments
    export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath (with pkgs; [ sqlite ncurses openssl ])}:$LD_LIBRARY_PATH"
    
    sbcl() {
      local args=()
      for arg in "$@"; do
        if [ "$arg" = "(asdf:load-system :librecode-runner)" ]; then
          args+=("(progn (asdf:load-asd (merge-pathnames \"librecode.asd\" *default-pathname-defaults*)) (asdf:load-system :librecode-runner))")
        elif [ "$arg" = "(asdf:load-system :librecode-meta)" ]; then
          args+=("(progn (asdf:load-asd (merge-pathnames \"librecode.asd\" *default-pathname-defaults*)) (asdf:load-system :librecode-meta))")
        else
          args+=("$arg")
        fi
      done
      command sbcl "''${args[@]}"
    }
    
    echo "====================================================="
    echo "  librecode Development Shell"
    echo "====================================================="
  '';
}
