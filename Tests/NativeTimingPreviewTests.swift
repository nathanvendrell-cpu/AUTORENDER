import Foundation
import AppKit
import ImageIO
import CryptoKit
import Darwin

@main enum NativeTimingPreviewTests {
    static var checks=0
    static func check(_ value:Bool,_ label:String){checks+=1;precondition(value,label)}
    static func sha(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func json(_ value:Any,_ file:URL)throws{try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:file)}
    static func iso(_ date:Date)->String{let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return f.string(from:date)}
    static func png()throws->Data{
        let rgba=Data([0,255,0,255]),provider=CGDataProvider(data:rgba as CFData)!
        let image=CGImage(width:1,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let data=NSMutableData(),destination=CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,image,nil);guard CGImageDestinationFinalize(destination) else{throw NSError(domain:"fixturePNG",code:1)}
        return data as Data
    }
    @MainActor static func main()async throws {
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("autoren-timing-preview-"+UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
        let now=Date(),born=Date(timeIntervalSince1970:floor(now.timeIntervalSince1970)-20)
        let identity=NativeProcessIdentity(pid:4242,birthSeconds:UInt64(born.timeIntervalSince1970),birthMicroseconds:0,executable:"/Applications/Blender.app/Contents/MacOS/Blender")
        let scene=root.appendingPathComponent("scene.blend"),script=root.appendingPathComponent("producer.py"),job=root.appendingPathComponent("job"),frames=job.appendingPathComponent("frames")
        try fm.createDirectory(at:frames,withIntermediateDirectories:true)
        try Data("synthetic scene, never loaded".utf8).write(to:scene);try Data("# synthetic producer, never run".utf8).write(to:script)
        for file in [scene,script]{try fm.setAttributes([.modificationDate:born.addingTimeInterval(-1)],ofItemAtPath:file.path)}
        let image=try png(),hash=sha(image)
        for frame in 1...3 {
            let p=frames.appendingPathComponent(String(format:"f_%04d.png",frame));try image.write(to:p)
            try fm.setAttributes([.modificationDate:born.addingTimeInterval(Double(frame))],ofItemAtPath:p.path)
        }
        // A newer partial filename cannot enter the receipt preview.
        try image.write(to:frames.appendingPathComponent("_rendering_0004.png"))
        var manifest:[String:Any]=["createdUTC":iso(born.addingTimeInterval(-2)),"scene":scene.path,"renderer":script.path,"sceneSHA256":sha(try Data(contentsOf:scene)),"rendererSHA256":sha(try Data(contentsOf:script)),"blender":identity.executable,"settings":["frames":10,"width":1,"height":1],"reusedNativeFrames":["fromJob":"/never-read-other-job","frames":[1]]]
        let jf=job.appendingPathComponent("job.json"),rf=job.appendingPathComponent("frames_receipt.json")
        try json(manifest,jf)
        var records:[[String:Any]]=[["frame":1,"seconds":100.0,"bytes":image.count,"sha256":hash],["frame":2,"seconds":2.0,"bytes":image.count,"sha256":hash],["frame":3,"seconds":4.0,"bytes":image.count,"sha256":hash]]
        var receipt:[String:Any]=["utc":iso(now.addingTimeInterval(-1)),"state":"RUNNING","pid":4242,"jobSHA256":sha(try Data(contentsOf:jf)),"sceneSHA256":manifest["sceneSHA256"]!,"settings":manifest["settings"]!,"completeFrames":3,"records":records]
        try json(receipt,rf)
        let reader=NativeJobReceiptReader()
        func read()throws->NativeJobReceiptReader.Value{try reader.read(directory:job.path,identity:identity,scene:scene.path,renderer:script.path,now:now)}
        var value=try read()
        check(value.timing?.sampleCount==2 && value.timing?.meanSeconds==3,"durations from same receipt; reused other-job frame excluded")
        check(value.timing?.latestSeconds==4,"latest duration uses latest finalized file timestamp, not record count or poll interval")
        let entry=value.preview!
        check(entry.filename=="f_0003.png" && entry.localPreviewProof?.sha256==hash && entry.monitorJobID==identity.jobID,"latest exact final PNG bound to job/hash/stat")
        check(!entry.filename.contains("_rendering"),"partial PNG excluded even if newer")
        check(RenderPreviewRequest.cacheIdentity(entry)==RenderPreviewRequest.cacheIdentity(entry),"proof cache identity is deterministic")
        _=try read();check(reader.hashReads==2 && reader.previewHashReads==1,"scene/script and finalized PNG not rehashed on unchanged poll")
        var observation=NativeRenderObservation(identity:identity,producer:"Blender",observedAt:now);value.apply(to:&observation)
        let dashboard=observation.dashboard(entries:[])
        check(dashboard.previewEntries==[entry] && dashboard.nativeFrameTiming?.sampleCount==2,"timing and verified preview reach dashboard without folder scan")
        check(dashboard.finalOutputProof==nil && !observation.stableOutputCountVerified,"preview does not grant library completion or movement authority")
        let session=URLSession(configuration:.ephemeral),store=RenderPreviewStore(root:root,session:session,remote:ShadowFolderScanner(),enabled:true,loader:nil)
        store.setCompactPreview(entry,forJobID:identity.jobID)
        check(store.visiblePreviewIDs.isEmpty,"compact decoding defaults to hidden")
        store.setCompactPreviewsVisible(true)
        for _ in 0..<100 where store.status(for:entry) != .ready {try await Task.sleep(nanoseconds:10_000_000)}
        check(store.status(for:entry) == .ready && store.thumbnail(for:entry) != nil,"verified real PNG decodes through existing ImageIO thumbnail pipeline")
        store.setVisiblePreviewEntries([entry],roots:[])
        store.setCompactPreview(nil,forJobID:identity.jobID)
        check(store.visiblePreviewIDs.contains(entry.id),"compact disappearance preserves detail owner")
        var second=entry;second=RenderEntry(id:"second",source:.macFolder,job:"synthetic",filename:entry.filename,modified:entry.modified,state:.stable,path:entry.path,previewURL:nil,monitorJobID:"other-job")
        store.setCompactPreview(second,forJobID:"other-job")
        check(store.visiblePreviewIDs==Set([entry.id,second.id]),"compact and detail ownership form bounded union")
        store.setCompactPreviewsVisible(false)
        check(store.visiblePreviewIDs==Set([entry.id]),"native compact window hide preserves detail and releases compact request")
        store.setCompactPreviewsVisible(true)
        check(store.visiblePreviewIDs==Set([entry.id,second.id]),"native compact window reopen restores retained compact owner")
        store.setVisiblePreviewEntries([],roots:[])
        check(store.visiblePreviewIDs==Set([second.id]),"detail disappearance preserves compact owner")
        store.setCompactPreviewsVisible(false)
        check(store.visiblePreviewIDs.isEmpty,"hidden compact-only window requests no decode")
        store.setCompactPreviewsVisible(true)
        check(store.visiblePreviewIDs==Set([second.id]),"compact-only reopen restores its request")
        store.setCompactPreview(nil,forJobID:"other-job")
        check(store.visiblePreviewIDs.isEmpty,"last owner removal releases requested preview")
        store.stop();await store.waitForShutdown();session.invalidateAndCancel()

        records[2]["seconds"]=true;records[1]["seconds"] = -5
        receipt["records"]=records;try json(receipt,rf);value=try read()
        check(value.timing==nil && value.completed==3,"invalid timing omitted without losing render progress")
        records[1]["seconds"]=2.0;records[2]["seconds"]=1.0e20;receipt["records"]=records;try json(receipt,rf);value=try read()
        check(value.timing?.sampleCount==1 && value.timing?.meanSeconds==2,"implausible duration omitted")
        records[2]["seconds"]=4.0;receipt["records"]=records;try json(receipt,rf)
        let final=frames.appendingPathComponent("f_0003.png")
        try Data("replaced file".utf8).write(to:final)
        reader.beginCollection();value=try read()
        check(value.preview==nil && value.timing?.meanSeconds==3,"changed final file loses preview without losing same-job timing")
        let secondSession=URLSession(configuration:.ephemeral)
        let replacedStore=RenderPreviewStore(root:root.appendingPathComponent("fresh"),session:secondSession,remote:ShadowFolderScanner(),enabled:true,loader:nil)
        replacedStore.setCompactPreviewsVisible(true)
        replacedStore.setCompactPreview(entry,forJobID:identity.jobID)
        for _ in 0..<100 where replacedStore.status(for:entry) != .failed {try await Task.sleep(nanoseconds:10_000_000)}
        check(replacedStore.status(for:entry) == .failed && replacedStore.thumbnail(for:entry)==nil,"post-verification replacement rejected before ImageIO load")
        replacedStore.stop();await replacedStore.waitForShutdown();secondSession.invalidateAndCancel()
        try fm.removeItem(at:final);try fm.createSymbolicLink(at:final,withDestinationURL:frames.appendingPathComponent("f_0002.png"))
        reader.beginCollection();value=try read()
        check(value.preview==nil,"symlink final rejected")

        // A different manifest/receipt is a different timing scope; no cross-job cache reuse.
        manifest.removeValue(forKey:"reusedNativeFrames");try json(manifest,jf)
        records[0]["seconds"]=8.0;records[1]["seconds"]=8.0;records[2]["seconds"]=8.0
        receipt["jobSHA256"]=sha(try Data(contentsOf:jf));receipt["records"]=records;try json(receipt,rf)
        reader.beginCollection();value=try read()
        check(value.timing?.sampleCount==3 && value.timing?.meanSeconds==8,"timing scope resets with new manifest identity")
        print("NativeTimingPreviewTests: \(checks) assertions PASS; PNG fixture decoding only; no renderer or network")
    }
}
