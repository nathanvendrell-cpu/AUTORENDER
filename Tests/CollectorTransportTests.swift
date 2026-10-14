import Foundation
@main enum CollectorTransportTests {
 static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);let helper=URL(fileURLWithPath:CommandLine.arguments[2])
  async let a=CollectorProcess.asyncRun(arguments:[root.path,"one"],timeout:5,fixtureHelperURL:helper)
  async let b=CollectorProcess.asyncRun(arguments:[root.path,"two"],timeout:5,fixtureHelperURL:helper)
  let results=await (a,b);precondition(results.0 != nil && results.1 != nil,"overlapping helper transports")
  let first=Task {await CollectorProcess.asyncRun(arguments:[root.path,"first"],timeout:5,fixtureHelperURL:helper)}
  for _ in 0..<100 {if FileManager.default.fileExists(atPath:root.appendingPathComponent("first").path){break};try await Task.sleep(for:.milliseconds(10))}
  let queued=Task {await CollectorProcess.asyncRun(arguments:[root.path,"cancelled"],timeout:5,fixtureHelperURL:helper)}
  try await Task.sleep(for:.milliseconds(30));queued.cancel()
  let cancelled=await queued.value;let done=await first.value
  precondition(cancelled == nil && done != nil && !FileManager.default.fileExists(atPath:root.appendingPathComponent("cancelled").path),"cancelled queued helper launched")
  let large=await CollectorProcess.asyncRun(arguments:[root.path,"large"],timeout:5,fixtureHelperURL:helper);precondition(large == nil,"oversized output accepted")
  let imports=await CollectorProcess.asyncRun(arguments:[root.path,"imports"],timeout:5,fixtureHelperURL:helper)
  precondition(imports != nil,"real helper imports did not disable bytecode")
  let resources=helper.deletingLastPathComponent()
  precondition(!FileManager.default.fileExists(atPath:resources.appendingPathComponent("__pycache__").path),"bundle resources mutated by bytecode")
  CollectorProcess.waitForExit()
  print("CollectorTransportTests: serialization, queued cancellation, output cap + real helper imports without bytecode PASS; fixture processes reaped")
 }
}
