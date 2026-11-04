import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageProcessor {
    static func jpeg(_ data: Data, maximumSide: Int = 2048) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw APIError(code: "INVALID_IMAGE", message: "无法读取这张照片")
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumSide,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw APIError(code: "INVALID_IMAGE", message: "无法生成图片")
            }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw APIError(code: "IMAGE_ENCODE", message: "图片转换失败")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw APIError(code: "IMAGE_ENCODE", message: "图片保存失败") }
            return output as Data
        }.value
    }

    static func thumbnail(_ url: URL) async throws -> Data {
        let data = try await Task.detached(priority: .utility) { try Data(contentsOf: url) }.value
        return try await jpeg(data, maximumSide: 240)
    }
}
