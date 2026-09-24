import OSLog
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

private let logger = Logger(subsystem: "AzureFish.Scripts", category: "prepare-resources")

// 从仓库真实 HEIC 派生固定格式夹具；只在准备资源时运行，测量过程中不生成或修改原件。
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sourceURL = directory.appendingPathComponent("preview-image-21.heic")
let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil)!
let original = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let raster = CGContext(data: nil, width: original.width, height: original.height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
raster.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
let image = raster.makeImage()!
// 沙盒禁止系统 HEIC 解码服务时，延迟解码可能返回空白；不得将这种产物作为性能资源。
let probe = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
probe.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
let bytes = probe.data!.assumingMemoryBound(to: UInt8.self)
precondition((0..<64).contains { bytes[$0 * 4] > 32 || bytes[$0 * 4 + 1] > 32 || bytes[$0 * 4 + 2] > 32 },
    "HEIC decoded to an empty bitmap; run outside a sandbox that blocks the system codec service")
func write(_ image: CGImage, name: String, type: UTType, orientation: Int = 1) {
    let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9, kCGImagePropertyOrientation: orientation] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
}
write(image, name: "benchmark-large.jpg", type: .jpeg)
write(image, name: "benchmark-rotated.jpg", type: .jpeg, orientation: 6)
write(image.cropping(to: CGRect(x: 0, y: 1008, width: 4032, height: 1008))!, name: "benchmark-panorama.jpg", type: .jpeg)
let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setAlpha(0.6)
context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
write(context.makeImage()!, name: "benchmark-alpha.png", type: .png)
// 共 20 个选择项目；有意复用有限的真实来源，各次导入仍复制到不同 URL，避免解码缓存命中。
let names = Array(repeating: "preview-image-21.heic", count: 6)
    + Array(repeating: "benchmark-large.jpg", count: 6)
    + ["benchmark-rotated.jpg", "benchmark-alpha.png", "benchmark-panorama.jpg", "preview-image-02.png",
       "benchmark-rotated.jpg", "benchmark-alpha.png", "benchmark-panorama.jpg", "preview-image-07.png"]
let entries = try names.enumerated().map { index, name -> [String: Any] in
    let url = directory.appendingPathComponent(name)
    let data = try Data(contentsOf: url)
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
    return ["index": index, "file": name, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        "bytes": data.count, "width": props[kCGImagePropertyPixelWidth]!, "height": props[kCGImagePropertyPixelHeight]!,
        "orientation": props[kCGImagePropertyOrientation] ?? 1]
}
let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
try data.write(to: directory.appendingPathComponent("benchmark-manifest.json"))
logger.notice("Prepared \(entries.count, privacy: .public) ordered entries")
