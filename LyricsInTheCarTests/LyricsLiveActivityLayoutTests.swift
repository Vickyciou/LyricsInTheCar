import SwiftUI
import UIKit
import XCTest

@MainActor
final class LyricsLiveActivityLayoutTests: XCTestCase {
    func testLongActiveLyricAndNextLyricBothRenderWithoutVerticalCompression() throws {
        let state = LyricsActivityAttributes.ContentState(
            track: .init(title: "花都開好了", artist: "S.H.E"),
            display: .lyric(
                text: "顏色艷了 香味香了 花都開好了",
                next: "你是我的 我有愛了 世界完成了",
                isPaused: false
            ),
            revision: 1
        )
        let subject = LockScreenLyricsView(state: state)
            .frame(width: 361, height: 160, alignment: .topLeading)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        let controller = UIHostingController(rootView: subject)
        controller.view.bounds = CGRect(x: 0, y: 0, width: 361, height: 160)
        controller.view.backgroundColor = .black
        controller.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: controller.view.bounds.size, format: format).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let textBands = try brightTextBands(in: image)

        XCTAssertGreaterThanOrEqual(
            textBands.count,
            5,
            "Expected title, artist, two active-lyric lines, and the next lyric; rendered bands: \(textBands)"
        )
    }

    private func brightTextBands(in image: UIImage) throws -> [ClosedRange<Int>] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let context = try XCTUnwrap(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let occupiedRows = (0..<height).filter { row in
            (0..<width).reduce(into: 0) { brightPixels, column in
                let offset = row * bytesPerRow + column * 4
                if max(pixels[offset], pixels[offset + 1], pixels[offset + 2]) > 72 {
                    brightPixels += 1
                }
            } >= 3
        }

        return occupiedRows.reduce(into: [ClosedRange<Int>]()) { bands, row in
            guard let previous = bands.last else {
                bands.append(row...row)
                return
            }
            if row - previous.upperBound <= 2 {
                bands[bands.count - 1] = previous.lowerBound...row
            } else {
                bands.append(row...row)
            }
        }
    }
}
