import Foundation
import CryptoKit

struct ShadowFrame: Codable {
    let name: String
    let t: String?
}

struct ShadowTask: Codable {
    let name: String
    let state: String
}

struct ShadowResponse: Codable {
    let ok: Bool
    let now: String?
    let brut: Int?
    let post: Int?
    let latest: [ShadowFrame]?
    let tasks: [ShadowTask]?
    let blender: Int?
    let error: String?
    var total: Int? = nil
    var rawTotal: Int? = nil
    var postTotal: Int? = nil
    var times: [String]? = nil
    var plans: [String: Int]? = nil
    var gpu: String? = nil
    var fetched: String? = nil
    var projectID: String? = nil
    var title: String? = nil
    var workType: RenderWorkType? = nil
    var eta: String? = nil
    var workID: String? = nil
    var versionID: String? = nil
    private enum CodingKeys:String,CodingKey { case ok,now,brut,post,latest,tasks,blender,error,total,rawTotal,postTotal,times,plans,gpu,fetched,projectID,title,eta,workID,versionID,workType }
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        ok = try c.decode(Bool.self,forKey:.ok)
        now = try c.decodeIfPresent(String.self,forKey:.now)
        brut = try c.decodeIfPresent(Int.self,forKey:.brut)
        post = try c.decodeIfPresent(Int.self,forKey:.post)
        latest = try c.decodeIfPresent([ShadowFrame].self,forKey:.latest)
        tasks = try c.decodeIfPresent([ShadowTask].self,forKey:.tasks)
        blender = try c.decodeIfPresent(Int.self,forKey:.blender)
        error = try c.decodeIfPresent(String.self,forKey:.error)
        total = try c.decodeIfPresent(Int.self,forKey:.total)
        rawTotal = try c.decodeIfPresent(Int.self,forKey:.rawTotal)
        postTotal = try c.decodeIfPresent(Int.self,forKey:.postTotal)
        times = try c.decodeIfPresent([String].self,forKey:.times)
        plans = try c.decodeIfPresent([String:Int].self,forKey:.plans)
        gpu = try c.decodeIfPresent(String.self,forKey:.gpu)
        fetched = try c.decodeIfPresent(String.self,forKey:.fetched)
        projectID = try c.decodeIfPresent(String.self,forKey:.projectID)
        title = try c.decodeIfPresent(String.self,forKey:.title)
        eta = try c.decodeIfPresent(String.self,forKey:.eta)
        workID = try c.decodeIfPresent(String.self,forKey:.workID)
        versionID = try c.decodeIfPresent(String.self,forKey:.versionID)
        workType = (try c.decodeIfPresent(String.self,forKey:.workType)).flatMap(RenderWorkType.init(rawValue:))
    }

}

struct MacProcess: Codable {
    let cpu: String?
    let ram_mo: Int?
    let duree: String?
}

struct MacJob: Codable {
    let id: String
    let titre: String
    let sous: String?
    let total: Int
    let faites: Int
    let en_cours: [String]
    let latest: [String]
    let times: [String]
    let proc: MacProcess?
    let workType: RenderWorkType?
    let projectID: String?
    var workID: String? = nil
    var versionID: String? = nil
    var processReported = true
    var eta: String? = nil

    var progress: RenderProgress? { RenderProgress(completed: faites, total: total) }

    private enum CodingKeys: String, CodingKey { case id, titre, sous, total, faites, en_cours, latest, times, proc, workType, projectID, eta, workID, versionID }

    init(id: String, titre: String, sous: String?, total: Int, faites: Int, en_cours: [String],
         latest: [String], times: [String], proc: MacProcess?, workType: RenderWorkType? = nil, projectID: String? = nil) {
        self.id = id; self.titre = titre; self.sous = sous; self.total = total; self.faites = faites
        self.en_cours = en_cours; self.latest = latest; self.times = times; self.proc = proc; self.workType = workType; self.projectID = projectID
    }

    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        id = try v.decode(String.self, forKey: .id)
        titre = try v.decode(String.self, forKey: .titre)
        sous = try v.decodeIfPresent(String.self, forKey: .sous)
        total = try v.decodeIfPresent(Int.self, forKey: .total) ?? 0
        faites = try v.decodeIfPresent(Int.self, forKey: .faites) ?? -1
        en_cours = try v.decodeIfPresent([String].self, forKey: .en_cours) ?? []
        latest = try v.decodeIfPresent([String].self, forKey: .latest) ?? []
        times = try v.decodeIfPresent([String].self, forKey: .times) ?? []
        proc = try v.decodeIfPresent(MacProcess.self, forKey: .proc)
        workID = try v.decodeIfPresent(String.self, forKey: .workID)
        versionID = try v.decodeIfPresent(String.self, forKey: .versionID)
        processReported = v.contains(.proc)
        eta = try v.decodeIfPresent(String.self, forKey: .eta)
        workType = (try v.decodeIfPresent(String.self, forKey: .workType)).flatMap(RenderWorkType.init(rawValue:))
        projectID = try v.decodeIfPresent(String.self, forKey: .projectID)
    }
}

struct MacResponse: Codable {
    let ok: Bool
    let now: String?
    let jobs: [MacJob]
}

