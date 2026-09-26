import AppKit
import LipiExport

/// Settings → Print: what File › Print… and File › Export › PDF… do with
/// images, which theme they use, and the running header and footer. The
/// PDF save panel offers the same choices and stores them here.
@MainActor
public final class PrintSettingsPane: SettingsFormPane {
    public override func buildRows() {
        let s = settings
        popup("Images:", PrintImageMode.allCases.map { ($0.title, $0) }, get: s.pdfImages) { s.pdfImages = $0 }
        popup("Theme:", PrintThemeMode.allCases.map { ($0.title, $0) }, get: s.pdfTheme) { s.pdfTheme = $0 }
        checkbox("Document title at the top", label: "Each page:", get: s.pdfHeader) { s.pdfHeader = $0 }
        checkbox("Page numbers at the foot", get: s.pdfFooter) { s.pdfFooter = $0 }
        note("For Print and PDF export. HTML export's choices are under Images.")
    }
}
