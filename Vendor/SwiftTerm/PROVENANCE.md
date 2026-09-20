SwiftTerm v1.13.0, commit 8e7a1e154f470e19c709a00a8768df348ba5fc43
https://github.com/migueldeicaza/SwiftTerm
MIT license in LICENSE. Sources copied unchanged. Package.swift is reduced to the macOS library target to avoid fetching upstream benchmark, CLI, and documentation dependencies. Vendored for reproducible offline builds.

Shader source is copied as a resource instead of precompiled, using SwiftTerm’s existing runtime shader compilation fallback. This avoids a separate Xcode Metal Toolchain download.
