import CoreGraphics
import Foundation

struct IdentityColor: Codable, Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(hex: String) throws {
        guard hex.count == 7, hex.first == "#" else {
            throw IdentityExporterError.invalidInput("palette colors must use #RRGGBB")
        }
        let digits = String(hex.dropFirst())
        guard digits.allSatisfy({ $0.isHexDigit }),
              let value = UInt32(digits, radix: 16) else {
            throw IdentityExporterError.invalidInput("palette contains an invalid color")
        }
        red = UInt8((value >> 16) & 0xff)
        green = UInt8((value >> 8) & 0xff)
        blue = UInt8(value & 0xff)
    }
}

struct IdentityPalette: Equatable, Sendable {
    let name: String
    let background: IdentityColor
    let mark: IdentityColor
}

enum IdentityRasterPipeline {
    /// The approved identity contract requires a 16x high-resolution bitmap
    /// along each axis before the in-tool Lanczos-3 reduction.
    static let linearSupersamplingScale = 16
    static let supersamplingSamplesPerPixel = 256

    static func renderMenu(
        svg: ValidatedSVG,
        pixelSize: Int,
        supersamplingScale: Int = linearSupersamplingScale
    ) throws -> RasterImage {
        guard pixelSize > 0, supersamplingScale > 0, supersamplingScale <= linearSupersamplingScale else {
            throw IdentityExporterError.invalidInput("menu output size must be positive")
        }
        let sourceSize = try checkedMultiply(pixelSize, supersamplingScale)
        let supersampled = try renderTemplateMask(
            svg: svg,
            width: sourceSize,
            height: sourceSize,
            contentScale: 1,
            opticalOffset: VectorPoint(x: 0, y: 0)
        )
        let reduced = try LanczosDownsampler.resizeAlphaMask(
            supersampled,
            width: pixelSize,
            height: pixelSize
        )
        return try blackTemplate(from: reduced)
    }

    static func renderAppIconMasterMask(
        svg: ValidatedSVG,
        supersamplingScale: Int = linearSupersamplingScale
    ) throws -> RasterImage {
        let destinationSize = 1_024
        guard supersamplingScale > 0, supersamplingScale <= linearSupersamplingScale else {
            throw IdentityExporterError.invalidInput("invalid App Icon supersampling scale")
        }
        let sourceSize = try checkedMultiply(destinationSize, supersamplingScale)
        if sourceSize == destinationSize {
            return try blackTemplate(from: renderTemplateMask(
                svg: svg,
                width: sourceSize,
                height: sourceSize,
                contentScale: 0.82,
                opticalOffset: VectorPoint(x: -0.12, y: -0.18)
            ))
        }
        let bandHeight = 128
        var cachedBandStart = -1
        var cachedBandHeight = 0
        var cachedAlpha: [UInt8] = []

        let reduced = try LanczosDownsampler.resizeStreamingAlphaMask(
            sourceWidth: sourceSize,
            sourceHeight: sourceSize,
            width: destinationSize,
            height: destinationSize
        ) { sourceY in
            let requiredBandStart = sourceY / bandHeight * bandHeight
            if requiredBandStart != cachedBandStart {
                cachedBandStart = requiredBandStart
                cachedBandHeight = min(bandHeight, sourceSize - requiredBandStart)
                cachedAlpha = try renderTemplateAlphaBand(
                    svg: svg,
                    fullWidth: sourceSize,
                    fullHeight: sourceSize,
                    logicalStartY: cachedBandStart,
                    logicalHeight: cachedBandHeight,
                    contentScale: 0.82,
                    opticalOffset: VectorPoint(x: -0.12, y: -0.18)
                )
            }
            let localY = sourceY - cachedBandStart
            let rowStart = localY * sourceSize
            return cachedAlpha[rowStart..<(rowStart + sourceSize)]
        }
        return try blackTemplate(from: reduced)
    }

    static func resizedMask(_ master: RasterImage, pixelSize: Int) throws -> RasterImage {
        try LanczosDownsampler.resizeAlphaMask(master, width: pixelSize, height: pixelSize)
    }

    static func composite(mask: RasterImage, palette: IdentityPalette) throws -> RasterImage {
        var output = [UInt8](repeating: 0, count: mask.rgba.count)
        for pixelOffset in stride(from: 0, to: mask.rgba.count, by: 4) {
            let alpha = Int(mask.rgba[pixelOffset + 3])
            let inverse = 255 - alpha
            output[pixelOffset] = blend(
                foreground: palette.mark.red,
                background: palette.background.red,
                alpha: alpha,
                inverseAlpha: inverse
            )
            output[pixelOffset + 1] = blend(
                foreground: palette.mark.green,
                background: palette.background.green,
                alpha: alpha,
                inverseAlpha: inverse
            )
            output[pixelOffset + 2] = blend(
                foreground: palette.mark.blue,
                background: palette.background.blue,
                alpha: alpha,
                inverseAlpha: inverse
            )
            output[pixelOffset + 3] = 255
        }
        return try RasterImage(width: mask.width, height: mask.height, rgba: output)
    }

    private static func renderTemplateMask(
        svg: ValidatedSVG,
        width: Int,
        height: Int,
        contentScale: Double,
        opticalOffset: VectorPoint
    ) throws -> RasterImage {
        let rgba = try renderTemplateRGBAWindow(
            svg: svg,
            fullWidth: width,
            fullHeight: height,
            windowStartY: 0,
            windowHeight: height,
            contentScale: contentScale,
            opticalOffset: opticalOffset
        )
        return try RasterImage(width: width, height: height, rgba: rgba)
    }

    private static func renderTemplateAlphaBand(
        svg: ValidatedSVG,
        fullWidth: Int,
        fullHeight: Int,
        logicalStartY: Int,
        logicalHeight: Int,
        contentScale: Double,
        opticalOffset: VectorPoint
    ) throws -> [UInt8] {
        guard logicalStartY >= 0,
              logicalHeight > 0,
              logicalStartY + logicalHeight <= fullHeight else {
            throw IdentityExporterError.invalidInput("invalid supersampling band")
        }
        let antialiasGuard = 2
        let renderStartY = max(0, logicalStartY - antialiasGuard)
        let renderEndY = min(
            fullHeight,
            logicalStartY + logicalHeight + antialiasGuard
        )
        let renderHeight = renderEndY - renderStartY
        let rgba = try renderTemplateRGBAWindow(
            svg: svg,
            fullWidth: fullWidth,
            fullHeight: fullHeight,
            windowStartY: renderStartY,
            windowHeight: renderHeight,
            contentScale: contentScale,
            opticalOffset: opticalOffset
        )

        var alpha = [UInt8](
            repeating: 0,
            count: try checkedMultiply(fullWidth, logicalHeight)
        )
        let firstRenderedRow = logicalStartY - renderStartY
        for logicalRow in 0..<logicalHeight {
            let renderedRow = firstRenderedRow + logicalRow
            let renderedOffset = renderedRow * fullWidth * 4
            let alphaOffset = logicalRow * fullWidth
            for x in 0..<fullWidth {
                alpha[alphaOffset + x] = rgba[renderedOffset + x * 4 + 3]
            }
        }
        return alpha
    }

    private static func renderTemplateRGBAWindow(
        svg: ValidatedSVG,
        fullWidth: Int,
        fullHeight: Int,
        windowStartY: Int,
        windowHeight: Int,
        contentScale: Double,
        opticalOffset: VectorPoint
    ) throws -> [UInt8] {
        let byteCount = try checkedMultiply(try checkedMultiply(fullWidth, windowHeight), 4)
        let bytesPerRow = try checkedMultiply(fullWidth, 4)
        var rgba = [UInt8](repeating: 0, count: byteCount)
        let colorSpace = try requireSRGBColorSpace()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        try rgba.withUnsafeMutableBytes { rawBuffer in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: fullWidth,
                height: windowHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                throw IdentityExporterError.invalidInput("could not create identity bitmap context")
            }

            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setBlendMode(.copy)
            context.clear(CGRect(
                x: 0,
                y: 0,
                width: CGFloat(fullWidth),
                height: CGFloat(windowHeight)
            ))
            context.setBlendMode(.normal)
            context.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 1)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            let baseScale = min(
                Double(fullWidth) / svg.viewBoxWidth,
                Double(fullHeight) / svg.viewBoxHeight
            )
            let scale = baseScale * contentScale
            let drawnWidth = svg.viewBoxWidth * scale
            let drawnHeight = svg.viewBoxHeight * scale
            let originX = (Double(fullWidth) - drawnWidth) / 2 + opticalOffset.x * scale
            let originY = (Double(fullHeight) - drawnHeight) / 2 + opticalOffset.y * scale

            // Quartz user space is y-up. This transform consumes the parsed
            // SVG's y-down coordinates. A window translates the same global
            // geometry into a narrow RGBA8 band without seams or a 1 GiB canvas.
            context.translateBy(
                x: CGFloat(originX),
                y: CGFloat(Double(windowStartY + windowHeight) - originY)
            )
            context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))

            let bowlPath = CGMutablePath()
            guard let first = svg.bowlPolyline.first else {
                throw IdentityExporterError.invalidInput("parsed bowl geometry is empty")
            }
            bowlPath.move(to: CGPoint(x: CGFloat(first.x), y: CGFloat(first.y)))
            for point in svg.bowlPolyline.dropFirst() {
                bowlPath.addLine(to: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
            }
            context.addPath(bowlPath)
            context.setLineWidth(CGFloat(svg.bowlStrokeWidth))
            context.strokePath()

            let cursorPath = CGMutablePath()
            cursorPath.move(to: CGPoint(x: CGFloat(svg.cursorStart.x), y: CGFloat(svg.cursorStart.y)))
            cursorPath.addLine(to: CGPoint(x: CGFloat(svg.cursorEnd.x), y: CGFloat(svg.cursorEnd.y)))
            context.addPath(cursorPath)
            context.setLineWidth(CGFloat(svg.cursorStrokeWidth))
            context.strokePath()
            context.flush()
        }
        return rgba
    }

    private static func blackTemplate(from image: RasterImage) throws -> RasterImage {
        var rgba = image.rgba
        for pixelOffset in stride(from: 0, to: rgba.count, by: 4) {
            rgba[pixelOffset] = 0
            rgba[pixelOffset + 1] = 0
            rgba[pixelOffset + 2] = 0
        }
        return try RasterImage(width: image.width, height: image.height, rgba: rgba)
    }

    private static func blend(
        foreground: UInt8,
        background: UInt8,
        alpha: Int,
        inverseAlpha: Int
    ) -> UInt8 {
        let numerator = Int(foreground) * alpha + Int(background) * inverseAlpha + 127
        return UInt8(numerator / 255)
    }

    private static func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else {
            throw IdentityExporterError.invalidInput("identity raster dimensions overflow")
        }
        return result
    }

    private static func requireSRGBColorSpace() throws -> CGColorSpace {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw IdentityExporterError.invalidInput("sRGB is unavailable")
        }
        return colorSpace
    }
}
