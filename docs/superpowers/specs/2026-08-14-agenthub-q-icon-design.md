# AgentHub Q Icon

**Status:** Approved
**Date:** 2026-08-14

## 1. Context

AgentHub is a macOS menu bar application. Its status item currently uses the
SF Symbol `gauge.with.dots.needle.33percent`, and the project has no custom
application icon asset catalog. The application needs a recognizable identity
built around an uppercase `Q` without changing its quota behavior.

## 2. Goals and non-goals

### Goals

- Give Finder, Launchpad, and the built application a custom AgentHub icon.
- Make the uppercase `Q` the dominant and unmistakable shape.
- Connect the icon to the four supported providers with four accent dots.
- Use a monochrome template variant in the menu bar so it works in both macOS
  menu bar appearances.
- Keep the implementation static and local to the app resources and status-item
  setup.

### Non-goals

- Changing the quota panel, provider colors, or refresh behavior.
- Adding icon customization or user-selectable themes.
- Using a colored image directly in the menu bar.
- Adding a new runtime drawing framework or external package.

## 3. Visual design

The selected direction is **Orbit Q**: a tactile, editorial badge with a large
graphite Q on a warm light background.

### Application icon

- Master artwork is square and rendered at 1024 x 1024 points/pixels.
- The background is a warm light gray, using a gentle gradient from `#F3F0EC`
  to `#C9C4C2`, inside a macOS-style rounded square.
- The Q is a thick dark graphite ring and diagonal tail, using `#20232B`.
- Four small circular dots sit around the Q without competing with its outline:
  Claude `#E87950`, Codex `#6AC184`, Cursor `#67A7F4`, and OpenCode `#AD80EF`.
- The Q remains readable when the icon is reduced to the smallest macOS icon
  size. No text other than the Q is present.

### Menu bar icon

- The menu bar asset is a transparent monochrome version of the Q silhouette.
- It omits the background and provider dots.
- It is loaded as an `NSImage` template image, allowing AppKit to apply the
  correct foreground color for light and dark menu bars.
- The asset is sized for the status item at 18 points with a 36-pixel @2x
  representation and keeps the Q's ring and tail open enough to survive the
  small display size.

## 4. Integration design

### Resources

Add an `App/Resources/Assets.xcassets` catalog containing:

- `AppIcon.appiconset` for the application icon sizes Xcode expects.
- `MenuBarQ.imageset` for the monochrome status-item image.

The XcodeGen project configuration will include `App/Resources` as application
resources and set `ASSETCATALOG_COMPILER_APPICON_NAME` to `AppIcon`.

### Status item

`MenuBarController.install()` will load `MenuBarQ` and set
`item.button?.image`. The image will be marked `isTemplate = true`; the existing
SF Symbol remains a concrete fallback if the resource cannot be loaded, so a
missing packaged resource cannot remove the status item entirely.

No quota model, panel, provider reader, or persistence code changes.

## 5. Data flow and failure behavior

The icon has no data flow and does not reflect live quota values. The four dots
are a fixed brand reference to the supported providers, not status indicators.

At launch, AppKit resolves the compiled asset catalog. If `MenuBarQ` is absent,
the status item falls back to the existing SF Symbol and continues to expose
all existing interactions. A failed icon load does not affect quota refreshes.

## 6. Verification

- Run `zsh scripts/check.sh` to execute package tests, app tests, project
  generation, and source checks.
- Run the documented Debug build with XcodeGen and no code signing.
- Open `.build/xcode/Build/Products/Debug/AgentHubApp.app`.
- Confirm the application launches as an `LSUIElement`, remains visible in the
  menu bar, and shows the monochrome Q rather than the SF Symbol.
- Confirm the built app bundle contains the compiled application icon asset.
- Confirm the quota panel still opens by hover, click, and the global hotkey.
