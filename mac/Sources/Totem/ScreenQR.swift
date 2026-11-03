import AppKit
import CoreImage.CIFilterBuiltins
import ScreenCaptureKit
import Vision

/// Finds authenticator QR codes anywhere on your screens, no phone needed.
enum ScreenQR {
    enum ScanError: LocalizedError {
        case permission, nothingFound
        var errorDescription: String? {
            switch self {
            case .permission:
                return "Totem needs Screen Recording permission to read QR codes. Turn it on in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
            case .nothingFound:
                return "No authenticator QR code on screen. Open the site's 2FA setup page so the QR code is visible, then scan again."
            }
        }
    }

    static func scanScreens() async throws -> [String] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScanError.permission
        }
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        var found: [String] = []
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let config = SCStreamConfiguration()
            let scale = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }?
                .backingScaleFactor ?? 2
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { continue }
            found += decode(image)
        }
        let links = Array(Set(found.filter { $0.hasPrefix("otpauth://") || $0.hasPrefix("otpauth-migration://") }))
        if links.isEmpty { throw ScanError.nothingFound }
        return links
    }

    static func decode(_ image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    static func decode(fileURL: URL) -> [String] {
        guard let img = NSImage(contentsOf: fileURL), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        return decode(cg)
    }

    /// A QR code image for moving an account to a phone.
    static func image(for text: String, size: CGFloat = 220) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: size / out.extent.width, y: size / out.extent.height))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
