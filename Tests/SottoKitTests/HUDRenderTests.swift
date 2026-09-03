import AppKit
import SwiftUI
import Testing
@testable import SottoKit

/// Renders each overlay state to a PNG so the design can be inspected without
/// launching the app and holding a key down.
///
/// Output: /tmp/sotto-hud/<state>.png
@Suite("HUD rendering")
struct HUDRenderTests {
    @MainActor
    @Test("Render every overlay state to PNG")
    func renderStates() throws {
        let directory = URL(fileURLWithPath: "/tmp/sotto-hud")
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let states: [(String, HUDState)] = [
            ("recording-quiet", .recording(level: 0.08, partial: "")),
            ("recording-loud", .recording(level: 0.9, partial: "")),
            ("recording-partial", .recording(level: 0.6, partial: "can you send the deck to Sarah")),
            ("transcribing", .transcribing),
            ("message", .message("Didn't catch anything")),
        ]

        for (name, state) in states {
            let model = HUDModel()
            model.state = state

            let renderer = ImageRenderer(
                content: HUDView(model: model)
                    .frame(width: HUDController.size.width, height: HUDController.size.height)
            )
            renderer.scale = 2

            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name).png"))
        }

        print("Rendered \(states.count) states to \(directory.path)")
    }
}
