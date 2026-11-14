import Foundation
@testable import VauldyCore
@main struct Probe {
 static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),out=URL(fileURLWithPath:CommandLine.arguments[2]);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
  for file in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter({$0.pathExtension=="png"}).sorted(by:{$0.lastPathComponent<$1.lastPathComponent}) {
   let result=try await NativeLocalDocumentOCR().recognize(file:file){_ in};try JSONEncoder().encode(result.pages[0]).write(to:out.appendingPathComponent(file.lastPathComponent+".json"));print(file.lastPathComponent+" "+result.pages[0].text.replacingOccurrences(of:"\n",with:" | "))
  }
 }
}
