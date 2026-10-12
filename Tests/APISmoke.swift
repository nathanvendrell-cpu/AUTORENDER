import Foundation
import ImageIO

@main
enum APISmoke {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let base = URL(string: "http://127.0.0.1:4420")!

        func fetch(_ path: String) async throws -> Data {
            let (data, response) = try await session.data(from: base.appendingPathComponent(path))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            return data
        }

        let shadow = try JSONDecoder().decode(ShadowResponse.self, from: await fetch("api/status"))
        let mac = try JSONDecoder().decode(MacResponse.self, from: await fetch("api/mac"))
        let defaults = AppConfig.bootstrap()
        let knownFolders = AppConfig.knownMacMonitorFolders()
        guard shadow.ok, mac.ok,
              let shadowFrame = shadow.latest?.first,
              let macJob = mac.jobs.first(where: { !$0.latest.isEmpty }),
              let macFrame = macJob.latest.first else {
            throw NSError(domain: "RenduBar.APISmoke", code: 1)
        }
        for (label, path) in [
            ("Shadow", "api/frame/" + shadowFrame.name),
            ("Mac", "api/mac/frame/\(macJob.id)/\(macFrame)")
        ] {
            let data = try await fetch(path)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceCreateThumbnailAtIndex(source, 0,
                    [kCGImageSourceCreateThumbnailFromImageAlways: true,
                     kCGImageSourceThumbnailMaxPixelSize: 420] as CFDictionary) != nil else {
                throw NSError(domain: "RenduBar.APISmoke", code: 2)
            }
            print("\(label): aperçu décodable, \(data.count) octets")
        }
        print("API: Shadow \(shadow.brut ?? 0) brutes/\(shadow.post ?? 0) finales ; Mac \(mac.jobs.count) rendus")
        print("Dossiers locaux importables: \(defaults.macFolders.count) Mac ; \(defaults.shadowFolders.count) Shadow")
        let mappedFiles = mac.jobs.compactMap { job -> (String, Date)? in
            guard let folder = knownFolders[job.id], let name = job.latest.first,
                  let timestamp = job.times.last else { return nil }
            return (URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(name).path,
                    RenderDate.parse(timestamp))
        }
        guard !mappedFiles.isEmpty, mappedFiles.allSatisfy({ path, expected in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date else { return false }
            return abs(modified.timeIntervalSince(expected)) <= 2
        }) else {
            throw NSError(domain: "RenduBar.APISmoke", code: 3)
        }
        print("Correspondance vérifiée : \(mappedFiles.count) fichiers de l'API Mac dans leurs dossiers locaux, horodatages à ±2 s")
    }
}
