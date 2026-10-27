import Foundation
import VoiceCore

struct OpenAILanguageHelper: LanguageHelping {
    let auth: ChatGPTAuth
    let model: String
    var apiKey: String? = nil
    func assist(_ request: LanguageRequest) async throws -> LanguageReply {
        let body = try OpenAIProtocol.body(for:request,model:model)
        let token: String
        if let apiKey { token = apiKey } else { token = try await auth.token() }
        try Task.checkCancellation()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        let session = URLSession(configuration:config,delegate:OpenAINoRedirect(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            var http = URLRequest(url:URL(string:OpenAIProtocol.resource+"/responses")!)
            http.httpMethod = "POST"; http.httpBody = body
            http.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
            http.setValue("application/json",forHTTPHeaderField:"Content-Type")
            http.setValue("text/event-stream",forHTTPHeaderField:"Accept")
            let (bytes,response) = try await session.bytes(for:http)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.value(forHTTPHeaderField:"Content-Type")?.contains("text/event-stream") == true else {
                throw VoiceError("OpenAI request failed. Check the selected authentication method, model access, and billing or plan limits in Setup.")
            }
            var stream = OpenAIEventStream(), count = 0
            for try await line in bytes.lines {
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
