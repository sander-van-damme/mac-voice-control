import AppKit
import Combine
import CryptoKit
import Network
import Security
import VoiceCore

@MainActor final class OAuthLoopback {
    private var listener: NWListener?
    private var pending: CheckedContinuation<URL,Error>?
    private var received: URL?
    private var failure: Error?
    private var expiry: Task<Void,Never>?
    private var connections: [NWConnection] = []
    private let state: String
    init(state: String) { self.state = state }
    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        let listener = try NWListener(using:parameters,on:.any); self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { status in
                Task { @MainActor in
                    guard !resumed else { return }
                    switch status {
                    case .ready:
                        guard let port = listener.port else { return }
                        resumed = true
                        continuation.resume(returning:URL(string:"http://127.0.0.1:\(port.rawValue)/auth/callback")!)
                    case .failed:
                        resumed = true; continuation.resume(throwing:VoiceError("Could not start the local sign-in callback."))
                    case .cancelled:
                        resumed = true; continuation.resume(throwing:CancellationError())
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
            listener.start(queue:DispatchQueue(label:"com.macvoicecontrol.oauth"))
            expiry = Task { [weak self] in
                do { try await Task.sleep(nanoseconds:180_000_000_000) } catch { return }
                self?.cancel(VoiceError("ChatGPT sign-in timed out. Please try again."))
            }
        }
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        connections.append(connection)
        connection.start(queue:DispatchQueue(label:"com.macvoicecontrol.oauth.connection"))
        read(connection,buffer:Data())
    }
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:8192) { data,_,complete,error in
            Task { @MainActor in
                let bytes = buffer + (data ?? Data())
                guard error == nil, bytes.count <= 16_384 else { connection.cancel(); return }
                guard let header = String(data:bytes,encoding:.utf8), header.contains("\r\n\r\n") else {
                    if complete { connection.cancel() } else { self.read(connection,buffer:bytes) }; return
                }
                let first = header.components(separatedBy:"\r\n")[0].split(separator:" ")
                guard first.count == 3, first[0] == "GET", first[1].hasPrefix("/auth/callback?"),
                      let url = URL(string:"http://127.0.0.1:\(self.listener?.port?.rawValue ?? 0)"+first[1]),
                      let components = URLComponents(url:url,resolvingAgainstBaseURL:false),
                      components.queryItems?.filter({$0.name == "state"}).count == 1,
                      components.queryItems?.first(where:{$0.name == "state"})?.value == self.state else {
                    self.reply(connection,success:false); return
                }
                self.reply(connection,success:true)
                self.received = url; self.pending?.resume(returning:url); self.pending = nil
                self.listener?.cancel(); self.expiry?.cancel()
            }
        }
    }
    private func reply(_ connection: NWConnection, success: Bool) {
        let text = success ? "Return to Mac Voice Control to finish connecting ChatGPT." : "This sign-in callback was not accepted."
        let response = "HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(text.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(text)"
        connection.send(content:Data(response.utf8),completion:.contentProcessed { _ in connection.cancel() })
    }
    func result() async throws -> URL {
        if let received { return received }; if let failure { throw failure }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func cancel(_ error: Error = CancellationError()) {
        failure = error; pending?.resume(throwing:error); pending = nil
        listener?.cancel(); connections.forEach { $0.cancel() }; connections.removeAll(); expiry?.cancel()
    }
}

struct ChatGPTModel: Identifiable, Sendable { let id: String; let name: String }

@MainActor final class ChatGPTAccount: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Connect ChatGPT to enable language assistance."
    @Published private(set) var models: [ChatGPTModel] = []
    @Published var model = UserDefaults.standard.string(forKey:"chatGPTModel") ?? "gpt-6-luna" {
        didSet { UserDefaults.standard.set(model,forKey:"chatGPTModel") }
    }
    let auth: ChatGPTAuth
    private var task: Task<Void,Never>?
    private var loopback: OAuthLoopback?
    private var epoch = UUID()
    init() {
        let credentials = try? ChatGPTKeychain.read()
        auth = ChatGPTAuth(credentials:credentials)
        connected = credentials?.sharing == true
        if let credentials { status = credentials.sharing ? "Connected: \(credentials.email ?? "ChatGPT account")" : "Sign in again and enable ChatGPT plan usage." }
    }
    func cancelSignIn() { epoch = UUID(); task?.cancel(); loopback?.cancel(); loopback = nil; busy = false; status = "Sign-in cancelled." }
    func signIn(newAccount: Bool = false) {
        guard !busy else { return }
        busy = true; epoch = UUID(); let run = epoch
        status = "Complete ChatGPT sign-in in your browser…"
        task = Task { [weak self] in
            guard let self else { return }
            var callbackListener: OAuthLoopback?
            defer { callbackListener?.cancel(); if self.epoch == run { self.busy = false; self.loopback = nil } }
            do {
                func random() throws -> String {
                    var bytes = [UInt8](repeating:0,count:32)
                    guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { throw VoiceError("Could not prepare secure sign-in.") }
                    return Data(bytes).base64URLEncoded
                }
                let state = try random(), nonce = try random(), verifier = try random()
                let callback = OAuthLoopback(state:state); callbackListener = callback; loopback = callback
                let redirect = try await callback.start(); try Task.checkCancellation()
                let defaults = UserDefaults.standard
                let oldClient = newAccount ? nil : defaults.string(forKey:"chatGPTClientID")
                let oldSubject = newAccount ? nil : defaults.string(forKey:"chatGPTSubject")
                let host = defaults.string(forKey:"chatGPTHostID") ?? "urn:uuid:"+UUID().uuidString.lowercased()
                defaults.set(host,forKey:"chatGPTHostID")
                var parameters = ["client_id":oldClient ?? "dynamic_agent_client","ext_agent_host_id":host,
                    "response_type":"code","redirect_uri":redirect.absoluteString,
                    "scope":"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                    "resource":OpenAIProtocol.resource,"state":state,"nonce":nonce,
                    "code_challenge_method":"S256","code_challenge":Data(SHA256.hash(data:Data(verifier.utf8))).base64URLEncoded]
                if oldClient == nil { parameters["agent_name_hint"] = "Mac Voice Control" }
                var url = URLComponents(string:"https://auth.openai.com/api/accounts/authorize")!
                url.queryItems = parameters.map { URLQueryItem(name:$0.key,value:$0.value) }
                guard NSWorkspace.shared.open(url.url!) else { throw VoiceError("Could not open ChatGPT sign-in.") }
                let returned = try await callback.result(); try Task.checkCancellation()
                let result = try OAuthValidation.callback(returned,redirect:redirect,state:state,clientID:oldClient)
                let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
                let session = URLSession(configuration:config,delegate:OpenAINoRedirect(),delegateQueue:nil)
                defer { session.invalidateAndCancel() }
                let tokens = try await ChatGPTAuth.exchange(["grant_type":"authorization_code","client_id":result.clientID,
                    "code":result.code,"code_verifier":verifier,"redirect_uri":redirect.absoluteString,
                    "resource":OpenAIProtocol.resource],session:session)
                guard let id = tokens["id_token"] as? String, let access = tokens["access_token"] as? String,
                      let expires = tokens["expires_in"] as? Double, expires.isFinite, expires > 0,
                      let scope = tokens["scope"] as? String, tokens["token_type"] as? String == "Bearer" else { throw VoiceError("ChatGPT sign-in returned incomplete credentials.") }
                let identity = try await OpenAIIdentity.verify(id,clientID:result.clientID,nonce:nonce,subject:oldSubject,session:session)
                try Task.checkCancellation(); guard epoch == run else { throw CancellationError() }
                let credentials = ChatGPTCredentials(clientID:result.clientID,subject:identity.subject,email:identity.email,
                    accessToken:access,refreshToken:tokens["refresh_token"] as? String,idToken:id,
                    expiresAt:Date().addingTimeInterval(expires),scopes:scope.split(separator:" ").map(String.init))
                try await auth.install(credentials)
                try Task.checkCancellation(); guard epoch == run else { throw CancellationError() }
                defaults.set(result.clientID,forKey:"chatGPTClientID"); defaults.set(identity.subject,forKey:"chatGPTSubject")
                connected = credentials.sharing
                status = connected ? "Connected: \(identity.email ?? "ChatGPT account")" : "Signed in. Enable ChatGPT plan usage by signing in again."
                if connected { try await loadModels() }
            } catch is CancellationError { }
            catch { if epoch == run { status = error.localizedDescription } }
        }
    }
    func loadModels() async throws {
        let run = epoch
        let token = try await auth.token()
        var request = URLRequest(url:URL(string:OpenAIProtocol.resource+"/models")!)
        request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration:config,delegate:OpenAINoRedirect(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        let (data,response) = try await session.data(for:request); try Task.checkCancellation()
        guard epoch == run else { throw CancellationError() }
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000,
              let document = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let items = document["models"] as? [[String:Any]] else { throw VoiceError("Connected, but model discovery failed. Refresh models to retry.") }
        models = items.compactMap {
            guard $0["visibility"] as? String == "list", let slug = $0["slug"] as? String,
                  let name = $0["display_name"] as? String else { return nil }; return ChatGPTModel(id:slug,name:name)
        }
        if !models.contains(where:{$0.id == model}), let first = models.first { model = first.id }
    }
    func refreshModels() {
        guard !busy else { return }; busy = true
        let run = epoch
        task = Task { [weak self] in
            guard let self else { return }; defer { if epoch == run { busy = false } }
            do { try await loadModels() } catch { if epoch == run { status = error.localizedDescription } }
        }
    }
    func disconnect() {
        cancelSignIn(); busy = true; connected = false; models = []
        let run = epoch
        task = Task { [weak self] in
            guard let self else { return }; defer { if epoch == run { busy = false } }
            do {
                let revoked = try await auth.disconnect()
                if epoch == run { status = revoked ? "Disconnected." : "Disconnected locally. Remote revocation was not confirmed; disconnect the app in ChatGPT Settings." }
            } catch { if epoch == run { status = error.localizedDescription } }
        }
    }
}

private extension Data {
    var base64URLEncoded: String { base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
}
