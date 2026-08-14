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

func generate() throws {
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
}

do {
    try generate()
} catch {
    fputs("Icon generation failed: \(error)\n", stderr)
    exit(1)
}
