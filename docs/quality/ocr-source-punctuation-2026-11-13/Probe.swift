import Foundation
import Vision
import ImageIO
@main struct Probe {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1])
  for file in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter({$0.pathExtension=="png"}).sorted(by:{$0.lastPathComponent<$1.lastPathComponent}) {
   try autoreleasepool {
    let image=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(file as CFURL,nil)!,0,nil)!
    let request=VNRecognizeTextRequest();request.recognitionLevel = CommandLine.arguments.contains("fast") ? .fast : .accurate;request.recognitionLanguages=["de-DE","en-US"];request.automaticallyDetectsLanguage = !CommandLine.arguments.contains("noauto");request.usesLanguageCorrection = CommandLine.arguments.contains("correct");request.minimumTextHeight=0
    try VNImageRequestHandler(cgImage:image).perform([request])
    let readings=(request.results ?? []).map { o in o.topCandidates(3).map { ["text":$0.string,"confidence":$0.confidence] as [String:Any] } }
    let data=try JSONSerialization.data(withJSONObject:["file":file.lastPathComponent,"readings":readings],options:[.sortedKeys]);print(String(decoding:data,as:UTF8.self));fflush(stdout)
   }
  }
 }
}
