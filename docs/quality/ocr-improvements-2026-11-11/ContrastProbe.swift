import Foundation
import Vision
import ImageIO
import CoreGraphics

func enhanced(_ image: CGImage, mode: Int) -> CGImage? {
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 255, count: w*h)
    pixels.withUnsafeMutableBytes { b in
        let c = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        c.draw(image, in: CGRect(x:0,y:0,width:w,height:h))
    }
    let original = pixels
    if mode > 0 {
        for y in 1..<(h-1) { for x in 1..<(w-1) {
            if mode == 1 {
                var sum = 0
                for dy in -1...1 { for dx in -1...1 {
                    sum += Int(original[(y+dy)*w+x+dx]) * (dy == 0 ? 2 : 1) * (dx == 0 ? 2 : 1)
                }}
                pixels[y*w+x] = UInt8(sum/16)
            } else if mode == 2 {
                var values: [UInt8] = []
                for dy in -1...1 { for dx in -1...1 { values.append(original[(y+dy)*w+x+dx]) }}
                pixels[y*w+x] = values.sorted()[4]
            } else {
                pixels[y*w+x] = UInt8((Int(original[y*w+x])*4 + Int(original[y*w+x-1])+Int(original[y*w+x+1])+Int(original[(y-1)*w+x])+Int(original[(y+1)*w+x]))/8)
            }
        }}
    }
    let sorted = pixels.sorted()
    var border: [UInt8] = []
    for y in 0..<h { for x in 0..<w where (y >= 1 && y < 4) || (y >= h-4 && y < h-1) || (x >= 1 && x < 4) || (x >= w-4 && x < w-1) { border.append(pixels[y*w+x]) }}
    border.sort()
    let black = Double(sorted[sorted.count/100]), white = Double(border[border.count/100])
    let gain = min(32, 255/max(1,white-black))
    let adjusted = pixels.map { UInt8(max(0,min(255,255+(Double($0)-white)*gain))) }
    return CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:[],provider:CGDataProvider(data:Data(adjusted) as CFData)!,decode:nil,shouldInterpolate:true,intent:.defaultIntent)
}
@main struct Probe {
 static func main() throws {
    let root=URL(fileURLWithPath:CommandLine.arguments[1]), out=URL(fileURLWithPath:CommandLine.arguments[2])
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    for file in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter({$0.pathExtension=="png" && $0.lastPathComponent.hasPrefix("grid-")}).sorted(by:{$0.path<$1.path}) {
        let source=CGImageSourceCreateWithURL(file as CFURL,nil)!, image=CGImageSourceCreateImageAtIndex(source,0,nil)!
        let boxes=try OCRFaintRasterRegions.proposals(in:image,checkCancellation:{})
        for mode in 0...3 {
            var strings:[String]=[]
            for box in boxes {
                let crop=box.insetBy(dx:-12,dy:-max(8,box.height)).integral.intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
                guard let raw=image.cropping(to:crop), let contrast=enhanced(raw,mode:mode) else {continue}
                let scale=min(6,48/box.height)
                let c=CGContext(data:nil,width:Int(crop.width*scale),height:Int(crop.height*scale),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
                c.interpolationQuality = .high; c.draw(contrast,in:CGRect(x:0,y:0,width:c.width,height:c.height))
                let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.recognitionLanguages=["de-DE","en-US"];request.automaticallyDetectsLanguage=true;request.usesLanguageCorrection=true
                try VNImageRequestHandler(cgImage:c.makeImage()!).perform([request])
                strings += (request.results ?? []).compactMap{$0.topCandidates(1).first?.string}
            }
            try strings.joined(separator:"\n").write(to:out.appendingPathComponent(file.lastPathComponent+".\(mode).txt"),atomically:true,encoding:.utf8)
            print("\(file.lastPathComponent) mode=\(mode) boxes=\(boxes.count) \(strings)");fflush(stdout)
        }
    }
 }
}
