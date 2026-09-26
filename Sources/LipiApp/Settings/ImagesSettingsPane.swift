import AppKit
import LipiExport

/// Settings → Images (§6.6): how pasted and dropped images are named, the
/// HEIC conversion, and what HTML export does with local images.
@MainActor
public final class ImagesSettingsPane: SettingsFormPane {
    public override func buildRows() {
        let s = settings
        popup("File names:", [("Date and time (2026-01-31-142501-a1b2c3)", AssetPolicy.Naming.timestamp),
                              ("Original name", AssetPolicy.Naming.original)],
              get: s.imageNaming) { s.imageNaming = $0 }
        checkbox("Convert HEIC to JPEG", get: s.convertHEIC) { s.convertHEIC = $0 }
        note("Images go to the front matter's assets folder, or ./assets beside the document.")
        popup("HTML export:", ImageExport.Mode.allCases.map { ($0.title, $0) },
              get: s.exportImages) { s.exportImages = $0 }
    }
}
