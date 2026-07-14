import Foundation

enum RasterImageError: Error, Equatable {
    case nonPositiveDimensions(width: Int, height: Int)
    case byteCountOverflow(width: Int, height: Int)
    case invalidRGBAByteCount(expected: Int, actual: Int)
    case invalidAlphaByteCount(expected: Int, actual: Int)
}

/// An 8-bit, row-major RGBA raster. Exporter callers provide premultiplied
/// channel values when transparent colored pixels are present.
struct RasterImage: Equatable, Sendable {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(width: Int, height: Int, rgba: [UInt8]) throws {
        let expectedByteCount = try Self.rgbaByteCount(width: width, height: height)
        guard rgba.count == expectedByteCount else {
            throw RasterImageError.invalidRGBAByteCount(
                expected: expectedByteCount,
                actual: rgba.count
            )
        }

        self.width = width
        self.height = height
        self.rgba = rgba
    }

    fileprivate static func rgbaByteCount(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0 else {
            throw RasterImageError.nonPositiveDimensions(width: width, height: height)
        }

        let (pixelCount, pixelCountOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteCountOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelCountOverflow, !byteCountOverflow else {
            throw RasterImageError.byteCountOverflow(width: width, height: height)
        }
        return byteCount
    }
}

enum LanczosDownsampler {
    static let radius = 3.0
    private static let coefficientFractionBits = 24
    private static let coefficientScale: Int64 = 1 << coefficientFractionBits
    private static let finalFractionBits = coefficientFractionBits * 2

    /// Resizes premultiplied RGBA through a separable Lanczos-3 kernel.
    ///
    /// Pixel centers are mapped between the two rasters. Samples beyond the
    /// source bounds are transparent zero and remain part of the normalized
    /// kernel footprint; edge taps are deliberately not renormalized. The
    /// horizontal pass retains signed Q24 values so negative Lanczos lobes are
    /// neither rounded nor clamped before the vertical pass.
    static func resize(
        _ image: RasterImage,
        width destinationWidth: Int,
        height destinationHeight: Int
    ) throws -> RasterImage {
        let outputByteCount = try RasterImage.rgbaByteCount(
            width: destinationWidth,
            height: destinationHeight
        )

        guard image.width != destinationWidth || image.height != destinationHeight else {
            return image
        }

        let horizontalTable = makeCoefficientTable(
            sourceCount: image.width,
            destinationCount: destinationWidth
        )
        let verticalTable = makeCoefficientTable(
            sourceCount: image.height,
            destinationCount: destinationHeight
        )

        var output = [UInt8](repeating: 0, count: outputByteCount)

        // Only horizontally filtered rows needed by the current vertical
        // footprint are retained. For a 16x reduction this is at most 96 rows,
        // instead of a sourceHeight x destinationWidth intermediate image.
        var horizontalRowCache: [Int: [Int64]] = [:]

        for destinationY in 0..<destinationHeight {
            let verticalTaps = verticalTable[destinationY]
            let neededSourceRows = Set(
                verticalTaps.lazy
                    .map(\.sourceIndex)
                    .filter { $0 >= 0 && $0 < image.height }
            )

            horizontalRowCache = horizontalRowCache.filter {
                neededSourceRows.contains($0.key)
            }

            for sourceY in neededSourceRows.sorted() where horizontalRowCache[sourceY] == nil {
                horizontalRowCache[sourceY] = filterHorizontalRow(
                    image,
                    sourceY: sourceY,
                    destinationWidth: destinationWidth,
                    coefficientTable: horizontalTable
                )
            }

            var accumulatedRow = [Int64](
                repeating: 0,
                count: destinationWidth * 4
            )

            for tap in verticalTaps {
                guard tap.sourceIndex >= 0,
                      tap.sourceIndex < image.height,
                      let horizontalRow = horizontalRowCache[tap.sourceIndex]
                else {
                    // Transparent zero extension. The omitted contribution is
                    // zero, but its coefficient was included during table
                    // normalization.
                    continue
                }

                for componentIndex in accumulatedRow.indices {
                    accumulatedRow[componentIndex] += horizontalRow[componentIndex] * tap.weight
                }
            }

            let destinationRowOffset = destinationY * destinationWidth * 4
            for componentIndex in accumulatedRow.indices {
                output[destinationRowOffset + componentIndex] = finalByte(
                    fromQ48: accumulatedRow[componentIndex]
                )
            }
        }

        return try RasterImage(
            width: destinationWidth,
            height: destinationHeight,
            rgba: output
        )
    }

    /// Specialized path for the exporter's black-RGB template masks. It uses
    /// the exact same kernel and rounding contract while filtering only alpha,
    /// reducing the 1024 App Icon master work by four without changing pixels.
    static func resizeAlphaMask(
        _ image: RasterImage,
        width destinationWidth: Int,
        height destinationHeight: Int
    ) throws -> RasterImage {
        let outputByteCount = try RasterImage.rgbaByteCount(
            width: destinationWidth,
            height: destinationHeight
        )
        guard image.width != destinationWidth || image.height != destinationHeight else {
            return image
        }

        let horizontalTable = makeCoefficientTable(
            sourceCount: image.width,
            destinationCount: destinationWidth
        )
        let verticalTable = makeCoefficientTable(
            sourceCount: image.height,
            destinationCount: destinationHeight
        )
        var output = [UInt8](repeating: 0, count: outputByteCount)
        var horizontalRowCache: [Int: [Int64]] = [:]

        for destinationY in 0..<destinationHeight {
            let verticalTaps = verticalTable[destinationY]
            let neededSourceRows = Set(
                verticalTaps.lazy
                    .map(\.sourceIndex)
                    .filter { $0 >= 0 && $0 < image.height }
            )
            horizontalRowCache = horizontalRowCache.filter {
                neededSourceRows.contains($0.key)
            }
            for sourceY in neededSourceRows.sorted() where horizontalRowCache[sourceY] == nil {
                horizontalRowCache[sourceY] = filterHorizontalAlphaRow(
                    image,
                    sourceY: sourceY,
                    destinationWidth: destinationWidth,
                    coefficientTable: horizontalTable
                )
            }

            var accumulatedRow = [Int64](repeating: 0, count: destinationWidth)
            for tap in verticalTaps {
                guard tap.sourceIndex >= 0,
                      tap.sourceIndex < image.height,
                      let horizontalRow = horizontalRowCache[tap.sourceIndex] else {
                    continue
                }
                for destinationX in 0..<destinationWidth {
                    accumulatedRow[destinationX] += horizontalRow[destinationX] * tap.weight
                }
            }

            let destinationRowOffset = destinationY * destinationWidth * 4
            for destinationX in 0..<destinationWidth {
                output[destinationRowOffset + destinationX * 4 + 3] = finalByte(
                    fromQ48: accumulatedRow[destinationX]
                )
            }
        }

        return try RasterImage(
            width: destinationWidth,
            height: destinationHeight,
            rgba: output
        )
    }

    /// Streams an alpha-only source without materializing a giant RGBA image.
    /// Coefficients are inverted so each non-zero source sample contributes to
    /// only the destination pixels whose Lanczos-3 footprint contains it.
    static func resizeStreamingAlphaMask(
        sourceWidth: Int,
        sourceHeight: Int,
        width destinationWidth: Int,
        height destinationHeight: Int,
        sourceAlphaRow: (Int) throws -> ArraySlice<UInt8>
    ) throws -> RasterImage {
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw RasterImageError.nonPositiveDimensions(
                width: sourceWidth,
                height: sourceHeight
            )
        }
        let outputByteCount = try RasterImage.rgbaByteCount(
            width: destinationWidth,
            height: destinationHeight
        )
        let horizontalTable = makeCoefficientTable(
            sourceCount: sourceWidth,
            destinationCount: destinationWidth
        )
        let verticalTable = makeCoefficientTable(
            sourceCount: sourceHeight,
            destinationCount: destinationHeight
        )
        let horizontalContributions = invert(
            horizontalTable,
            sourceCount: sourceWidth
        )
        let verticalContributions = invert(
            verticalTable,
            sourceCount: sourceHeight
        )

        var accumulated = [Int64](
            repeating: 0,
            count: destinationWidth * destinationHeight
        )
        var horizontal = [Int64](repeating: 0, count: destinationWidth)

        for sourceY in 0..<sourceHeight {
            let row = try sourceAlphaRow(sourceY)
            guard row.count == sourceWidth else {
                throw RasterImageError.invalidAlphaByteCount(
                    expected: sourceWidth,
                    actual: row.count
                )
            }
            for destinationX in horizontal.indices {
                horizontal[destinationX] = 0
            }

            var hasCoverage = false
            for (sourceX, alpha) in row.enumerated() where alpha != 0 {
                hasCoverage = true
                for contribution in horizontalContributions[sourceX] {
                    horizontal[contribution.destinationIndex] +=
                        Int64(alpha) * contribution.weight
                }
            }
            guard hasCoverage else { continue }

            for vertical in verticalContributions[sourceY] {
                let destinationOffset = vertical.destinationIndex * destinationWidth
                for destinationX in 0..<destinationWidth where horizontal[destinationX] != 0 {
                    accumulated[destinationOffset + destinationX] +=
                        horizontal[destinationX] * vertical.weight
                }
            }
        }

        var output = [UInt8](repeating: 0, count: outputByteCount)
        for destinationY in 0..<destinationHeight {
            for destinationX in 0..<destinationWidth {
                let sourceOffset = destinationY * destinationWidth + destinationX
                let destinationOffset = sourceOffset * 4
                output[destinationOffset + 3] = finalByte(fromQ48: accumulated[sourceOffset])
            }
        }
        return try RasterImage(
            width: destinationWidth,
            height: destinationHeight,
            rgba: output
        )
    }

    private static func filterHorizontalRow(
        _ image: RasterImage,
        sourceY: Int,
        destinationWidth: Int,
        coefficientTable: [[Tap]]
    ) -> [Int64] {
        var result = [Int64](repeating: 0, count: destinationWidth * 4)
        let sourceRowOffset = sourceY * image.width * 4

        for destinationX in 0..<destinationWidth {
            let destinationOffset = destinationX * 4

            for tap in coefficientTable[destinationX] {
                guard tap.sourceIndex >= 0, tap.sourceIndex < image.width else {
                    continue
                }

                let sourceOffset = sourceRowOffset + tap.sourceIndex * 4
                for channel in 0..<4 {
                    result[destinationOffset + channel] +=
                        Int64(image.rgba[sourceOffset + channel]) * tap.weight
                }
            }
        }

        return result
    }

    private static func filterHorizontalAlphaRow(
        _ image: RasterImage,
        sourceY: Int,
        destinationWidth: Int,
        coefficientTable: [[Tap]]
    ) -> [Int64] {
        var result = [Int64](repeating: 0, count: destinationWidth)
        let sourceRowOffset = sourceY * image.width * 4
        for destinationX in 0..<destinationWidth {
            var value: Int64 = 0
            for tap in coefficientTable[destinationX] {
                guard tap.sourceIndex >= 0, tap.sourceIndex < image.width else {
                    continue
                }
                value += Int64(image.rgba[sourceRowOffset + tap.sourceIndex * 4 + 3]) * tap.weight
            }
            result[destinationX] = value
        }
        return result
    }

    private static func makeCoefficientTable(
        sourceCount: Int,
        destinationCount: Int
    ) -> [[Tap]] {
        let scale = Double(sourceCount) / Double(destinationCount)
        let filterScale = max(1.0, scale)
        let support = radius * filterScale

        return (0..<destinationCount).map { destinationIndex in
            // Coordinates use image edges as integers and pixel centers as
            // half-integers.
            let sourceCenter = (Double(destinationIndex) + 0.5) * scale
            let firstCandidate = Int(floor(sourceCenter - support - 0.5))
            let lastCandidate = Int(ceil(sourceCenter + support - 0.5))

            var sourceIndices: [Int] = []
            var rawWeights: [Double] = []
            sourceIndices.reserveCapacity(lastCandidate - firstCandidate + 1)
            rawWeights.reserveCapacity(lastCandidate - firstCandidate + 1)

            for sourceIndex in firstCandidate...lastCandidate {
                let sourcePixelCenter = Double(sourceIndex) + 0.5
                let normalizedDistance = abs(sourcePixelCenter - sourceCenter) / filterScale
                guard normalizedDistance < radius else {
                    continue
                }

                sourceIndices.append(sourceIndex)
                rawWeights.append(lanczos3(normalizedDistance))
            }

            let rawWeightSum = rawWeights.reduce(0, +)
            precondition(rawWeightSum.isFinite && rawWeightSum > 0)

            let fixedWeights = quantizeNormalizedWeights(
                rawWeights,
                sum: rawWeightSum
            )
            precondition(fixedWeights.reduce(0, +) == coefficientScale)

            return zip(sourceIndices, fixedWeights).map {
                Tap(sourceIndex: $0.0, weight: $0.1)
            }
        }
    }

    private static func invert(
        _ table: [[Tap]],
        sourceCount: Int
    ) -> [[DestinationTap]] {
        var inverted = [[DestinationTap]](repeating: [], count: sourceCount)
        for (destinationIndex, taps) in table.enumerated() {
            for tap in taps where tap.sourceIndex >= 0 && tap.sourceIndex < sourceCount {
                inverted[tap.sourceIndex].append(.init(
                    destinationIndex: destinationIndex,
                    weight: tap.weight
                ))
            }
        }
        return inverted
    }

    private static func quantizeNormalizedWeights(
        _ rawWeights: [Double],
        sum: Double
    ) -> [Int64] {
        precondition(!rawWeights.isEmpty)

        let isSymmetric = zip(rawWeights, rawWeights.reversed()).allSatisfy {
            $0.0 == $0.1
        }

        var quantized = [Int64](repeating: 0, count: rawWeights.count)

        if isSymmetric {
            // Quantize mirrored taps together. Integer-ratio reductions such
            // as 16x therefore keep an exactly symmetric impulse response.
            for index in 0..<((rawWeights.count + 1) / 2) {
                let mirroredIndex = rawWeights.count - 1 - index
                let value = quantizedWeight(rawWeights[index], sum: sum)
                quantized[index] = value
                quantized[mirroredIndex] = value
            }

            let correction = coefficientScale - quantized.reduce(0, +)
            if rawWeights.count.isMultiple(of: 2) {
                precondition(correction.isMultiple(of: 2))
                let leftCenter = rawWeights.count / 2 - 1
                let rightCenter = rawWeights.count / 2
                quantized[leftCenter] += correction / 2
                quantized[rightCenter] += correction / 2
            } else {
                quantized[rawWeights.count / 2] += correction
            }
        } else {
            for index in rawWeights.indices {
                quantized[index] = quantizedWeight(rawWeights[index], sum: sum)
            }

            // Resolve the sub-LSB normalization remainder at the strongest
            // positive tap. Ties choose the lower source index deterministically.
            let correctionIndex = rawWeights.indices.max { lhs, rhs in
                if rawWeights[lhs] == rawWeights[rhs] {
                    return lhs > rhs
                }
                return rawWeights[lhs] < rawWeights[rhs]
            }!
            quantized[correctionIndex] += coefficientScale - quantized.reduce(0, +)
        }

        return quantized
    }

    private static func quantizedWeight(_ rawWeight: Double, sum: Double) -> Int64 {
        Int64(
            (rawWeight / sum * Double(coefficientScale))
                .rounded(.toNearestOrEven)
        )
    }

    private static func lanczos3(_ distance: Double) -> Double {
        guard distance < radius else {
            return 0
        }
        guard distance != 0 else {
            return 1
        }

        return sinc(distance) * sinc(distance / radius)
    }

    private static func sinc(_ value: Double) -> Double {
        guard value != 0 else {
            return 1
        }
        let angle = Double.pi * value
        return sin(angle) / angle
    }

    private static func finalByte(fromQ48 value: Int64) -> UInt8 {
        let rounded = roundToNearestEven(value, fractionalBits: finalFractionBits)
        return UInt8(clamping: rounded)
    }

    static func roundToNearestEven(
        _ value: Int64,
        fractionalBits: Int
    ) -> Int64 {
        precondition(fractionalBits > 0 && fractionalBits < 63)

        let isNegative = value < 0
        let magnitude: UInt64
        if isNegative {
            // This form is defined even for Int64.min, although convolution
            // bounds are substantially smaller.
            magnitude = UInt64(-(value + 1)) + 1
        } else {
            magnitude = UInt64(value)
        }

        let quotient = magnitude >> UInt64(fractionalBits)
        let remainderMask = (UInt64(1) << UInt64(fractionalBits)) - 1
        let remainder = magnitude & remainderMask
        let halfway = UInt64(1) << UInt64(fractionalBits - 1)
        let roundsUp = remainder > halfway ||
            (remainder == halfway && !quotient.isMultiple(of: 2))
        let roundedMagnitude = quotient + (roundsUp ? 1 : 0)

        let signedMagnitude = Int64(roundedMagnitude)
        return isNegative ? -signedMagnitude : signedMagnitude
    }

    private struct Tap {
        let sourceIndex: Int
        let weight: Int64
    }

    private struct DestinationTap {
        let destinationIndex: Int
        let weight: Int64
    }
}
