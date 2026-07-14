import CoreGraphics
import Foundation

enum IdentityProductionRasterPipeline {
    static func renderState(
        strokes: [IdentityVectorStroke],
        pixelSize: Int,
        supersamplingScale: Int
    ) throws -> RasterImage {
        guard pixelSize > 0, supersamplingScale > 0,
              supersamplingScale <= IdentityRasterPipeline.linearSupersamplingScale else {
            throw IdentityExporterError.invalidInput("invalid production state raster size")
        }
        let sourceSize = try checkedMultiply(pixelSize, supersamplingScale)
        let pixelCount = try checkedMultiply(sourceSize, sourceSize)
        let byteCount = try checkedMultiply(pixelCount, 4)
        var rgba = [UInt8](repeating: 0, count: byteCount)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw IdentityExporterError.invalidInput("sRGB is unavailable")
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        try rgba.withUnsafeMutableBytes { rawBuffer in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: sourceSize,
                height: sourceSize,
                bitsPerComponent: 8,
                bytesPerRow: sourceSize * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                throw IdentityExporterError.invalidInput("could not create state bitmap context")
            }
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setBlendMode(.copy)
            context.clear(CGRect(x: 0, y: 0, width: sourceSize, height: sourceSize))
            context.setBlendMode(.normal)
            context.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 1)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            let scale = Double(sourceSize) / 24
            context.translateBy(x: 0, y: CGFloat(sourceSize))
            context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
            for stroke in strokes {
                let path = CGMutablePath()
                for points in stroke.subpaths {
                    guard let first = points.first, points.count >= 2 else {
                        throw IdentityExporterError.invalidInput("state path is incomplete")
                    }
                    path.move(to: CGPoint(x: first.x, y: first.y))
                    for point in points.dropFirst() {
                        path.addLine(to: CGPoint(x: point.x, y: point.y))
                    }
                }
                context.addPath(path)
                context.setLineWidth(CGFloat(stroke.width))
                context.strokePath()
            }
            context.flush()
        }
        let supersampled = try RasterImage(width: sourceSize, height: sourceSize, rgba: rgba)
        let reduced: RasterImage
        if supersamplingScale == 1 {
            reduced = supersampled
        } else {
            reduced = try LanczosDownsampler.resizeAlphaMask(
                supersampled,
                width: pixelSize,
                height: pixelSize
            )
        }
        var output = reduced.rgba
        for offset in stride(from: 0, to: output.count, by: 4) {
            output[offset] = 0
            output[offset + 1] = 0
            output[offset + 2] = 0
        }
        return try RasterImage(width: pixelSize, height: pixelSize, rgba: output)
    }

    private static func checkedMultiply(_ first: Int, _ second: Int) throws -> Int {
        let (result, overflow) = first.multipliedReportingOverflow(by: second)
        guard !overflow else {
            throw IdentityExporterError.invalidInput("production raster dimensions overflow")
        }
        return result
    }
}
