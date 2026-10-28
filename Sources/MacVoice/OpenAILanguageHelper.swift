import Foundation
import VoiceCore

struct OpenAILanguageHelper: LanguageHelping {
    let auth: ChatGPTAuth
    let model: String
    var apiKey: String? = nil
    var injectedSession: URLSession? = nil
    func assist(_ request: LanguageRequest) async throws -> LanguageReply {
        let body = try OpenAIProtocol.body(for:request,model:model)
        let fields = ["request_id":request.id.uuidString,"observation_id":request.observation.id.uuidString,"model":model,"authentication":apiKey == nil ? "chatgpt_oauth" : "api_key"]
        DebugLog.shared.record("chatgpt.request",data:body,fields:fields)
        var rawStream = Data()
        defer {
            DebugLog.shared.record("chatgpt.response_stream",data:rawStream,ext:"txt",fields:fields)
            DebugLog.shared.event("chatgpt.finished",fields)
        }
        let token: String
        if let apiKey { token = apiKey } else { token = try await auth.token() }
        try Task.checkCancellation()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        let session = injectedSession ?? URLSession(configuration:config,delegate:OpenAINoRedirect(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            var http = URLRequest(url:URL(string:OpenAIProtocol.resource+"/responses")!)
            http.httpMethod = "POST"; http.httpBody = body
            http.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
            http.setValue("application/json",forHTTPHeaderField:"Content-Type")
            http.setValue("text/event-stream",forHTTPHeaderField:"Accept")
            let (bytes,response) = try await session.bytes(for:http)
            DebugLog.shared.event("chatgpt.http",fields.merging(["status":String((response as? HTTPURLResponse)?.statusCode ?? 0)]) { _,v in v })
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.value(forHTTPHeaderField:"Content-Type")?.contains("text/event-stream") == true else {
                // Preserve error bodies too, bounded by the same stream budget.
                if DebugLog.shared.isEnabled {
                    for try await byte in bytes {
                        if rawStream.count >= 1_000_000 { break }
                        rawStream.append(byte)
                    }
                }
                throw VoiceError("OpenAI request failed. Check the selected authentication method, model access, and billing or plan limits in Setup.")
            }
            var stream = OpenAIEventStream(), count = 0
            for try await line in bytes.lines {
                if DebugLog.shared.isEnabled { rawStream.append(contentsOf:(line+"\n").utf8) }
                try Task.checkCancellation(); count += line.utf8.count
                guard count <= 1_000_000 else { throw VoiceError("Language response exceeded its limit.") }
                try stream.append(line:line)
                // Responses SSE carries one complete JSON event per data line. Some
                // AsyncBytes line iterators omit blank separators; flush explicitly.
                if line.hasPrefix("data:") { try stream.append(line:"") }
                if stream.completedText != nil { break }
            }
            try stream.append(line:""); try Task.checkCancellation()
            let reply = try stream.finish(); try reply.validate(for:request); return reply
        } onCancel: { session.invalidateAndCancel() }
    }
}
