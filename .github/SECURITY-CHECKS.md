# Repository security checks

`codeql.yml` runs on pull requests to `main`, pushes to `main`, and weekly.
CodeQL scans GitHub Actions workflows. Semgrep Community Edition scans the
app's Swift source with the public `p/swift` rules and uploads SARIF results
to GitHub code scanning. It runs locally on the Actions runner, without a
Semgrep account or source upload; usage metrics are disabled.

Jibiji uses iOS 27 PencilKit APIs. GitHub currently does not support CodeQL
traced builds with Xcode 27 or Swift 6.4, and Swift has no build-free CodeQL
mode. Building with Xcode 26 instead fails because those APIs are absent.
See [GitHub's compatibility announcement](https://github.blog/changelog/2026-10-19-codeql-changes-for-macos-27-xcode-27-and-swift-6-4/).
The Swift scan uses Semgrep's community rules, rather than CodeQL's Swift
queries or Semgrep's paid cross-file analysis. Revisit CodeQL Swift analysis
when GitHub adds support for Jibiji's toolchain.

Dependabot checks Actions and the pinned scanner dependency every Monday.
It opens update PRs for review; updates are not automatically merged.
Dependabot alerts and security updates are also enabled in repository settings.
The vendored ONNX Runtime package requires manual updates, as described in
[Vendor/README.md](../Vendor/README.md).
