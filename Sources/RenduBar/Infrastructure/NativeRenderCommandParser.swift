import Foundation

enum NativeRenderCommandParser {
    static func parse(_ snapshot: NativeProcessSnapshot, at: Date) -> NativeRenderObservation? {
        guard let producer=NativeProcessReader.producer(snapshot.identity.executable) else { return nil }
        var observation=NativeRenderObservation(identity:snapshot.identity,producer:producer,observedAt:at)
        guard let args=snapshot.arguments,args.count<=256,args.allSatisfy({$0.utf8.count<=4096}) else {
            observation.stage="Processus candidat · commande inaccessible";return observation
        }
        if producer=="Blender" { blender(args,&observation) } else { ffmpeg(args,&observation) }
        return observation
    }
    private static func blender(_ args: [String], _ observation: inout NativeRenderObservation) {
        var index=1;var background=false;var output:String?;var start:Int?;var end:Int?;var jump=1
        var actions=0;var ambiguous=false;var scriptSeen=false;var selectedScene:String?
        let noValue:Set<String>=["--factory-startup","--disable-autoexec","-y","--enable-autoexec","--debug","--debug-cycles"]
        let values:Set<String>=["-t","--threads","-E","--engine","-F","--render-format","-x","--use-extension","-S","--scene","--log-level","--python-exit-code"]
        while index<args.count {
            let arg=args[index]
            if arg=="--" {
                // Only the explicit first positional script argument is a job-directory candidate.
                if index+1<args.count { observation.jobDirectory=NativeRenderPaths.absolute(args[index+1]) }
                break
            }
            if arg=="-b" || arg=="--background" { background=true;index+=1;continue }
            if arg=="-r" || arg=="-R" || arg=="--register" || arg=="--register-allusers" { ambiguous=true;index+=1;continue }
            if arg=="--python" || arg=="-P" || arg=="--python-expr" || arg=="--python-text" {
                scriptSeen=true
                if index+1<args.count, arg=="--python" || arg=="-P" { observation.script=NativeRenderPaths.absolute(args[index+1]) }
                index+=2;continue
            }
            if arg=="-o" || arg=="--render-output" || arg=="-s" || arg=="--frame-start" || arg=="-e" || arg=="--frame-end" || arg=="-j" || arg=="--frame-jump" {
                guard index+1<args.count else { ambiguous=true;break }
                let value=args[index+1]
                switch arg {
                case "-o","--render-output": output=NativeRenderPaths.absolute(value,scene:observation.scene)
                case "-s","--frame-start": start=positive(value)
                case "-e","--frame-end": end=positive(value)
                default: jump=positive(value) ?? 0
                }
                index+=2;continue
            }
            if arg=="-a" || arg=="--render-anim" || arg=="-f" || arg=="--render-frame" {
                actions+=1
                var total:Int?
                if arg=="-f" || arg=="--render-frame" {
                    guard index+1<args.count else { ambiguous=true;break }
                    total=frameCount(args[index+1]);index+=1
                } else if let first=start,let last=end,last>=first,jump>0 { total=(last-first)/jump+1 }
                // Snapshot at the action: later output flags do not affect an earlier render.
                observation.outputPattern=output;observation.declaredTotal=total;observation.nativeSceneName=selectedScene
                observation.renderCommand=background && observation.scene != nil
                index+=1;continue
            }
            if values.contains(arg) {
                if index+1>=args.count {ambiguous=true}
                else if arg=="-S" || arg=="--scene" {selectedScene=RenderContextPath.label(args[index+1])}
                index+=2;continue
            }
            if noValue.contains(arg) { index+=1;continue }
            if !arg.hasPrefix("-"),arg.lowercased().hasSuffix(".blend"),let scene=NativeRenderPaths.absolute(arg) {
                if actions>0 { ambiguous=true }
                observation.scene=scene
                // Loading a blend file replaces output/range set before it.
                output=nil;start=nil;end=nil;jump=1;selectedScene=nil
                index+=1;continue
            }
            ambiguous=true;index+=1
        }
        if actions != 1 || scriptSeen || ambiguous {
            observation.renderCommand=false;observation.declaredTotal=nil;observation.outputPattern=nil
            observation.stage=scriptSeen ? "Processus Blender avec script · activité non attribuée" : "Processus Blender candidat · commande non qualifiée"
        } else if observation.renderCommand { observation.stage="Commande de rendu Blender identifiée · activité non attestée" }
        if let pattern=observation.outputPattern { observation.outputRoot=NativeRenderPaths.root(URL(fileURLWithPath:pattern).deletingLastPathComponent().path) }
    }
    private static func ffmpeg(_ args: [String], _ observation: inout NativeRenderObservation) {
        let values:Set<String>=["-i","-c:v","-codec:v","-vcodec","-c:a","-codec:a","-acodec","-c","-codec","-vf","-af","-filter:v","-filter:a","-filter_complex","-r","-s","-pix_fmt","-b:v","-b:a","-crf","-preset","-t","-to","-ss","-frames:v","-vframes","-frames:a","-f","-map","-metadata","-loglevel","-threads","-progress","-vsync","-fps_mode","-bufsize"]
        let switches:Set<String>=["-y","-n","-nostdin","-hide_banner","-an","-vn","-sn","-dn","-shortest"]
        var index=1;var input=false;var outputs:[String]=[];var ambiguous=false;var frameTotal:Int?
        while index<args.count {
            let arg=args[index]
            if switches.contains(arg) { index+=1;continue }
            if values.contains(arg) {
                guard index+1<args.count else { ambiguous=true;break }
                if arg=="-i" { input=true }
                if arg=="-frames:v" || arg=="-vframes" { frameTotal=positive(args[index+1]) }
                index+=2;continue
            }
            if arg.hasPrefix("-") { ambiguous=true;index+=1;continue }
            if let path=NativeRenderPaths.absolute(arg) { outputs.append(path);if index != args.count-1 { ambiguous=true } } else { ambiguous=true }
            index+=1
        }
        guard input,outputs.count==1,!ambiguous else { observation.stage="Processus ffmpeg candidat · sorties non qualifiées";return }
        observation.outputPattern=outputs[0]
        observation.outputRoot=NativeRenderPaths.root(URL(fileURLWithPath:outputs[0]).deletingLastPathComponent().path)
        observation.renderCommand=true;observation.declaredTotal=frameTotal
        observation.stage="Commande ffmpeg identifiée · activité non attestée"
    }
    private static func positive(_ value: String) -> Int? {
        guard value.allSatisfy({$0.isASCII && $0.isNumber}),let number=Int(value),number>0,number<=1_000_000 else { return nil }
        return number
    }
    private static func frameCount(_ value: String) -> Int? {
        var frames=Set<Int>()
        for part in value.split(separator:",",omittingEmptySubsequences:false) {
            let range=part.components(separatedBy:"..")
            if range.count==1 { guard let frame=positive(range[0]) else { return nil };frames.insert(frame) }
            else if range.count==2 {
                guard let first=positive(range[0]),let last=positive(range[1]),last>=first,last-first<=10000 else { return nil }
                frames.formUnion(first...last)
            } else { return nil }
            guard frames.count<=10000 else { return nil }
        }
        return frames.isEmpty ? nil : frames.count
    }
}
