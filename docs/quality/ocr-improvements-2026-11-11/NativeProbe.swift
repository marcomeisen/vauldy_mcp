import Foundation
import VauldyCore
@main struct Probe {
 static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),out=URL(fileURLWithPath:CommandLine.arguments[2])
  try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
  let engine=NativeLocalDocumentOCR()
  for file in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter({$0.pathExtension=="png"}).sorted(by:{$0.path<$1.path}) {
   let result=try await engine.recognize(file:file){_ in}
   try JSONEncoder().encode(result.pages[0]).write(to:out.appendingPathComponent(file.lastPathComponent+".json"))
   print(file.lastPathComponent);fflush(stdout)
  }
 }
}
