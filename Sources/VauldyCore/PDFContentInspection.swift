import Foundation
import CoreGraphics

/// Tracks graphics transforms and descends into forms. Unknown/inline constructs fall back to full-page OCR.
struct PDFContentInspection {
    var imageRects: [CGRect] = []
    var uncertain = false
    static func inspect(_ page: CGPDFPage) -> Self {
        let state = ScanState()
        state.scan(CGPDFContentStreamCreateWithPage(page))
        return Self(imageRects: state.images, uncertain: state.uncertain)
    }
    private final class ScanState {
        var transform = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var images: [CGRect] = []
        var uncertain = false
        var depth = 0
        func scan(_ stream: CGPDFContentStreamRef) {
            guard depth < 12, let table = CGPDFOperatorTableCreate() else { uncertain = true; return }
            depth += 1; defer { depth -= 1 }
            CGPDFOperatorTableSetCallback(table, "q") { _, info in
                guard let info else { return }; let s = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
                s.stack.append(s.transform)
            }
            CGPDFOperatorTableSetCallback(table, "Q") { _, info in
                guard let info else { return }; let s = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
                if let value = s.stack.popLast() { s.transform = value } else { s.uncertain = true }
            }
            CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
                guard let info else { return }; let s = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
                var values = [CGPDFReal](repeating: 0, count: 6)
                for index in (0..<6).reversed() {
                    guard CGPDFScannerPopNumber(scanner, &values[index]) else { s.uncertain = true; return }
                }
                let m = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
                s.transform = m.concatenating(s.transform)
            }
            CGPDFOperatorTableSetCallback(table, "BI") { _, info in
                if let info { Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue().uncertain = true }
            }
            CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
                guard let info else { return }; let s = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
                var name: UnsafePointer<CChar>?
                guard CGPDFScannerPopName(scanner, &name), let name,
                      let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "XObject", name) else { s.uncertain = true; return }
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { s.uncertain = true; return }
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { s.uncertain = true; return }
                switch String(cString: subtype) {
                case "Image":
                    guard s.images.count < 64 else { s.uncertain = true; return }
                    let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(s.transform).standardized
                    guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { s.uncertain = true; return }
                    s.images.append(rect)
                case "Form":
                    let old = s.transform, oldStack = s.stack
                    defer { s.transform = old; s.stack = oldStack }
                    var matrix: CGPDFArrayRef?
                    if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix {
                        var v = [CGPDFReal](repeating: 0, count: 6)
                        for i in 0..<6 { if !CGPDFArrayGetNumber(matrix, i, &v[i]) { s.uncertain = true; return } }
                        s.transform = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(old)
                    }
                    var resources: CGPDFDictionaryRef?
                    CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
                    guard let resources else { s.uncertain = true; return }
                    s.scan(CGPDFContentStreamCreateWithStream(stream, resources, CGPDFScannerGetContentStream(scanner)))
                default: s.uncertain = true
                }
            }
            if !CGPDFScannerScan(CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())) { uncertain = true }
        }
    }
}
