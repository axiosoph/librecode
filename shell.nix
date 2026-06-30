{ pkgs ? import <nixpkgs> {} }:

let
  sbclEnv = pkgs.sbcl.withPackages (ps: with ps; [
    bordeaux-threads
    sqlite
    com_dot_inuoe_dot_jzon
    dexador
    hunchentoot
    clack
    fiveam
    trivial-signal
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
    tmux
    nickel
  ];

  shellHook = ''
    export PREDICATE_PLUGIN_SRC="/var/home/nrd/.gemini/antigravity-cli/plugins/predicate"
    # Ensure CFFI finds system libraries in Nix environments
    export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath (with pkgs; [ sqlite ncurses openssl ])}:$LD_LIBRARY_PATH"
    
    echo "====================================================="
    echo "  librecode Development Shell"
    echo "====================================================="
  '';
}
