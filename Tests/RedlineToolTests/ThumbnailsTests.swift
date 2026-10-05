#if os(macOS)
import AppKit
import Testing
@testable import RedlineTool

struct ThumbnailsTests {
    private let temporary = TemporaryFolder("ThumbnailsTests")

    @Test func aScreenshotIsDecodedNoBiggerThanAsked() async throws {
        try FileManager.default.createDirectory(at: temporary.url, withIntermediateDirectories: true)
        let file = temporary.url.appending(path: "screen-1.jpg")
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1290,
                pixelsHigh: 2796,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        try #require(bitmap.representation(using: .jpeg, properties: [:])).write(to: file)
        let image = try #require(await Thumbnails.load(file, maxPixels: 240))
        #expect(max(image.size.width, image.size.height) <= 240)
        #expect(Thumbnails.thumbnail(temporary.url.appending(path: "missing.jpg"), maxPixels: 240) == nil)
    }
}
#endif
