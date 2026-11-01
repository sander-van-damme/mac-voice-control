import Foundation
import VoiceCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

func emit<T: Encodable>(_ value: T) throws {
    let data = try JSONEncoder().encode(value)
    print(String(decoding:data,as:UTF8.self)); fflush(stdout)
}
func choiceResponse(_ q: JevRequest, operation: String, selected: [String:String] = [:]) throws -> JevResponse {
    var answers: [String:Any] = [:]
    for (name, offered) in q.choices {
        let id = name == "operation" ? operation : selected[name] ?? offered.sorted().first!
        answers[name] = ["type":"choice","choice":id,"confidence":1,
            "probabilities":Dictionary(uniqueKeysWithValues:offered.map { ($0,$0 == id ? 1.0 : 0.0) })]
    }
    for (key,value) in ["is_command":1.0,"complete":operation == "done" ? 1.0 : 0.0,"sensitive":0.0,"present":1.0] { answers[key] = ["type":"noul","noul":value] }
    return try JevResponse.decode(JSONSerialization.data(withJSONObject:["model":JevRequest.model,"answers":answers]))
}
@MainActor final class PipeBrowser: DesktopControlling {
    let apps = [AppCandidate(id:"com.google.Chrome",name:"Google Chrome")]
    var supportsTaskPlanning: Bool { true }
    let run = UUID()
    var last: Observation?
    func exchange(_ kind: BrowserCommand.Kind, context: BrowserContext? = nil, action: Action? = nil) throws -> BrowserReply {
        let command = BrowserCommand(runID:run,kind:kind,context:context,action:action)
        try emit(command)
        guard let line = readLine(), let data = line.data(using:.utf8) else { throw VoiceError("Browser pipe closed") }
        let reply = try JSONDecoder().decode(BrowserReply.self,from:data)
        guard reply.id == command.id, reply.ok else { throw VoiceError("Browser refused the fixture action") }
        return reply
    }
    func observe() async throws -> Observation {
        let start = MonotonicTime.now
        guard let snapshot = try exchange(.observe).snapshot else { throw VoiceError("No browser snapshot") }
        let frame = Rect(0,0,1200,800)
        var o = Observation(pid:123,app:"Google Chrome",window:frame,controls:snapshot.controls,focusedID:snapshot.focusedID,
            secureFocus:snapshot.secureFocus,geometry:try .fitted(crop:frame),jpeg:Data(),signature:[])
        o.source = .browser; o.browser = snapshot.context; o.timings["browser_observation_ms"] = (MonotonicTime.now-start)*1000
        last = o; return o
    }
    func isFresh(_ o: Observation, for action: Action) async throws -> Bool { try exchange(.validate,context:o.browser,action:action).ok }
    func execute(_ action: Action, observed o: Observation) async throws { _ = try exchange(.act,context:o.browser,action:action) }
}
@MainActor final class FixtureDecision: Deciding {
    let desktop: PipeBrowser
    var typed = false, submitted = false
    init(_ desktop: PipeBrowser) { self.desktop = desktop }
    func decide(_ q: JevRequest) async throws -> JevResponse {
        let json = try JSONSerialization.jsonObject(with:q.body) as! [String:Any]
        let state = json["state"] as! [String:Any]
        let instruction = (state["current_objective"] as? [String:String])?["instruction"] ?? ""
        let o = desktop.last!
        if instruction.lowercased().hasPrefix("open chrome") { return try choiceResponse(q,operation:"done") }
        if instruction.lowercased().hasPrefix("go to") {
            if let url = q.candidates.urls.first, o.browser?.url != BrowserContext.canonicalURL(url) {
                return try choiceResponse(q,operation:"openURL",selected:["url":"u0"])
            }
            return try choiceResponse(q,operation:"done")
        }
        if instruction.lowercased().hasPrefix("search") {
            if o.controls.contains(where: { $0.date != nil }) { return try choiceResponse(q,operation:"done") }
            if submitted { return try choiceResponse(q,operation:"wait") }
            let field = q.candidates.controls.first { $0.role == "searchbox" }!
            if o.focusedID != field.id { return try choiceResponse(q,operation:"focus",selected:["focus_target":field.id]) }
            if !typed {
                typed = true
                let index = q.candidates.texts.firstIndex(of:"newsletters")!
                return try choiceResponse(q,operation:"typeText",selected:["focus_target":field.id,"text":"t\(index)"])
            }
            submitted = true
            let button = q.candidates.controls.first { $0.label == "Search" }!
            return try choiceResponse(q,operation:"click",selected:["click_target":button.id])
        }
        if o.browser?.url.hasSuffix("/newest") == true { return try choiceResponse(q,operation:"done") }
        let newest = BrowserSelection.newest(query:"newsletters",controls:q.candidates.controls)!
        return try choiceResponse(q,operation:"click",selected:["click_target":newest.id])
    }
}
@MainActor final class LocalDesktop: DesktopControlling, DirectCommandExecuting {
    let apps = [AppCandidate(id:"com.google.Chrome",name:"Google Chrome"),AppCandidate(id:"com.apple.finder",name:"Finder")]
    func observe() async throws -> Observation { throw VoiceError("Direct benchmark unexpectedly observed") }
    func isFresh(_ o: Observation,for a: Action) async throws -> Bool { true }
    func execute(_ a: Action,observed: Observation) async throws { }
    func executeDirect(_ action: Action) async throws -> DirectResult { DirectResult(verified:true) }
}
@MainActor final class NeverDecision: Deciding {
    func decide(_ q: JevRequest) async throws -> JevResponse { throw VoiceError("Direct benchmark unexpectedly used Jev") }
}
struct Report: Codable { let scenario: String; let metrics: CommandMetrics }
@main struct Benchmark {
    @MainActor static func main() async {
        do {
            if CommandLine.arguments.contains("--browser") {
                let url = CommandLine.arguments.last!
                let desktop = PipeBrowser()
                let actual = GoalLoop(desktop:desktop,decider:FixtureDecision(desktop))
                actual.maxSteps = 30
                try await actual.run(goal:"Open Chrome, go to \(url), search for newsletters, and open the newest matching result")
                try emit(Report(scenario:"real_chromium_mock_jev",metrics:actual.metrics))
            } else {
                let commands = ["Open Chrome","Open Finder","Open Downloads","Create a new tab","Go to example.org"]
                for goal in commands {
                    for _ in 0..<10 {
                        let loop = GoalLoop(desktop:LocalDesktop(),decider:NeverDecision())
                        try await loop.run(goal:goal)
                        try emit(Report(scenario:goal,metrics:loop.metrics))
                    }
                }
                let frame = Rect(0,0,1200,800)
                var o = Observation(pid:1,app:"Chrome",window:frame,
                    controls:[Control(id:"e1",role:"searchbox",label:"Search website",frame:Rect(0,0,100,30),canFocus:true)],
                    geometry:try .fitted(crop:frame),jpeg:Data(repeating:0xA0,count:300_000),signature:[0])
                let visual = try JevRequest(goal:"search for newsletters",observation:o,apps:[],history:[])
                o.source = .browser
                let semantic = try JevRequest(goal:"search for newsletters",observation:o,apps:[],history:[])
                print("{\"request_size_comparison\":{\"visual_bytes\":\(visual.body.count),\"structured_bytes\":\(semantic.body.count),\"synthetic_jpeg_bytes\":300000}}")
            }
        } catch {
            fputs("Benchmark failed: \(error.localizedDescription)\n",stderr); exit(1)
        }
    }
}
