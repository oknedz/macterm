# 2026-08-26 — macterm: Settings + Terminal + UI overhaul

## Request
User asked to (1) verify the app works, (2) make the Settings panel sophisticated and prominent (not "one slider + three color pickers"), and (3) make the UI look like a native Xcode app.

## Diagnosis (before code)
- Settings was a 380×440 sheet with only a font picker, size slider, and theme swatches — no categories, no color pickers, no persistence.
- Terminal only painted bg/fg; no caret color, no selection color, no ANSI palette, fixed cursor/scrollback → themes looked unfinished ("terminal doesn't work okay").
- `.windowStyle(.hiddenTitleBar)` hid the window traffic lights entirely (the 78pt spacer in `TitleBar` cleared nothing) → window couldn't be minimized/closed/zoomed with the mouse.

## Changes
- `Model/TerminalController.swift`: full settings model, UserDefaults persistence, per-theme color overrides (hex), theme resolution (`effectiveColor`), `appearanceSignature` for cheap live-apply gating, `terminalOptions()` builder, `openSettings()`, `resetAllSettings()`, `handleProcessExit` (honors close-on-exit). Dracula 16-color ANSI palette added.
- `Term/TerminalViewRepresentable.swift`: passes `TerminalOptions` at creation; `applyAppearance` pushes font, fg, bg (+opacity), caret, selection, option-as-meta, mouse reporting, backspace, bright colors, and `installColors` — reapplied on signature change.
- `Views/SettingsView.swift`: replaced sheet with `SettingsRoot` (`NavigationSplitView`: General / Appearance / Text / Terminal / Window), native `Form`s, 4 `ColorPicker`s, theme cards, opacity slider, live previews, reset button.
- `MacTermApp.swift`: added `Settings` scene, removed `appSettings` CommandGroup replacement + `.windowStyle(.hiddenTitleBar)`.
- `Views/MainGlassView.swift`: removed settings sheet; sidebar width now `controller.sidebarWidth`.
- `Views/TitleBar.swift`: gear → `controller.openSettings()`. (78pt leading spacer now correctly clears the visible traffic lights.)
- `Views/TerminalArea.swift`: padding now `controller.terminalPadding`.
- Setup (earlier in session): `.second-brain.json` + `task/` + `project-brain/SESSION.md`.

## Verification
- `xcodebuild -scheme macterm -configuration Debug` → **EXIT=0** (compiles + links; only a harmless AppIntents metadata note).
- Fixed 4 compile errors: `TerminalOptions` arg order, `static` member access (`themes`/`startupDirOptions`), `Color→NSColor` via `NSColor(Color)`.

## Not verified (needs user's machine)
- Visual appearance, traffic-light hit area, live settings apply, terminal resize reflow. Compile only.

## Uncommitted
- New/changed files are working-tree only (no commit — hard rule). SwiftTermVendor uncommitted edits left untouched.
