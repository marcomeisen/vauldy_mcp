import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
func require<T>(_ x:T?) throws -> T { guard let x else { throw NSError(domain:"generator",code:1) };return x }
func expect(_ x:Bool) { precondition(x) }
struct LineScan {
    let name: String
    let fields: [String]
    let size: CGFloat
    var gray: CGFloat = 0.05
    var noise: Int = 0
    var gap: CGFloat = 45
    var faintWord: String? = nil
    var faintGray: CGFloat = 0.85
    var fontName = "Helvetica"
    var angle: CGFloat = 0

    func write(to file: URL) throws {
        let width = 840, height = 480
        var pixels = [UInt8](repeating: 255, count: width * height)
        let image = try pixels.withUnsafeMutableBytes { bytes -> CGImage in
            let context = try require(CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: 420, y: 240); context.rotate(by: angle); context.translateBy(x: -420, y: -240)
            for (index, line) in (["Synthetische Zeilenpruefung"] + fields).enumerated() {
                if index > 0, let faintWord {
                    var x: CGFloat = 55
                    let parts = line.split(separator: " ")
                    for (position, part) in parts.enumerated() {
                        let value = String(part) + (position < parts.count - 1 ? " " : "")
                        let attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): CTFontCreateWithName(fontName as CFString, size, nil),
                            .init(kCTForegroundColorAttributeName as String): CGColor(gray: part == faintWord ? faintGray : gray, alpha: 1)]
                        let rendered = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
                        context.textPosition = CGPoint(x: x, y: 410 - CGFloat(index) * gap); CTLineDraw(rendered, context)
                        x += CTLineGetTypographicBounds(rendered, nil, nil, nil)
                    }
                    continue
                }
                let attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): CTFontCreateWithName((index == 0 ? "Helvetica" : fontName) as CFString, index == 0 ? 25 : size, nil),
                    .init(kCTForegroundColorAttributeName as String): CGColor(gray: index == 0 ? 0.05 : gray, alpha: 1)]
                context.textPosition = CGPoint(x: 55, y: 410 - CGFloat(index) * gap)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), context)
            }
            return try require(context.makeImage())
        }
        // Seeded pixel noise is independent of OCR output and expected answers.
        var state: UInt64 = 739245
        if noise > 0 {
            for index in pixels.indices {
                state = state &* 6364136223846793005 &+ 1
                let delta = Int((state >> 32) % UInt64(noise * 2 + 1)) - noise
                pixels[index] = UInt8(max(0, min(255, Int(pixels[index]) + delta)))
            }
        }
        let provider = try require(CGDataProvider(data: Data(pixels) as CFData))
        let noisy = try require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        _ = image // retains the drawing context's image until pixel noise is prepared
        let destination = try require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, noisy, nil)
        expect(CGImageDestinationFinalize(destination))
    }
}

@main struct Generate {
 static func main() throws {
 let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
 for size in [9,13] {
 for (index,field) in ["Beitrag: 82.47 EUR", "Beitrag: 17,29 EUR", "Summe: -39.51 EUR", "Summe: 1.234,56 EUR"].enumerated() {
 try LineScan(name:"source",fields:["Geltungsbereich: Fahrradzubehoer und Kleingeraete","Leistung: Wartung am Aggregat",field],size:CGFloat(size),gray:0.7,noise:5,fontName:"Helvetica-Oblique",angle:0.08).write(to:root.appendingPathComponent("source-\(size)-\(index).png"))
 }
 }
 }
}
