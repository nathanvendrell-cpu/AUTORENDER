import Foundation

@MainActor final class ShadowJobMapper {
    private var estimates=QualifiedRenderEstimate()
    private struct Sample {let count:Int?;let media:Double?;let at:Date?;let observed:Date}
    private var previous:[String:Sample]=[:]
    func reset(){previous=[:];estimates.reset()}

    func standard(_ row:ShadowProcessObservation,fresh:Bool) -> RenderDashboardJob {
        guard fresh,row.qualified else{return row.dashboard(fresh:fresh)}
        let observed=RenderDate.parse(row.observedAt),sampled=RenderDate.parseOptional(row.progressObservedAt)
        let old=previous[row.id]
        let advanced=(row.completedFrames.flatMap{n in old?.count.map{n>$0}} ?? false)
            || (row.mediaPositionSeconds.flatMap{n in old?.media.map{n>$0}} ?? false)
        let recent=sampled.flatMap{at in advanced && observed.timeIntervalSince(at)<=20 && old?.at.map({$0<at})==true ? at:nil}
        previous[row.id]=Sample(count:row.completedFrames,media:row.mediaPositionSeconds,at:sampled,observed:observed)
        var eta:Date?
        if let sampled,let count=row.completedFrames,let total=row.totalFrames {
            eta=estimates.estimate(key:row.id+"|frames",completed:Double(count),total:Double(total),sampledAt:sampled,observedAt:observed)
        } else if let sampled,let position=row.mediaPositionSeconds,let duration=row.mediaDurationSeconds {
            eta=estimates.estimate(key:row.id+"|media",completed:position,total:duration,sampledAt:sampled,observedAt:observed)
        }
        trim()
        return row.dashboard(fresh:true,eta:eta,recentProgress:recent)
    }

    func legacy(_ run:ShadowObservedRun,stableFrames:Set<String>,fresh:Bool) -> RenderDashboardJob {
        var job=run.dashboard(fresh:fresh,stableFrames:stableFrames)
        guard fresh,job.isDetectedActiveRender,run.phases.count==1,let stage=run.phases.first else{return job}
        let observed=RenderDate.parse(run.observedAt),key=run.runID+"|"+stage
        let count=stage=="raw" ? run.rawCount:run.postCount
        let old=previous[key]
        let birth=run.claims.filter{$0.phase==stage}.compactMap{RenderDate.parseOptional($0.birth)}.min() ?? observed
        let boundary=old.map{min(birth,$0.observed)} ?? birth
        let times=run.frames.filter{$0.stage==stage && stableFrames.contains(run.runID+"|"+$0.path.lowercased())}
            .compactMap{RenderDate.parseOptional($0.modified)}.filter{$0>=boundary && $0<=observed}.sorted()
        let sampled=times.last
        let advanced=old?.count.map{count>$0}==true
        previous[key]=Sample(count:count,media:nil,at:sampled,observed:observed)
        if advanced,let sampled {job.progressObservedAt=sampled}
        if let sampled {
            let gaps=zip(times,times.dropFirst()).map{$1.timeIntervalSince($0)}.filter{$0>0}
            job.eta=estimates.estimate(key:key,completed:Double(count),total:Double(run.total),sampledAt:sampled,observedAt:observed,seededIntervals:gaps)
        }
        trim()
        return job
    }
    private func trim(){if previous.count>128,let oldest=previous.min(by:{$0.value.observed<$1.value.observed})?.key {previous.removeValue(forKey:oldest)}}
}
