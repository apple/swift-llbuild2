with import <nixpkgs> { }; mkShell.override { stdenv = swift.stdenv; } {
  LD_LIBRARY_PATH = "${swiftPackages.Dispatch}/lib";

  buildInputs = with swiftPackages;[
    lldb
    swift
    swiftpm
    Foundation
    Dispatch
    XCTest
    zlib
    sourcekit-lsp
  ];
}
