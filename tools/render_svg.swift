#!/usr/bin/env swift
// Render an SVG to a PNG at an exact pixel size.
//
// Every platform icon except HarmonyOS has to be a bitmap, so changing the mark
// means regenerating 20-odd files. This is the one step that has to run on a
// Mac. It deliberately does not shell out to Chrome: headless Chrome wants its
// own profile directory and is frequently blocked in sandboxed sessions, while
// AppKit renders an SVG with no extra setup.
//
//   swift tools/render_svg.swift assets/app-icon.svg /tmp/icon.png 1024
//
// Sizes used by this repository:
//   iOS app icon            1024
//   iOS launch screen       2732
//   Android launcher        48 / 72 / 96 / 144 / 192
//   Android adaptive layers 108 / 162 / 216 / 324 / 432
//   Android splash mark     96 / 144 / 192 / 288 / 384

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: render_svg <in.svg> <out.png> <size>\n".data(using: .utf8)!)
    exit(1)
}
let inPath = args[1]
let outPath = args[2]
guard let size = Int(args[3]), size > 0 else {
    FileHandle.standardError.write("size must be a positive integer\n".data(using: .utf8)!)
    exit(1)
}
guard let image = NSImage(contentsOfFile: inPath) else {
    FileHandle.standardError.write("cannot load \(inPath)\n".data(using: .utf8)!)
    exit(2)
}
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else {
    FileHandle.standardError.write("cannot allocate a \(size)x\(size) bitmap\n".data(using: .utf8)!)
    exit(3)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
NSGraphicsContext.current?.shouldAntialias = true
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG encoding failed\n".data(using: .utf8)!)
    exit(4)
}
try data.write(to: URL(fileURLWithPath: outPath))
print("\(outPath)  \(size)x\(size)")
