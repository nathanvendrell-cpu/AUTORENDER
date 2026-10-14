import Foundation
import AppKit
actor PreviewProbe {
 var calls=0
 var failures=0
 var delay:UInt64=0
 func load(_ entry:RenderEntry) async -> (NSImage,Data)? {
  calls+=1
  if delay>0 { try? await Task.sleep(nanoseconds:delay) }
  if failures>0 { failures-=1;return nil }
  return (NSImage(size:NSSize(width:2,height:2)),Data([1]))
 }
 func setFailure(_ count:Int) {failures=count}
 func setDelay(_ value:UInt64) {delay=value}
 func count()->Int {calls}
}
@main enum ConfigurationPreviewTests {
 static var checks=0
 static func check(_ value:Bool,_ message:String) {checks+=1;precondition(value,message)}
 @MainActor static func main() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("configuration-preview-tests-"+UUID().uuidString,isDirectory:true)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:root)}
  for (index,bytes) in [Data("broken JSON".utf8),Data(#"{"schemaVersion":99,"macFolders":[]}"#.utf8),Data(#"{"macFolders":12,"shadowFolders":[]}"#.utf8)].enumerated() {
   let folder=root.appendingPathComponent("bad-\(index)");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
   let file=folder.appendingPathComponent("config.json");try bytes.write(to:file)
   let model=MonitorModel(storageRoot:folder,collectionEnabled:false)
   check(model.configurationError != nil,"invalid/future config not reported")
   model.addMacFolder(root);model.setFolderWorkType(.video,path:root.path)
   check(try Data(contentsOf:file)==bytes,"existing invalid config overwritten at init or setter")
   model.stop()
  }
  let missing=root.appendingPathComponent("missing")
  let fresh=MonitorModel(storageRoot:missing,collectionEnabled:false)
  check(FileManager.default.fileExists(atPath:missing.appendingPathComponent("config.json").path) && fresh.configurationError==nil,"missing config not bootstrapped")
  fresh.stop()
  let valid=root.appendingPathComponent("valid");try FileManager.default.createDirectory(at:valid,withIntermediateDirectories:true)
  let validData=try JSONEncoder().encode(AppConfig(macFolders:["/tmp/chosen"],dismissedMacFolders:["/tmp/removed"]))
  try validData.write(to:valid.appendingPathComponent("config.json"))
  let preserved=MonitorModel(storageRoot:valid,collectionEnabled:false)
  check(preserved.config.dismissedMacFolders==["/tmp/removed"] && preserved.configurationError==nil,"valid config migration loses removal")
  preserved.stop()
  let probe=PreviewProbe()
  let model=MonitorModel(storageRoot:root.appendingPathComponent("preview"),collectionEnabled:false,previewLoader:{entry in await probe.load(entry)})
  defer {model.stop()}
  let first=RenderEntry(id:"same",source:.macFolder,job:"fixture",filename:"frame.png",modified:Date(timeIntervalSince1970:1),state:.pending,path:nil,previewURL:nil)
  var stable=first;stable.state = .stable
  check(RenderPreviewRequest.fingerprint(entries:[first]) != RenderPreviewRequest.fingerprint(entries:[stable]),"pending/stable UI fingerprint unchanged")
  check(RenderPreviewRequest.cacheIdentity(first)==RenderPreviewRequest.cacheIdentity(stable),"state alone invalidates valid image cache")
  model.setVisiblePreviewEntries([first]);try await Task.sleep(for:.milliseconds(30))
  check(await probe.count()==0,"pending image loaded")
  model.setVisiblePreviewEntries([stable]);try await Task.sleep(for:.milliseconds(80))
  check(await probe.count()==1 && model.thumbnail(for:stable) != nil,"same-ID pending/stable did not load")
  model.setVisiblePreviewEntries([stable]);try await Task.sleep(for:.milliseconds(30))
  check(await probe.count()==1,"unchanged request downloads redundantly")
  var changed=stable;changed=RenderEntry(id:stable.id,source:.macFolder,job:"fixture",filename:"frame.png",modified:Date(timeIntervalSince1970:2),state:.stable,path:nil,previewURL:nil)
  check(RenderPreviewRequest.cacheIdentity(stable) != RenderPreviewRequest.cacheIdentity(changed),"same-ID modified image shares stale cache")
  model.setVisiblePreviewEntries([changed]);try await Task.sleep(for:.milliseconds(60))
  check(await probe.count()==2,"modified same-ID didn't invalidate")
  var failure=changed;failure=RenderEntry(id:"failure",source:.macFolder,job:"fixture",filename:"frame.png",modified:Date(),state:.stable,path:nil,previewURL:nil)
  await probe.setFailure(1);model.setVisiblePreviewEntries([failure]);try await Task.sleep(for:.milliseconds(60))
  let count=await probe.count();try await Task.sleep(for:.milliseconds(30))
  check(await probe.count()==count,"failed preview loops unbounded")
  model.retryVisiblePreviews();try await Task.sleep(for:.milliseconds(60))
  check(await probe.count()==count+1 && model.thumbnail(for:failure) != nil,"manual retry doesn't wake loader")
  await probe.setDelay(100_000_000)
  let old=RenderEntry(id:"old",source:.macFolder,job:"fixture",filename:"frame.png",modified:Date(),state:.stable,path:nil,previewURL:nil)
  let newer=RenderEntry(id:"new",source:.macFolder,job:"fixture",filename:"frame.png",modified:Date(),state:.stable,path:nil,previewURL:nil)
  model.setVisiblePreviewEntries([old]);try await Task.sleep(for:.milliseconds(10));model.setVisiblePreviewEntries([newer]);try await Task.sleep(for:.milliseconds(180))
  check(model.thumbnail(for:old)==nil && model.thumbnail(for:newer) != nil,"cancelled source publishes stale preview")
  model.setVisiblePreviewEntries([]);model.stop()
  print("ConfigurationPreviewTests: \(checks) assertions passed (mock loaders; no native image/real source IO)")
 }
}
