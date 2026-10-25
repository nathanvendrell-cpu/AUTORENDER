import Foundation
@main struct Check {
 static func main() throws {
  var count = 0
  for requested in [false, true] { for canonical in [false, true] {
   precondition(MacOnlyStartupPolicy.shouldApply(requested: requested, canonical: canonical) == (requested && canonical)); count += 1
  }}
  let cases: [(Bool,Bool,Bool?,String)] = [(true,false,false,"saved"),(true,false,true,"runtime-only-persistence-failed"),(true,false,nil,"runtime-only-persistence-failed"),(true,true,false,"runtime-disable-failed"),(false,false,false,"rejected-noncanonical")]
  for (canonical,runtime,persisted,state) in cases {
   let line = MacOnlyStartupPolicy.diagnostic(canonical: canonical,runtimeShadowEnabled: runtime,persistedShadowEnabled: persisted)!
   let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String:Any]
   precondition(value["state"] as? String == state); precondition(value["runtimeShadowMonitoringEnabled"] as? Bool == runtime)
   precondition(line.count < 320 && !line.contains("/Users/")); count += 3
  }
  print("PASS \(count) mac-only startup gate and honest persistence-report checks; no application launch")
 }
}
