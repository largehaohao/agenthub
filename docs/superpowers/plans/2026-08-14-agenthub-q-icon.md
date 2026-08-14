# AgentHub Q Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a custom Orbit Q application icon and a monochrome Q status-item icon to AgentHub, then build and launch the macOS app.

**Architecture:** Keep the artwork static and deterministic. A small CoreGraphics renderer produces the PNG sizes consumed by an Xcode asset catalog; the app icon is selected through XcodeGen, while `MenuBarController` loads a separate transparent asset and marks it as a template image. Quota, panel, and refresh code remain unchanged.

**Tech Stack:** Swift 6, AppKit/CoreGraphics, ImageIO, XCTest, XcodeGen, Xcode asset catalogs, macOS 14+.

**Spec:** `docs/superpowers/specs/2026-08-14-agenthub-q-icon-design.md`

---

## Global Constraints

- Keep the deployment target at macOS 14.0 and Swift strict concurrency settings unchanged.
- The application icon is the Orbit Q design: warm light-gray rounded-square background, graphite Q, and four fixed provider-color dots.
- The menu bar image is transparent, monochrome, and marked as an AppKit template image.
- Do not change quota readers, quota presentation, refresh timing, or panel behavior.
- Generated PNGs must be reproducible by a committed renderer script; do not hand-edit binary assets.
- Every implementation task ends with the relevant test or build command passing before its commit.

## File Structure

**Create**

| File | Responsibility |
|---|---|
| `scripts/generate-icon-assets.swift` | Deterministically renders the Orbit Q artwork into PNGs. |
| `App/Resources/Assets.xcassets/Contents.json` | Declares the asset catalog. |
| `App/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` | Maps macOS app-icon slots to generated PNGs. |
| `App/Resources/Assets.xcassets/MenuBarQ.imageset/Contents.json` | Maps 1x/2x monochrome status-item PNGs and declares template rendering. |
| `App/Resources/Assets.xcassets/AppIcon.appiconset/*.png` | Generated Finder/Launchpad/application icon sizes. |
| `App/Resources/Assets.xcassets/MenuBarQ.imageset/*.png` | Generated 18-point menu bar assets. |
| `Tests/AgentHubAppTests/IconResourceTests.swift` | Verifies that the compiled app bundle contains the menu bar asset. |

**Modify**

| File | Responsibility |
|---|---|
| `project.yml` | Includes `App/Resources` and selects `AppIcon` as the target application icon. |
| `App/MenuBar/MenuBarController.swift` | Loads `MenuBarQ` with the existing SF Symbol as a concrete fallback. |

---

### Task 1: Add the resource regression test

**Files:**
- Create: `Tests/AgentHubAppTests/IconResourceTests.swift`

- [ ] **Step 1: Write the failing resource test**

Create the test below. It asks the app target's bundle for `MenuBarQ`, so it
will fail before the resource catalog exists and will pass once Xcode compiles
the asset into the application bundle.

```swift
import AppKit
import XCTest
@testable import AgentHubApp

@MainActor
final class IconResourceTests: XCTestCase {
    func testMenuBarQAssetIsPresentInTheApplicationBundle() throws {
        let bundle = Bundle(for: AppDelegate.self)
        let image = try XCTUnwrap(
            NSImage(named: "MenuBarQ", in: bundle, compatibleWith: nil),
            "MenuBarQ must be compiled into the AgentHub application bundle"
        )

        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
xcodegen generate
xcodebuild -project AgentHub.xcodeproj -scheme AgentHubApp \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO \
  test -only-testing:AgentHubAppTests/IconResourceTests
```

Expected: the test target builds, then `IconResourceTests` fails because
`MenuBarQ` is not present yet.

- [ ] **Step 3: Keep the failing test uncommitted until the resource exists**

Do not commit the intentionally failing test yet. Carry it into Task 2, where
the generated assets and the passing focused test are committed together.

---

### Task 2: Generate the Orbit Q asset catalog

**Files:**
- Create: `scripts/generate-icon-assets.swift`
- Create: `App/Resources/Assets.xcassets/Contents.json`
- Create: `App/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `App/Resources/Assets.xcassets/MenuBarQ.imageset/Contents.json`
- Create: generated PNG files under both asset sets
- Modify: `Tests/AgentHubAppTests/IconResourceTests.swift` (included in the passing resource commit)
- Modify: `project.yml` (include resources and select `AppIcon`)

- [ ] **Step 1: Create the asset directories and catalog metadata**

From the repository root, create the directories and write these metadata files:

```bash
mkdir -p App/Resources/Assets.xcassets/AppIcon.appiconset \
  App/Resources/Assets.xcassets/MenuBarQ.imageset
```

`App/Resources/Assets.xcassets/Contents.json`:

```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

`App/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`:

```json
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

`App/Resources/Assets.xcassets/MenuBarQ.imageset/Contents.json`:

```json
{
  "images" : [
    { "filename" : "menubar-q.png", "idiom" : "mac", "scale" : "1x" },
    { "filename" : "menubar-q@2x.png", "idiom" : "mac", "scale" : "2x" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "template-rendering-intent" : "template"
  }
}
```

- [ ] **Step 2: Add the deterministic CoreGraphics renderer**

Create `scripts/generate-icon-assets.swift` with this complete implementation:

```swift
#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum GeneratorError: Error {
    case missingOutputDirectory
    case failedToCreateContext
    case failedToCreateImage
    case failedToCreateDestination(URL)
    case failedToWrite(URL)
}

guard CommandLine.arguments.count == 2 else {
    throw GeneratorError.missingOutputDirectory
}

let resourceRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let appIconDirectory = resourceRoot
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")
let menuBarDirectory = resourceRoot
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("MenuBarQ.imageset")

try FileManager.default.createDirectory(at: appIconDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: menuBarDirectory, withIntermediateDirectories: true)

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        colorSpace: colorSpace,
        components: [
            CGFloat((hex >> 16) & 0xff) / 255,
            CGFloat((hex >> 8) & 0xff) / 255,
            CGFloat(hex & 0xff) / 255,
            1
        ]
    )!
}

func makeContext(pixels: Int) throws -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw GeneratorError.failedToCreateContext
    }
    context.setShouldAntialias(true)
    return context
}

func render(
    logicalSize: CGFloat,
    pixels: Int,
    drawing: (CGContext) -> Void
) throws -> CGImage {
    let context = try makeContext(pixels: pixels)
    let scale = CGFloat(pixels) / logicalSize
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)
    drawing(context)
    guard let image = context.makeImage() else {
        throw GeneratorError.failedToCreateImage
    }
    return image
}

func drawQ(
    in context: CGContext,
    center: CGPoint,
    radius: CGFloat,
    lineWidth: CGFloat,
    stroke: CGColor,
    tailEnd: CGPoint
) {
    context.setStrokeColor(stroke)
    context.setLineWidth(lineWidth)
    context.setLineCap(.round)
    context.strokeEllipse(in: CGRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
    ))
    context.move(to: CGPoint(
        x: center.x + radius * 0.58,
        y: center.y + radius * 0.58
    ))
    context.addLine(to: tailEnd)
    context.strokePath()
}

func drawAppIcon(in context: CGContext) {
    let background = CGPath(
        roundedRect: CGRect(x: 42, y: 42, width: 940, height: 940),
        cornerWidth: 220,
        cornerHeight: 220,
        transform: nil
    )
    context.saveGState()
    context.addPath(background)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0xF3F0EC), color(0xC9C4C2)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 90, y: 60),
        end: CGPoint(x: 940, y: 970),
        options: []
    )
    context.restoreGState()

    let graphite = color(0x20232B)
    drawQ(
        in: context,
        center: CGPoint(x: 485, y: 448),
        radius: 261,
        lineWidth: 85,
        stroke: graphite,
        tailEnd: CGPoint(x: 837, y: 800)
    )

    let dots: [(CGPoint, CGColor)] = [
        (CGPoint(x: 256, y: 283), color(0xE87950)),
        (CGPoint(x: 709, y: 256), color(0x67A7F4)),
        (CGPoint(x: 757, y: 624), color(0xAD80EF)),
        (CGPoint(x: 283, y: 635), color(0x6AC184))
    ]
    for (center, dotColor) in dots {
        context.setFillColor(dotColor)
        context.fillEllipse(in: CGRect(
            x: center.x - 32,
            y: center.y - 32,
            width: 64,
            height: 64
        ))
    }
}

func drawMenuBarQ(in context: CGContext) {
    drawQ(
        in: context,
        center: CGPoint(x: 8.2, y: 7.7),
        radius: 5.7,
        lineWidth: 2.2,
        stroke: color(0x20232B),
        tailEnd: CGPoint(x: 15.4, y: 15.1)
    )
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw GeneratorError.failedToCreateDestination(url)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw GeneratorError.failedToWrite(url)
    }
}

let appIconSizes: [(String, Int, Int)] = [
    ("icon_16x16.png", 16, 1),
    ("icon_16x16@2x.png", 16, 2),
    ("icon_32x32.png", 32, 1),
    ("icon_32x32@2x.png", 32, 2),
    ("icon_128x128.png", 128, 1),
    ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png", 256, 1),
    ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png", 512, 1),
    ("icon_512x512@2x.png", 512, 2)
]

for (name, pointSize, scale) in appIconSizes {
    let image = try render(
        logicalSize: 1024,
        pixels: pointSize * scale,
        drawing: drawAppIcon(in:)
    )
    try writePNG(image, to: appIconDirectory.appendingPathComponent(name))
}

for (name, pixels) in [("menubar-q.png", 18), ("menubar-q@2x.png", 36)] {
    let image = try render(logicalSize: 18, pixels: pixels, drawing: drawMenuBarQ(in:))
    try writePNG(image, to: menuBarDirectory.appendingPathComponent(name))
}
```

- [ ] **Step 3: Generate and inspect the PNGs**

Run:

```bash
swift scripts/generate-icon-assets.swift App/Resources
file App/Resources/Assets.xcassets/AppIcon.appiconset/*.png \
  App/Resources/Assets.xcassets/MenuBarQ.imageset/*.png
```

Expected: ten app-icon PNGs and two menu bar PNGs are reported as valid PNG
images, with dimensions ranging from 16 x 16 through 1024 x 1024 for the app
icon and 18 x 18 / 36 x 36 for the menu bar image.

- [ ] **Step 4: Commit the generated resources**

```bash
git add scripts/generate-icon-assets.swift App/Resources \
  Tests/AgentHubAppTests/IconResourceTests.swift project.yml
git commit -m "feat: add Orbit Q icon assets"
```

---

### Task 3: Wire the asset catalog and replace the status symbol

**Files:**
- Modify: `App/MenuBar/MenuBarController.swift`

- [ ] **Step 1: Verify the generated project includes the resources**

Task 2 already adds `App/Resources` to the `AgentHubApp` target and sets
`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`. After `xcodegen generate`, verify
that the generated project contains an asset catalog build phase for
`Assets.xcassets`. Do not duplicate the resource configuration here.

```yaml
    sources:
      - App
    resources:
      - App/Resources
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.agenthub.app
        CODE_SIGN_ENTITLEMENTS: Config/AgentHubApp.entitlements
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_LSUIElement: YES
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
```

- [ ] **Step 2: Add a resource loader with a concrete fallback**

In `App/MenuBar/MenuBarController.swift`, replace the inline SF Symbol
assignment at the start of `install()`:

```swift
item.button?.image = NSImage(
    systemSymbolName: "gauge.with.dots.needle.33percent",
    accessibilityDescription: "AgentHub usage"
)
```

with:

```swift
item.button?.image = Self.menuBarImage()
```

Add this private helper before `revealPinned()`:

```swift
private static func menuBarImage() -> NSImage {
    if let image = NSImage(named: "MenuBarQ") {
        image.isTemplate = true
        image.accessibilityDescription = "AgentHub usage"
        return image
    }

    return NSImage(
        systemSymbolName: "gauge.with.dots.needle.33percent",
        accessibilityDescription: "AgentHub usage"
    )!
}
```

The fallback is only for a malformed or manually assembled bundle; normal
builds must resolve `MenuBarQ` from the asset catalog.

- [ ] **Step 3: Re-generate the project and run the focused test**

Run:

```bash
xcodegen generate
xcodebuild -project AgentHub.xcodeproj -scheme AgentHubApp \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO \
  test -only-testing:AgentHubAppTests/IconResourceTests
```

Expected: `IconResourceTests` passes and the generated project includes the
asset catalog under the AgentHub app target.

- [ ] **Step 4: Commit the integration**

```bash
git add App/MenuBar/MenuBarController.swift
git commit -m "feat: use the Q icon in the menu bar"
```

---

### Task 4: Run the full gate, build, launch, and verify the bundle

**Files:**
- Modify: none

- [ ] **Step 1: Run the repository gate**

Run:

```bash
zsh scripts/check.sh
```

Expected: Swift package tests, Xcode app tests, project generation, and source
rules all pass.

- [ ] **Step 2: Build the Debug app**

Run:

```bash
xcodegen generate
xcodebuild -project AgentHub.xcodeproj -scheme AgentHubApp \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **` and an app at
`.build/xcode/Build/Products/Debug/AgentHubApp.app`.

- [ ] **Step 3: Verify the compiled icon metadata**

Run:

```bash
plutil -p .build/xcode/Build/Products/Debug/AgentHubApp.app/Contents/Info.plist \
  | rg 'CFBundleIconName|CFBundleIdentifier|LSUIElement'
```

Expected: the output includes `AppIcon`, `com.agenthub.app`, and a true
`LSUIElement` value.

- [ ] **Step 4: Launch the app and verify the live status item**

Run:

```bash
open .build/xcode/Build/Products/Debug/AgentHubApp.app
pgrep -f '/AgentHubApp.app/Contents/MacOS/AgentHubApp'
```

Expected: the process is running without a Dock icon, and the menu bar shows
the monochrome Q. Hovering or clicking the item must still open the existing
quota panel; the panel's provider rows and controls must be unchanged.

- [ ] **Step 5: Inspect the final worktree**

Run:

```bash
git status --short
git diff --check
```

Expected: only the intended implementation commits are present and there are
no whitespace errors. Do not add `.build/`, generated Xcode project files, or
the ignored `.superpowers/` brainstorming session to a commit.
