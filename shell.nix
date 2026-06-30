{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    # Compiler & Lisp environment
    sbcl
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
    echo "  Loaded: SBCL, SQLite, Ncurses, OpenSSL, Nickel, Tmux"
    echo "====================================================="
  '';
}
