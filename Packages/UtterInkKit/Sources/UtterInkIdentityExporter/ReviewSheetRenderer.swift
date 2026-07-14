import Foundation

struct IdentityReviewAsset: Sendable {
    let label: String
    let image: RasterImage
}

enum IdentityReviewSheetRenderer {
    static func render(
        menuAssets: [IdentityReviewAsset],
        appIconAssets: [IdentityReviewAsset]
    ) throws -> RasterImage {
        guard menuAssets.count == 6, appIconAssets.count == 3 else {
            throw IdentityExporterError.invalidInput("review sheet requires six menu assets and three app icons")
        }

        var canvas = try BitmapCanvas(width: 1_280, height: 760, fill: (242, 240, 235))
        canvas.drawText("UTTERINK IDENTITY REVIEW", x: 38, y: 28, scale: 3, color: (23, 24, 33))
        canvas.drawText(
            "TASK 1 CANDIDATE - NOT FINAL",
            x: 40,
            y: 64,
            scale: 1,
            color: (95, 94, 100)
        )

        let simulations: [(name: String, background: RGB, tint: RGB)] = [
            ("LIGHT", (252, 252, 252), (0, 0, 0)),
            ("DARK", (30, 31, 36), (255, 255, 255)),
            ("HIGH CONTRAST", (255, 232, 0), (0, 0, 0)),
        ]
        let panelWidth = 386
        let panelHeight = 330
        let panelY = 100

        for (panelIndex, simulation) in simulations.enumerated() {
            let panelX = 34 + panelIndex * 412
            canvas.fillRect(
                x: panelX,
                y: panelY,
                width: panelWidth,
                height: panelHeight,
                color: simulation.background
            )
            canvas.strokeRect(
                x: panelX,
                y: panelY,
                width: panelWidth,
                height: panelHeight,
                color: panelIndex == 1 ? (86, 87, 94) : (23, 24, 33)
            )
            canvas.drawText(
                simulation.name,
                x: panelX + 18,
                y: panelY + 18,
                scale: 2,
                color: simulation.tint
            )

            for (assetIndex, asset) in menuAssets.enumerated() {
                let column = assetIndex % 3
                let row = assetIndex / 3
                let cellX = panelX + 18 + column * 119
                let cellY = panelY + 62 + row * 126
                let centerX = cellX + 52
                let centerY = cellY + 43

                canvas.drawTemplate(
                    asset.image,
                    centerX: centerX,
                    centerY: centerY,
                    scale: 2,
                    tint: simulation.tint
                )
                canvas.drawTemplate(
                    asset.image,
                    centerX: cellX + 99,
                    centerY: cellY + 18,
                    scale: 1,
                    tint: simulation.tint
                )
                canvas.drawText(
                    asset.label,
                    x: cellX + 5,
                    y: cellY + 93,
                    scale: 1,
                    color: simulation.tint
                )
            }
        }

        canvas.drawText("APP ICON PALETTE CANDIDATES", x: 38, y: 462, scale: 2, color: (23, 24, 33))
        for (index, asset) in appIconAssets.enumerated() {
            let panelX = 74 + index * 404
            let panelY = 500
            canvas.fillRect(x: panelX, y: panelY, width: 324, height: 224, color: (255, 255, 255))
            canvas.strokeRect(x: panelX, y: panelY, width: 324, height: 224, color: (177, 174, 166))
            let preview = try LanczosDownsampler.resize(asset.image, width: 176, height: 176)
            canvas.drawImage(preview, x: panelX + 22, y: panelY + 24)
            canvas.drawText(asset.label, x: panelX + 214, y: panelY + 88, scale: 1, color: (23, 24, 33))
        }

        return try RasterImage(width: canvas.width, height: canvas.height, rgba: canvas.rgba)
    }
}

private typealias RGB = (UInt8, UInt8, UInt8)

private struct BitmapCanvas {
    let width: Int
    let height: Int
    var rgba: [UInt8]

    init(width: Int, height: Int, fill: RGB) throws {
        guard width > 0, height > 0 else {
            throw IdentityExporterError.invalidInput("review sheet dimensions must be positive")
        }
        self.width = width
        self.height = height
        rgba = [UInt8](repeating: 0, count: width * height * 4)
        fillRect(x: 0, y: 0, width: width, height: height, color: fill)
    }

    mutating func fillRect(x: Int, y: Int, width rectWidth: Int, height rectHeight: Int, color: RGB) {
        let minX = max(0, x)
        let minY = max(0, y)
        let maxX = min(width, x + rectWidth)
        let maxY = min(height, y + rectHeight)
        guard minX < maxX, minY < maxY else { return }
        for destinationY in minY..<maxY {
            for destinationX in minX..<maxX {
                setOpaquePixel(x: destinationX, y: destinationY, color: color)
            }
        }
    }

    mutating func strokeRect(x: Int, y: Int, width rectWidth: Int, height rectHeight: Int, color: RGB) {
        fillRect(x: x, y: y, width: rectWidth, height: 1, color: color)
        fillRect(x: x, y: y + rectHeight - 1, width: rectWidth, height: 1, color: color)
        fillRect(x: x, y: y, width: 1, height: rectHeight, color: color)
        fillRect(x: x + rectWidth - 1, y: y, width: 1, height: rectHeight, color: color)
    }

    mutating func drawTemplate(
        _ image: RasterImage,
        centerX: Int,
        centerY: Int,
        scale: Int,
        tint: RGB
    ) {
        let originX = centerX - image.width * scale / 2
        let originY = centerY - image.height * scale / 2
        for sourceY in 0..<image.height {
            for sourceX in 0..<image.width {
                let sourceOffset = (sourceY * image.width + sourceX) * 4
                let alpha = image.rgba[sourceOffset + 3]
                guard alpha > 0 else { continue }
                for repeatY in 0..<scale {
                    for repeatX in 0..<scale {
                        blendTint(
                            x: originX + sourceX * scale + repeatX,
                            y: originY + sourceY * scale + repeatY,
                            tint: tint,
                            alpha: alpha
                        )
                    }
                }
            }
        }
    }

    mutating func drawImage(_ image: RasterImage, x: Int, y: Int) {
        for sourceY in 0..<image.height {
            for sourceX in 0..<image.width {
                let destinationX = x + sourceX
                let destinationY = y + sourceY
                guard destinationX >= 0, destinationX < width,
                      destinationY >= 0, destinationY < height else { continue }
                let sourceOffset = (sourceY * image.width + sourceX) * 4
                let destinationOffset = (destinationY * width + destinationX) * 4
                let alpha = Int(image.rgba[sourceOffset + 3])
                let inverse = 255 - alpha
                for channel in 0..<3 {
                    let source = Int(image.rgba[sourceOffset + channel])
                    let destination = Int(rgba[destinationOffset + channel])
                    rgba[destinationOffset + channel] = UInt8(
                        min(255, source + (destination * inverse + 127) / 255)
                    )
                }
                rgba[destinationOffset + 3] = 255
            }
        }
    }

    mutating func drawText(_ text: String, x: Int, y: Int, scale: Int, color: RGB) {
        var cursorX = x
        for character in text.uppercased() {
            let rows = BitmapFont.rows(for: character)
            for (rowIndex, bits) in rows.enumerated() {
                for column in 0..<5 where bits & (1 << (4 - column)) != 0 {
                    fillRect(
                        x: cursorX + column * scale,
                        y: y + rowIndex * scale,
                        width: scale,
                        height: scale,
                        color: color
                    )
                }
            }
            cursorX += 6 * scale
        }
    }

    private mutating func blendTint(x: Int, y: Int, tint: RGB, alpha: UInt8) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let offset = (y * width + x) * 4
        let a = Int(alpha)
        let inverse = 255 - a
        let channels = [tint.0, tint.1, tint.2]
        for channel in 0..<3 {
            rgba[offset + channel] = UInt8(
                (Int(channels[channel]) * a + Int(rgba[offset + channel]) * inverse + 127) / 255
            )
        }
        rgba[offset + 3] = 255
    }

    private mutating func setOpaquePixel(x: Int, y: Int, color: RGB) {
        let offset = (y * width + x) * 4
        rgba[offset] = color.0
        rgba[offset + 1] = color.1
        rgba[offset + 2] = color.2
        rgba[offset + 3] = 255
    }
}

private enum BitmapFont {
    static func rows(for character: Character) -> [UInt8] {
        glyphs[character] ?? glyphs["?"]!
    }

    private static let glyphs: [Character: [UInt8]] = [
        " ": [0, 0, 0, 0, 0, 0, 0],
        "-": [0, 0, 0, 31, 0, 0, 0],
        "?": [14, 17, 1, 2, 4, 0, 4],
        "@": [14, 17, 23, 21, 23, 16, 14],
        "0": [14, 17, 19, 21, 25, 17, 14],
        "1": [4, 12, 4, 4, 4, 4, 14],
        "2": [14, 17, 1, 2, 4, 8, 31],
        "3": [30, 1, 1, 14, 1, 1, 30],
        "4": [2, 6, 10, 18, 31, 2, 2],
        "5": [31, 16, 16, 30, 1, 1, 30],
        "6": [14, 16, 16, 30, 17, 17, 14],
        "7": [31, 1, 2, 4, 8, 8, 8],
        "8": [14, 17, 17, 14, 17, 17, 14],
        "9": [14, 17, 17, 15, 1, 1, 14],
        "A": [14, 17, 17, 31, 17, 17, 17],
        "B": [30, 17, 17, 30, 17, 17, 30],
        "C": [14, 17, 16, 16, 16, 17, 14],
        "D": [30, 17, 17, 17, 17, 17, 30],
        "E": [31, 16, 16, 30, 16, 16, 31],
        "F": [31, 16, 16, 30, 16, 16, 16],
        "G": [14, 17, 16, 23, 17, 17, 15],
        "H": [17, 17, 17, 31, 17, 17, 17],
        "I": [14, 4, 4, 4, 4, 4, 14],
        "J": [7, 2, 2, 2, 2, 18, 12],
        "K": [17, 18, 20, 24, 20, 18, 17],
        "L": [16, 16, 16, 16, 16, 16, 31],
        "M": [17, 27, 21, 21, 17, 17, 17],
        "N": [17, 25, 21, 19, 17, 17, 17],
        "O": [14, 17, 17, 17, 17, 17, 14],
        "P": [30, 17, 17, 30, 16, 16, 16],
        "Q": [14, 17, 17, 17, 21, 18, 13],
        "R": [30, 17, 17, 30, 20, 18, 17],
        "S": [15, 16, 16, 14, 1, 1, 30],
        "T": [31, 4, 4, 4, 4, 4, 4],
        "U": [17, 17, 17, 17, 17, 17, 14],
        "V": [17, 17, 17, 17, 17, 10, 4],
        "W": [17, 17, 17, 21, 21, 21, 10],
        "X": [17, 17, 10, 4, 10, 17, 17],
        "Y": [17, 17, 10, 4, 4, 4, 4],
        "Z": [31, 1, 2, 4, 8, 16, 31],
    ]
}
