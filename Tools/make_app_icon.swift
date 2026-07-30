import AppKit
import Foundation
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("usage: make_app_icon.swift <source.png> <out-1024.png> [preview.png]\n", stderr)
    exit(1)
}

let srcPath = args[1]
let out1024 = args[2]
let previewPath = args.count >= 4 ? args[3] : nil
let canvas: CGFloat = 1024

guard let srcImage = NSImage(contentsOfFile: srcPath) else {
    fputs("failed to load source: \(srcPath)\n", stderr)
    exit(1)
}

var srcRect = NSRect(origin: .zero, size: srcImage.size)
guard let srcCG = srcImage.cgImage(forProposedRect: &srcRect, context: nil, hints: nil) else {
    fputs("failed to get cgImage\n", stderr)
    exit(1)
}

let srcW = srcCG.width
let srcH = srcCG.height
let bytesPerRow = srcW * 4
var pixels = [UInt8](repeating: 0, count: srcH * bytesPerRow)
guard let readCtx = CGContext(
    data: &pixels,
    width: srcW,
    height: srcH,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("failed to create read context\n", stderr)
    exit(1)
}
readCtx.draw(srcCG, in: CGRect(x: 0, y: 0, width: srcW, height: srcH))

var minX = srcW
var minY = srcH
var maxX = 0
var maxY = 0
var whiteCount = 0
for y in 0..<srcH {
    for x in 0..<srcW {
        let i = y * bytesPerRow + x * 4
        let r = Int(pixels[i])
        let g = Int(pixels[i + 1])
        let b = Int(pixels[i + 2])
        if r > 200 && g > 200 && b > 200 {
            whiteCount += 1
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }
}

guard whiteCount > 0 else {
    fputs("no white cat pixels found\n", stderr)
    exit(1)
}

let bw = maxX - minX + 1
let bh = maxY - minY + 1
print("white=\(whiteCount) bbox=(\(minX),\(minY))-(\(maxX),\(maxY)) size=\(bw)x\(bh)")

var maskPixels = [UInt8](repeating: 0, count: bw * bh * 4)
for y in 0..<bh {
    for x in 0..<bw {
        let sx = minX + x
        let sy = minY + y
        let si = sy * bytesPerRow + sx * 4
        let r = Int(pixels[si])
        let g = Int(pixels[si + 1])
        let b = Int(pixels[si + 2])
        let di = (y * bw + x) * 4
        if r > 200 && g > 200 && b > 200 {
            maskPixels[di] = 255
            maskPixels[di + 1] = 255
            maskPixels[di + 2] = 255
            maskPixels[di + 3] = 255
        }
    }
}

guard let maskCtx = CGContext(
    data: &maskPixels,
    width: bw,
    height: bh,
    bitsPerComponent: 8,
    bytesPerRow: bw * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
), let catCG = maskCtx.makeImage() else {
    fputs("failed to build cat mask\n", stderr)
    exit(1)
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
var outPixels = [UInt8](repeating: 0, count: Int(canvas) * Int(canvas) * 4)
guard let outCtx = CGContext(
    data: &outPixels,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: Int(canvas) * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("failed to create output context\n", stderr)
    exit(1)
}

outCtx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

let corner = canvas * 0.2237
let iconRect = CGRect(x: 0, y: 0, width: canvas, height: canvas)
let clipPath = CGPath(
    roundedRect: iconRect,
    cornerWidth: corner,
    cornerHeight: corner,
    transform: nil
)
outCtx.addPath(clipPath)
outCtx.clip()

let gradientColors = [
    CGColor(srgbRed: 1.0, green: 0.694, blue: 0.235, alpha: 1), // #FFB13C
    CGColor(srgbRed: 1.0, green: 0.45, blue: 0.05, alpha: 1),   // #FF730D
    CGColor(srgbRed: 0.92, green: 0.30, blue: 0.02, alpha: 1)    // #EB4D05
] as CFArray
guard let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: gradientColors,
    locations: [0, 0.55, 1]
) else {
    fputs("failed to create gradient\n", stderr)
    exit(1)
}

// CG y grows upward: top-left -> bottom-right
outCtx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: canvas),
    end: CGPoint(x: canvas, y: 0),
    options: []
)

let pad = canvas * 0.16
let avail = canvas - pad * 2
let scale = min(avail / CGFloat(bw), avail / CGFloat(bh))
let dw = CGFloat(bw) * scale
let dh = CGFloat(bh) * scale
let dx = (canvas - dw) / 2
let dy = (canvas - dh) / 2

// Bitmap was filled top-left → bottom of buffer; CGImage y grows up, so draw as-is.
outCtx.draw(catCG, in: CGRect(x: dx, y: dy, width: dw, height: dh))

guard let outCG = outCtx.makeImage() else {
    fputs("failed to make output image\n", stderr)
    exit(1)
}

let outRep = NSBitmapImageRep(cgImage: outCG)
guard let pngData = outRep.representation(using: .png, properties: [:]) else {
    fputs("png encode failed\n", stderr)
    exit(1)
}

try pngData.write(to: URL(fileURLWithPath: out1024))
print("wrote \(out1024)")

if let previewPath {
    try pngData.write(to: URL(fileURLWithPath: previewPath))
    print("wrote \(previewPath)")
}
