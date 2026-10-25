import Foundation

// One estimate channel for frame cadence and media-time throughput. No inferred total.
struct QualifiedRenderEstimate {
    private struct Point {let value:Double;let at:Date}
    private struct Series {var points:[Point];var lastObserved:Date;let total:Double}
    private var series:[String:Series]=[:]

    mutating func estimate(key:String,completed:Double,total:Double,sampledAt:Date,observedAt:Date,
                           maximumObservationGap:Double=120,seededIntervals:[Double]=[]) -> Date? {
        guard completed.isFinite,total.isFinite,completed>=0,total>completed,total<=31_536_000,
              sampledAt<=observedAt,observedAt.timeIntervalSince(sampledAt)<=3600 else {series.removeValue(forKey:key);return nil}
        var value=series[key] ?? Series(points:[],lastObserved:observedAt,total:total)
        if value.total != total || observedAt.timeIntervalSince(value.lastObserved)>maximumObservationGap
            || value.points.last.map({completed<$0.value || sampledAt<$0.at})==true {
            value=Series(points:[],lastObserved:observedAt,total:total)
        }
        value.lastObserved=observedAt
        if value.points.last.map({completed>$0.value && sampledAt>$0.at}) ?? true {
            value.points.append(Point(value:completed,at:sampledAt));value.points=Array(value.points.suffix(16))
        }
        series[key]=value
        if series.count>128 {let oldest=series.min{$0.value.lastObserved<$1.value.lastObserved}?.key;if let oldest {series.removeValue(forKey:oldest)}}
        let measured=zip(value.points,value.points.dropFirst()).compactMap {a,b -> Double? in
            let rate=b.at.timeIntervalSince(a.at)/(b.value-a.value)
            return rate.isFinite && rate>0 ? rate:nil
        }
        let samples=(measured.count>=3 ? measured:seededIntervals).filter{$0.isFinite && $0>0}.sorted()
        guard samples.count>=3 else{return nil}
        let median=samples[samples.count/2]
        let age=observedAt.timeIntervalSince(sampledAt)
        guard age>=0,age<=min(3600,max(120,median*3)) else{return nil}
        let eta=sampledAt.addingTimeInterval((total-completed)*median)
        return eta>observedAt && eta.timeIntervalSince(observedAt).isFinite ? eta:nil
    }
    mutating func discard(_ key:String){series.removeValue(forKey:key)}
    mutating func reset(){series=[:]}
}
