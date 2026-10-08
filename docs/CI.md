# MacTerm CI/CD

Same kit as `oknedz/trading`, specialised for a single-platform macOS app. Everything
runs on the `xcode-27` runner (macOS 27, Apple Silicon).

## What runs

| File | Trigger | Does |
| --- | --- | --- |
| `.github/workflows/ci.yml` | push to `main`, PRs targeting `main` | `test` job: `mactermTests`. Then `build` job: Debug **and** Release |
| `.github/workflows/release.yml` | push tag `v*` | builds Release, packages `MacTerm-Release.dmg`, publishes a GitHub release |
| `.github/workflows/lint-workflows.yml` | PRs/pushes touching `.github/**` | `actionlint` + `zizmor` on the workflow files, with pinned versions and checksums |
| `.github/workflows/auto-pr.yml` | push to `feature/**`, `fix/**`, `refactor/**`, `chore/**`, `docs/**` | opens a PR against `main` |
| `.github/CODEOWNERS` | — | `* @oknedz`; inert until code-owner review is required |
| `.github/PULL_REQUEST_TEMPLATE.md` | — | what changed, how it was verified, risk/rollback, checklist |

`ci.yml` is a chain, not a fan-out: tests gate the build, so a broken test costs one
job instead of two. `lint-workflows.yml` is path-filtered, so it produces **no** check run
on a code-only PR — do not add it to required status checks without removing the `paths:`
filters in the same change.

**Artifacts stay on GitHub.** The release job uploads `MacTerm-Release.dmg` as a workflow
artifact (14-day retention) and, on a tag push, attaches it to the GitHub release. Nothing
in any workflow downloads a build to a machine — you fetch it from the artifact list or the
release page when you want it. There is no `download-artifact` step anywhere in this repo:
the build and the publish happen in one job, so there is nothing to hand across.

## Local gate — the same commands

```sh
cd macterm
xcodegen generate
xcodebuild build -project macterm.xcodeproj -scheme macterm -configuration Debug   -destination 'platform=macOS'
xcodebuild build -project macterm.xcodeproj -scheme macterm -configuration Release -destination 'platform=macOS'
xcodebuild test  -project macterm.xcodeproj -scheme mactermTests                  -destination 'platform=macOS'
```

Release packaging — the script the release job runs, unchanged:

```sh
scripts/package-release.sh [output-dir]   # default: dist

```

**The `xcode-27` image ships without the Metal toolchain.** SwiftTerm compiles Metal
shaders (`Sources/SwiftTerm/Apple/Metal`), so the build and release jobs run
`xcodebuild -downloadComponent MetalToolchain` first. Without it the build fails with
`cannot execute tool 'metal' due to missing Metal Toolchain`. The test job does not need
it — `mactermTests` compiles no Swift.

Linting the workflows the way CI does:

```sh
# The same ignore the lint job passes — actionlint's runner-label list predates xcode-27.
actionlint -ignore 'label "xcode-27" is unknown' .github/workflows/*.yml
```

## Things that will bite you

- **The runner cannot be `macos-latest`.** The vendored `Package.swift` declares
  `swift-tools-version:6.2`, so an older image fails at package resolution, not at compile
  time. `xcode-27` is public preview — if GitHub retires the label, this repo is the thing
  that breaks first.
- **`macterm.xcodeproj` is generated.** Never edit it by hand and never trust the
  committed copy: CI runs `xcodegen generate` before every build, so a stale committed
  project cannot hide a broken `project.yml`.
- **`SwiftTermVendor/` is a local fork, not upstream.** It is vendored in-repo and
  referenced by `path: SwiftTermVendor`. It has diverged heavily from
  `migueldeicaza/SwiftTerm`, so repointing the package at the remote URL will not build
  the same terminal.
- **`mactermTests` is a host-less logic-test bundle.** It compiles `Glass/*` and
  `Views/LiquidGlassAlgorithmSettingsView.swift` directly, so tests must not
  `@testable import macterm` — the app module is not a dependency of the test target.
  Adding the import back fails the build with
  `Unable to resolve module dependency: 'macterm'`.
- **Package versions are pinned.** CI passes `-onlyUsePackageVersionsFromResolvedFile`
  against `macterm.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
  After changing dependencies in `project.yml`, build locally and commit the updated
  `Package.resolved` or CI refuses to resolve.
- **No `swift` entry in dependabot**, on purpose: the Swift ecosystem reads a
  `Package.swift`, this project has none, and an entry pointed at `SwiftTermVendor/`
  would start bumping the fork's manifest behind your back.
- **Signing is ad-hoc** (`CODE_SIGN_IDENTITY: "-"`), so release builds need no certificate
  or secret. Not notarised and not hardened-runtime enabled — the DMG will open with a
  Gatekeeper warning on a machine that has not seen this build before.
- **Caching** keys on `project.yml`, every `.swift` file, and `Package.resolved`. Bump
  `CACHE_EPOCH` in `ci.yml` to invalidate without a source change.
- **Branch protection is unavailable.** Both this repo and `trading` are private on a plan
  where the API answers `403 Upgrade to GitHub Pro` for `/branches/main/protection`, so
  `CODEOWNERS` is inert and nothing blocks a red PR from merging. It goes live the moment
  the plan or visibility allows it — no file change needed.

## Cutting a release

```sh
git tag v1.0.0 && git push origin v1.0.0
```

A tag containing `-` (e.g. `v1.0.0-rc.1`) is published as a prerelease.