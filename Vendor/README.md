# Vendored packages

## onnxruntime-swift-package-manager

Microsoft's ONNX Runtime Swift package, copied unchanged from upstream
commit `b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2` (tag `1.24.2`, MIT
licensed; see its `LICENSE`). Upstream CI configuration (`.github`,
`.pipelines`, `.config`) was left out.

The upstream repository, `github.com/microsoft/onnxruntime-swift-package-manager`,
started returning "Repository not found" in November 2026, so clean
checkouts and CI could no longer resolve the package. The ONNX Runtime
binaries themselves are still downloaded at build time from
`download.onnxruntime.ai`, pinned by the SHA-256 checksums in
`Package.swift`.

To upgrade, replace this folder with a newer release (including the new
binary URLs and checksums) and rebuild. Dependabot does not track this
copy, so check ONNX Runtime releases by hand.
