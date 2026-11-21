import AppKit
import PDFKit
import Vision

/// OCR for PDF pages without a text layer, using Vision (on-device).
/// Returns recognized text keyed by page number.
public enum OCR {
    public static func run(path: String, pages: [Int]) -> [String: String] {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return [:] }
        var out: [String: String] = [:]
        for number in pages {
            autoreleasepool {
                guard let page = doc.page(at: number - 1), let image = render(page) else { return }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                if !lines.isEmpty { out[String(number)] = lines.joined(separator: "\n") }
            }
        }
        return out
    }

    /// Renders the page about 2,000 px on its long side.
    private static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = 2000 / max(box.width, box.height)
        let size = NSSize(width: box.width * scale, height: box.height * scale)
        var rect = NSRect(origin: .zero, size: size)
        return page.thumbnail(of: size, for: .cropBox).cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
