#!/usr/bin/env swift
//
// Renders a minimalist installer background for the DMG.
// Output: assets/dmg-background.png (640×400 — matches the DMG window).
// Rerun this whenever you tweak branding; check the PNG into git.
//
import AppKit
import CoreGraphics

let width:  CGFloat = 640
let height: CGFloat = 400

// Coordinates of the two icons set by create-dmg in scripts/make-dmg.sh.
// Both icons are centred on these points; create-dmg uses icon-size 110.
let appIconCentre = CGPoint(x: 165, y: 200)
let appsIconCentre = CGPoint(x: 475, y: 200)
let iconSize: CGFloat = 110

let image = NSImage(size: CGSize(width: width, height: height), flipped: true) { _ -> Bool in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
    let cs = CGColorSpaceCreateDeviceRGB()

    // 1) Background — almost-white gradient. macOS DMGs traditionally feel
    //    light & airy. Dark themes hide the Applications symlink icon.
    let bg = CGGradient(colorsSpace: cs, colors: [
        NSColor(red: 0.97, green: 0.98, blue: 0.99, alpha: 1).cgColor,
        NSColor(red: 0.90, green: 0.92, blue: 0.95, alpha: 1).cgColor
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg,
                          start: .zero,
                          end: CGPoint(x: 0, y: height),
                          options: [])

    let centred = NSMutableParagraphStyle()
    centred.alignment = .center

    // 2) Title with inline arrow.
    NSAttributedString(string: "Drag OpenMacStorage → Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 22, weight: .bold),
        .foregroundColor: NSColor.black.withAlphaComponent(0.88),
        .paragraphStyle: centred
    ]).draw(in: CGRect(x: 0, y: 36, width: width, height: 32))

    // 3) Subtitle / first-launch hint.
    NSAttributedString(string: "to install. macOS may warn on first launch — right-click → Open.", attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor.black.withAlphaComponent(0.50),
        .paragraphStyle: centred
    ]).draw(in: CGRect(x: 0, y: 75, width: width, height: 18))

    // 4) Solid arrow between the two icon slots.
    let arrowY = appIconCentre.y
    let xStart = appIconCentre.x + iconSize / 2 + 25      // ~245
    let xEnd   = appsIconCentre.x - iconSize / 2 - 25     // ~395

    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.40).cgColor)
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: xStart, y: arrowY))
    ctx.addLine(to: CGPoint(x: xEnd, y: arrowY))
    ctx.strokePath()

    // Arrow head (filled triangle).
    ctx.setFillColor(NSColor.black.withAlphaComponent(0.40).cgColor)
    ctx.beginPath()
    ctx.move(to:    CGPoint(x: xEnd + 10, y: arrowY))
    ctx.addLine(to: CGPoint(x: xEnd - 6,  y: arrowY - 9))
    ctx.addLine(to: CGPoint(x: xEnd - 6,  y: arrowY + 9))
    ctx.closePath()
    ctx.fillPath()

    // "drag" label hovering above the arrow.
    NSAttributedString(string: "drag", attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.black.withAlphaComponent(0.45),
        .paragraphStyle: centred
    ]).draw(in: CGRect(x: xStart, y: arrowY - 26,
                       width: xEnd - xStart, height: 16))

    // 5) Dashed placeholder behind the Applications symlink — a guaranteed
    //    visual landing zone even if Finder doesn't render the symlink icon
    //    on the first open (a known macOS+create-dmg quirk).
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.22).cgColor)
    ctx.setLineWidth(2)
    ctx.setLineDash(phase: 0, lengths: [6, 5])
    let box = CGRect(
        x: appsIconCentre.x - iconSize / 2,
        y: appsIconCentre.y - iconSize / 2,
        width: iconSize, height: iconSize
    )
    let path = CGPath(roundedRect: box,
                      cornerWidth: 18, cornerHeight: 18,
                      transform: nil)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    // 6) Footer credit line.
    NSAttributedString(string: "OpenMacStorage — free, open source, MIT licensed",
                       attributes: [
        .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
        .foregroundColor: NSColor.black.withAlphaComponent(0.30),
        .paragraphStyle: centred
    ]).draw(in: CGRect(x: 0, y: height - 28, width: width, height: 14))

    return true
}

guard
    let tiff = image.tiffRepresentation,
    let rep  = NSBitmapImageRep(data: tiff),
    let png  = rep.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write("Failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}

let outPath = "assets/dmg-background.png"
do {
    try png.write(to: URL(fileURLWithPath: outPath))
    print("✓ \(outPath) (\(png.count) bytes)")
} catch {
    FileHandle.standardError.write("Write failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
