import Foundation
import AppKit
import Combine
import CryptoKit
import ImageIO
import Darwin

enum RenderPreviewStatus: String, Equatable {
    case pending, loading, failed, ready
    var label:String {
        switch self {
        case .pending:return "Aperçu en attente"
        case .loading:return "Chargement de l’aperçu…"
        case .failed:return "Aperçu indisponible"
        case .ready:return "Aperçu prêt"
        }
    }
}

typealias RenderPreviewLoader = (RenderEntry) async -> (NSImage,Data)?

@MainActor final class RenderPreviewStore: ObservableObject {
    @Published private(set) var thumbnails: [String:NSImage] = [:]
    @Published private(set) var states:[String:RenderPreviewStatus]=[:]
    private let storageRoot:URL
    private let session:URLSession
    private let remote:ShadowFolderScanner
    private let collectionEnabled:Bool
    private let injectedPreviewLoader:RenderPreviewLoader?
    private struct OwnerRequest {let entries:[RenderEntry];let roots:[String]}
    private var owners:[String:OwnerRequest]=[:]
    private var compactPreviewsVisible=false
    func setCompactPreviewsVisible(_ visible:Bool){compactPreviewsVisible=visible;rebuildOwners()}
    var visiblePreviewIDs:Set<String>{Set(requestedPreviews.keys)}
    func setCompactPreview(_ entry:RenderEntry?,forJobID jobID:String) {
        guard !jobID.isEmpty,jobID.utf8.count<=256 else{return}
        let entries=entry.flatMap{$0.source == .macFolder && $0.monitorJobID==jobID ? $0:nil}.map{[$0]} ?? []
        setOwner("compact:"+jobID,entries:entries,roots:[])
    }
    private func setOwner(_ owner:String,entries:[RenderEntry],roots:[String]) {
        let images=entries.filter{["png","jpg","jpeg","tif","tiff"].contains(($0.filename as NSString).pathExtension.lowercased())}
        if images.isEmpty {owners.removeValue(forKey:owner)}
        else if owner=="detail" {owners[owner]=OwnerRequest(entries:Array(images.prefix(8)),roots:roots)}
        else if owners[owner] != nil || owners.keys.filter({$0.hasPrefix("compact:")}).count<15 {
            owners[owner]=OwnerRequest(entries:Array(images.prefix(1)),roots:roots)
        }
        rebuildOwners()
    }
    private func rebuildOwners() {
        let ordered=owners.keys.sorted {left,right in
            if left=="detail"{return right != "detail"};if right=="detail"{return false};return left<right
        }
        var union:[RenderEntry]=[],seen=Set<String>(),allRoots=Set<String>()
        for owner in ordered where compactPreviewsVisible || !owner.hasPrefix("compact:") {
            guard let request=owners[owner] else{continue};allRoots.formUnion(request.roots)
            for entry in request.entries where seen.insert(entry.id).inserted && union.count<8 {union.append(entry)}
        }
        replaceVisiblePreviewEntries(union,roots:allRoots.sorted())
    }
    private var roots:[String]=[]
    private var stopping=false
    private let lifetime:RenderTaskLifetime
    private var previewTasks:[String:Task<Void,Never>]=[:]
    private var requestedPreviews:[String:RenderEntry]=[:]
    private var previewGeneration:UInt64=0
    private var failedPreviews=Set<String>()
    private let imageCache=NSCache<NSString,NSImage>()
    init(root:URL,session:URLSession,remote:ShadowFolderScanner,enabled:Bool,loader:RenderPreviewLoader?,lifetime:RenderTaskLifetime? = nil) {
        storageRoot=root;self.session=session;self.remote=remote;collectionEnabled=enabled;injectedPreviewLoader=loader
        self.lifetime=lifetime ?? RenderTaskLifetime()
        imageCache.totalCostLimit=16*1024*1024;imageCache.countLimit=32
    }
    func stop() { stopping=true;lifetime.invalidate();owners=[:];requestedPreviews=[:];previewTasks.values.forEach{$0.cancel()};thumbnails=[:];publishStates() }
    func waitForShutdown() async {for task in Array(previewTasks.values) {await task.value}}
    func status(for entry:RenderEntry)->RenderPreviewStatus {
        guard requestedPreviews[entry.id].map(RenderPreviewRequest.cacheIdentity)==RenderPreviewRequest.cacheIdentity(entry) else{return .pending}
        return states[entry.id] ?? .pending
    }
    private func publishStates() {
        let next=requestedPreviews.mapValues {entry->RenderPreviewStatus in
            if thumbnails[entry.id] != nil {return .ready}
            if entry.state == .pending {return .pending}
            if failedPreviews.contains(entry.id) {return .failed}
            if previewTasks[entry.id] != nil {return .loading}
            return .pending
        }
        if states != next {states=next}
    }
    func isCached(_ entry:RenderEntry)->Bool {imageCache.object(forKey:RenderPreviewRequest.cacheIdentity(entry) as NSString) != nil}
    func setVisiblePreviewEntries(_ candidates:[RenderEntry], roots:[String]) {
        setOwner("detail",entries:candidates,roots:roots)
    }
    private func replaceVisiblePreviewEntries(_ candidates:[RenderEntry], roots:[String]) {
        guard (collectionEnabled || injectedPreviewLoader != nil), !stopping else { return }
        self.roots=roots
        let images = candidates.filter {
            ["png","jpg","jpeg","tif","tiff"].contains(($0.filename as NSString).pathExtension.lowercased())
        }.prefix(8)
        let next = Dictionary(images.map { ($0.id,$0) }, uniquingKeysWith: { _,new in new })
        if Set(next.values.map(RenderPreviewRequest.cacheIdentity)) != Set(requestedPreviews.values.map(RenderPreviewRequest.cacheIdentity)) {
            previewGeneration += 1
            failedPreviews.removeAll()
            for (id,task) in previewTasks {
                if next[id].map(RenderPreviewRequest.cacheIdentity) != requestedPreviews[id].map(RenderPreviewRequest.cacheIdentity) { task.cancel() }
            }
        }
        thumbnails = thumbnails.filter { item in
            next[item.key].map(RenderPreviewRequest.cacheIdentity) == requestedPreviews[item.key].map(RenderPreviewRequest.cacheIdentity)
        }
        requestedPreviews = next
        startRequestedPreviews()
    }

    func retryVisiblePreviews() {
        failedPreviews.subtract(requestedPreviews.keys)
        startRequestedPreviews()
    }

    func reconcileVisiblePreviews(_ snapshot:RenderCatalogSnapshot) {
        guard !owners.isEmpty else { return }
        let indexed=Dictionary(snapshot.jobs.flatMap(\.previewEntries).map { ($0.id,$0) },uniquingKeysWith:{ _,new in new })
        for key in Array(owners.keys) {
            guard let owner=owners[key] else{continue}
            if key.hasPrefix("compact:") {
                let jobID=String(key.dropFirst("compact:".count))
                let latest=snapshot.jobs.first(where:{$0.id==jobID})?.previewEntries.first(where:{$0.source == .macFolder && $0.monitorJobID==jobID && $0.localPreviewProof?.jobID==jobID})
                owners[key]=OwnerRequest(entries:latest.map{[$0]} ?? [],roots:[])
            } else {owners[key]=OwnerRequest(entries:owner.entries.map{indexed[$0.id] ?? $0},roots:owner.roots)}
        }
        rebuildOwners()
    }

    private func startRequestedPreviews() {
        guard !stopping else { return }
        for (id,entry) in requestedPreviews where entry.state != .pending && previewTasks.count < 2 && previewTasks[id] == nil && !failedPreviews.contains(id) {
            let identity=RenderPreviewRequest.cacheIdentity(entry)
            if let cached = imageCache.object(forKey: identity as NSString) { if thumbnails[id] == nil { thumbnails[id] = cached }; continue }
            let generation = previewGeneration
            let cache = cacheURL(identity)
            let roots = self.roots
            previewTasks[id] = Task {
                var succeeded = false
                defer {
                    previewTasks.removeValue(forKey: id)
                    if !succeeded && generation == previewGeneration && !Task.isCancelled { failedPreviews.insert(id) }
                    publishStates()
                    if !stopping { startRequestedPreviews() }
                }
                var decoded:(NSImage,Data)?
                if let injected=injectedPreviewLoader { decoded = await injected(entry) }
                else { decoded = await Task.detached(priority:.utility) { Self.downsampleFile(cache) }.value }
                if decoded == nil && !Task.isCancelled && injectedPreviewLoader == nil {
                    if entry.source == .macFolder, let path=entry.path {
                        decoded = await Task.detached(priority:.utility) {
                            entry.localPreviewProof != nil ? Self.downsampleVerifiedFile(entry):Self.downsampleFile(URL(fileURLWithPath:path))
                        }.value
                    } else if !entry.source.isShadow || CollectorProcess.remoteAccessEnabled {
                        var data: Data?
                        if entry.source == .shadowFolder, let path=entry.path { data = await remote.preview(path,roots:roots,id:identity) }
                        else if let raw=entry.previewURL, let url=URL(string:raw), let result=try? await session.data(from:url),
                                (result.1 as? HTTPURLResponse)?.statusCode == 200 { data=result.0 }
                        if let data, !Task.isCancelled { decoded = await Task.detached(priority:.utility) { Self.downsampleData(data) }.value }
                    }
                }
                guard let decoded, !Task.isCancelled, !stopping, generation == previewGeneration, requestedPreviews[id] != nil else { return }
                imageCache.setObject(decoded.0,forKey:identity as NSString,cost:Int(decoded.0.size.width * decoded.0.size.height * 4))
                thumbnails[id] = decoded.0; succeeded = true;publishStates()
                let bytes=decoded.1
                let lifetime=self.lifetime
                await Task.detached(priority:.utility) {
                    do { try lifetime.check();try Task.checkCancellation();try bytes.write(to:cache,options:.atomic) } catch { }
                }.value
            }
        }
        publishStates()
    }

    private func cacheURL(_ id: String) -> URL {
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return storageRoot.appendingPathComponent("Previews/" + hash + ".jpg")
    }

    func thumbnail(for entry: RenderEntry) -> NSImage? { thumbnails[entry.id] }

    nonisolated private static func downsampleVerifiedFile(_ entry:RenderEntry)->(NSImage,Data)? {
        guard let path=entry.path,let proof=entry.localPreviewProof,proof.jobID==entry.monitorJobID,
              proof.stamp.bytes>0,proof.stamp.bytes<=128*1024*1024 else{return nil}
        let fd=open(path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else{return nil};defer{close(fd)}
        func matches()->Bool {
            var s=stat();return fstat(fd,&s)==0 && (s.st_mode & S_IFMT)==S_IFREG
                && UInt64(s.st_dev)==proof.stamp.device && UInt64(s.st_ino)==proof.stamp.inode && s.st_size==proof.stamp.bytes
                && Int64(s.st_mtimespec.tv_sec)==proof.stamp.modifiedSeconds && Int64(s.st_mtimespec.tv_nsec)==proof.stamp.modifiedNanoseconds
                && Int64(s.st_ctimespec.tv_sec)==proof.changedSeconds && Int64(s.st_ctimespec.tv_nsec)==proof.changedNanoseconds
        }
        guard matches() else{return nil}
        var data=Data(),buffer=[UInt8](repeating:0,count:1024*1024)
        while true {
            guard !Task.isCancelled else{return nil}
            let n=buffer.withUnsafeMutableBytes{Darwin.read(fd,$0.baseAddress,$0.count)}
            if n==0{break};if n<0{if errno==EINTR{continue};return nil}
            guard data.count+n<=proof.stamp.bytes else{return nil};data.append(contentsOf:buffer.prefix(n))
        }
        guard data.count==proof.stamp.bytes,matches(),
              (try? RenderLibraryFileStamp.read(URL(fileURLWithPath:path)))==proof.stamp else{return nil}
        return downsampleData(data)
    }
    nonisolated private static func downsampleFile(_ url: URL) -> (NSImage,Data)? {
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil) else { return nil }; return makeThumbnail(source)
    }
    nonisolated private static func downsampleData(_ data: Data) -> (NSImage,Data)? {
        guard let source=CGImageSourceCreateWithData(data as CFData,nil) else { return nil }; return makeThumbnail(source)
    }
    nonisolated private static func makeThumbnail(_ source: CGImageSource) -> (NSImage,Data)? {
        let options:[CFString:Any] = [kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:420,kCGImageSourceCreateThumbnailWithTransform:true]
        guard let cg=CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary) else { return nil }
        let output=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(output,"public.jpeg" as CFString,1,nil) else { return nil }
        CGImageDestinationAddImage(destination,cg,[kCGImageDestinationLossyCompressionQuality:0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height)),output as Data)
    }
}
