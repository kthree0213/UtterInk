import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PNGEncoder {
    static func encode(_ image: RasterImage) throws -> Data {
        guard image.width > 0, image.height > 0 else {
            throw PNGEncodingError.invalidDimensions(width: image.width, height: image.height)
        }

        let (pixelCount, pixelCountOverflow) = image.width.multipliedReportingOverflow(by: image.height)
        let (expectedByteCount, byteCountOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        let (bytesPerRow, bytesPerRowOverflow) = image.width.multipliedReportingOverflow(by: 4)
        guard !pixelCountOverflow, !byteCountOverflow, !bytesPerRowOverflow else {
            throw PNGEncodingError.dimensionOverflow(width: image.width, height: image.height)
        }
        guard image.rgba.count == expectedByteCount else {
            throw PNGEncodingError.invalidByteCount(
                expected: expectedByteCount,
                actual: image.rgba.count
            )
        }

        let pixelData = Data(image.rgba)
        guard let provider = CGDataProvider(data: pixelData as CFData) else {
            throw PNGEncodingError.couldNotCreateDataProvider
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PNGEncodingError.couldNotCreateSRGBColorSpace
        }

        let bitmapInfo = CGBitmapInfo(
            rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let cgImage = CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw PNGEncodingError.couldNotCreateImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw PNGEncodingError.couldNotCreateDestination
        }

        let pngProperties: [CFString: Any] = [
            kCGImagePropertyPNGInterlaceType: 0,
            kCGImagePropertyPNGsRGBIntent: 0,
        ]
        let properties: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: pngProperties,
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination), output.length > 0 else {
            throw PNGEncodingError.finalizationFailed
        }
        return output as Data
    }
}

private enum PNGEncodingError: Error {
    case invalidDimensions(width: Int, height: Int)
    case dimensionOverflow(width: Int, height: Int)
    case invalidByteCount(expected: Int, actual: Int)
    case couldNotCreateDataProvider
    case couldNotCreateSRGBColorSpace
    case couldNotCreateImage
    case couldNotCreateDestination
    case finalizationFailed
}
