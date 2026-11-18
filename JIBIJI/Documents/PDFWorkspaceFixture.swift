#if DEBUG
import PDFKit
import UIKit

/// Public, generated content for disposable UI-test notebooks only.
@MainActor enum PDFWorkspaceFixture {
    static func install(in library: PDFLibrary) {
        guard library.items.isEmpty else { return }
        if UserDefaults.standard.bool(forKey: "JIBIJIScannedPDFFixture") {
            let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
            let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
            let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
                UIColor.white.setFill(); context.fill(bounds)
                "ORCHID laboratory".draw(at: CGPoint(x: 60, y: 100), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 30), .foregroundColor: UIColor.black])
                "A generated scanned worksheet".draw(at: CGPoint(x: 60, y: 160), withAttributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black])
            }
            let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in context.beginPage(); image.draw(in: bounds) }
            _ = try? library.importPDF(data: data, title: "Scanned worksheet")
            return
        }
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for page in 1...2 {
                context.beginPage()
                UIColor.white.setFill(); context.fill(bounds)
                "Mandarin textbook".draw(at: CGPoint(x: 48, y: 50), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 30)])
                "Lesson \(page) · Reading and practice".draw(at: CGPoint(x: 48, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
                "Write your notes below. Original text remains searchable.".draw(at: CGPoint(x: 48, y: 160), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
                for line in 0..<12 {
                    let path = UIBezierPath(); path.move(to: CGPoint(x: 48, y: 240 + line * 36)); path.addLine(to: CGPoint(x: 564, y: 240 + line * 36))
                    UIColor.lightGray.setStroke(); path.lineWidth = 0.3; path.stroke()
                }
            }
        }
        _ = try? library.importPDF(data: data, title: "Mandarin textbook")
    }
}
#endif
