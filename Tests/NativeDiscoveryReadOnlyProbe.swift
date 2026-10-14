import Foundation
import CryptoKit
@main enum NativeDiscoveryReadOnlyProbe {
    static func hash(_ value: String) -> String { SHA256.hash(data:Data(value.utf8)).map { String(format:"%02x",$0) }.joined() }
    static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-readonly-never-written-"+UUID().uuidString)
        let worker=NativeRenderDiscovery()
        let result=await worker.collect(store:RenderConfigStore(root:root),links:[:],writable:false)
        let observations=result.observations.map { value -> [String:Any] in
            ["pid":value.identity.pid,"birthSeconds":value.identity.birthSeconds,"birthMicroseconds":value.identity.birthMicroseconds,
             "executableBasename":(value.identity.executable as NSString).lastPathComponent,"identity":value.id,
             "sceneBasename":value.scene.map { ($0 as NSString).lastPathComponent } ?? "absent",
             "sceneSHA256":value.scene.map(hash) ?? "absent","scriptBasename":value.script.map { ($0 as NSString).lastPathComponent } ?? "absent",
             "outputQualified":value.outputRoot != nil,"renderCommandExplicit":value.renderCommand,
             "metadataAssociated":value.runID != nil,"activity":value.dashboard(entries:[]).activity.rawValue,
             "stage":value.stage]
        }
        let report:[String:Any]=["observedAt":ISO8601DateFormatter().string(from:Date()),"partial":result.health.partial,
                                "health":result.health.message,"sameUIDOnly":true,"configWritten":FileManager.default.fileExists(atPath:root.path),
                                "providerContacted":false,"rendererStarted":false,"rawArgvPersisted":false,"environmentDecoded":false,
                                "candidates":observations]
        print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    }
}
