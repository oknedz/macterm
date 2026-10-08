# MacTerm CI/CD

Two workflows, both on the `xcode-27` runner (macOS 27 / Apple Silicon).

## What runs

| Workflow | Trigger | Does |
| --- | --- | --- |
| `.github/workflows/ci.yml` | push to `main`, any pull request, manual | builds `macterm` in Debug **and** Release, runs the `mactermTests` unit tests |
| `.github/workflows/release.yml` | push tag `v*`, manual | builds Release, packages `dist/MacTerm-Release.dmg`, uploads it as a build artifact, and on a tag push publishes a GitHub release |

`ci.yml` jobs are independent: `build` and `test` run in parallel and the PR is red if either fails.

## Local gate — run the same thing

```sh
cd macterm
xcodegen generate
xcodebuild build -project macterm.xcodeproj -scheme macterm -configuration Debug -destination 'platform=macOS'
xcodebuild test  -project macterm.xcodeproj -scheme mactermTests -destination 'platform=macOS'
```

Release packaging:

```sh
scripts/package-release.sh [output-dir]   # default: dist
```

## Things that will bite you

- **`macterm.xcodeproj` is generated.** Never edit it by hand and never trust the
  committed copy: `xcodegen generate` overwrites it from `project.yml`. CI
  regenerates before every build, so a stale committed project cannot hide a
  broken `project.yml`.
- **`SwiftTermVendor/` is a local fork, not upstream.** It is vendored in-repo and
  referenced by `path: SwiftTermVendor` in `project.yml`. It has diverged heavily
  from `migueldeicaza/SwiftTerm` (see `diff -rq` against upstream `HEAD`), so
  repointing the package at the remote URL will not build the same terminal.
- **The vendored `Package.swift` declares `swift-tools-version:6.2`**, which is
  why the runner must be `xcode-27`. An older image fails at package resolution,
  not at compile time.
- **`mactermTests` is a host-less logic-test bundle.** It compiles `Glass/*` and
  `Views/LiquidGlassAlgorithmSettingsView.swift` directly, so tests must not
  `@testable import macterm` — the app module is not a dependency of the test
  target. Adding the import back breaks the build with
  `Unable to resolve module dependency: 'macterm'`.
- **Package versions are pinned.** CI passes
  `-onlyUsePackageVersionsFromResolvedFile` against the committed
  `macterm.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
  After changing `project.yml` dependencies, run a build locally and commit the
  updated `Package.resolved` or CI will refuse to resolve.
- **Signing is ad-hoc** (`CODE_SIGN_IDENTITY: "-"`), so release builds need no
  certificate or secret.
- **Caching** keys on `project.yml`, every `.swift` file, and `Package.resolved`.
  Bump `CACHE_EPOCH` in `ci.yml` if you need to invalidate without a source change.

## Cutting a release

```sh
git tag v1.0.0 && git push origin v1.0.0
```

That triggers `release.yml`, which attaches `MacTerm-Release.dmg` to a GitHub
release for that tag.