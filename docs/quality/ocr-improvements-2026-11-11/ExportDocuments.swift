import Foundation
import Vision
@main struct Export {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1])
  for file in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter({$0.pathExtension=="json" && !$0.lastPathComponent.contains(".tables.")}) {
   let result=try JSONDecoder().decode([DocumentObservation].self,from:Data(contentsOf:file))
   let tables=result.flatMap{$0.document.tables}.map { table in
    table.rows.map { row in row.map { cell -> [String:Any] in
      ["text":cell.content.text.transcript,"rows":[cell.rowRange.lowerBound,cell.rowRange.upperBound],"columns":[cell.columnRange.lowerBound,cell.columnRange.upperBound]]
    }}
   }
   let object:[String:Any] = ["tables":tables,"lines":result.flatMap{$0.document.text.lines}.map{$0.transcript}]
   try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:file.deletingPathExtension().appendingPathExtension("tables.json"))
  }
 }
}
