// Swift Testing and Foundation cannot be imported by the same file without
// Xcode (the overlay joining them ships only there), so the tool tests get
// Foundation and the PDF frameworks from here.
@_exported import Foundation
@_exported import CoreGraphics
@_exported import CoreText
@_exported import PDFKit
