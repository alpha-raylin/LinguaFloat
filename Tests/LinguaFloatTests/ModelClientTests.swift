import XCTest
import LinguaCore
@testable import LinguaFloat

final class ModelClientTests: XCTestCase {
    private func line(_ text: String? = nil, finish: String? = nil) throws -> String {
        var choice: [String: Any] = ["index": 0, "delta": text.map { ["content": $0] } ?? [:]]
        if let finish { choice["finish_reason"] = finish }
        let data = try JSONSerialization.data(withJSONObject: ["choices": [choice]])
        return "data: " + String(decoding: data, as: UTF8.self)
    }
    func testRequestMatchesPromptAndMasksInput() throws {
        let client = ModelClient(endpoint: "http://127.0.0.1:11434/v1", model: "qwen2.5:14b", key: "", language: "繁體中文")
        let (request, protected) = try client.request("Please run `git status`.", correct: false)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        XCTAssertEqual(body["reasoning_effort"] as? String, "none", "local reasoning models must not think before a correction")
        let cloud = ModelClient(endpoint: "https://api.example.com/v1", model: "x", key: "k", language: "繁體中文")
        let (cloudRequest, _) = try cloud.request("Hello", correct: false)
        let cloudBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(cloudRequest.httpBody)) as? [String: Any])
        XCTAssertNil(cloudBody["reasoning_effort"], "cloud providers reject the field on non-reasoning models")
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(((body["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["text", "notes"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages[1]["content"], protected.text)
        XCTAssertFalse(protected.text.contains("git status"))
        XCTAssertThrowsError(try client.request(String(repeating: "a", count: 24001), correct: false))
    }
    func testStreamRestoresUnicodeAndProtectedTokens() throws {
        let protected = ProtectedText("請執行 `git status`。")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["text": protected.text, "explanation": ""]), as: UTF8.self)
        var stream = CompletionStream()
        try stream.consume(": keepalive")
        for character in json { try stream.consume(line(String(character))) }
        try stream.consume(line(finish: "stop"))
        try stream.consume("data: [DONE]")
        XCTAssertEqual(try stream.result(protected: protected).text, "請執行 `git status`。")
    }
    func testSchemaCompatibilityAndURLValidation() throws {
        for (endpoint, mode, expected) in [("https://example.com/v1", JSONMode.automatic, false), ("http://localhost:8080/v1", .automatic, false), ("http://[::1]:11434/v1", .automatic, true), ("http://127.0.0.1:11434/v1", .disabled, false), ("https://example.com/v1", .enabled, true)] {
            let client = ModelClient(endpoint: endpoint, model: "test", key: "", language: "繁體中文", jsonMode: mode)
            let (request, _) = try client.request("Hello", correct: false)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["response_format"] != nil, expected)
        }
        let remote = ModelClient(endpoint: "http://example.com/v1", model: "test", key: "", language: "繁體中文")
        XCTAssertThrowsError(try remote.request("Hello", correct: false))
    }
    func testTruncatedValidJSONAndMissingEndAreRejected() throws {
        for reason in ["length", "content_filter", "stop"] {
            var stream = CompletionStream()
            try stream.consume(line(#"{"text":"partial","explanation":""}"#, finish: reason))
            if reason != "stop" { try stream.consume("data: [DONE]") }
            XCTAssertThrowsError(try stream.result(protected: ProtectedText("source")))
        }
    }
    func testInvalidJSONAndLostTokenAreRejected() throws {
        for content in ["not JSON", #"{"text":"missing token","explanation":""}"#, #"{"text":"","explanation":""}"#] {
            var stream = CompletionStream()
            try stream.consume(line(content, finish: "stop"))
            try stream.consume("data: [DONE]")
            XCTAssertThrowsError(try stream.result(protected: ProtectedText("`git status`")))
        }
        var stream = CompletionStream()
        XCTAssertThrowsError(try stream.consume("data: {broken"))
        XCTAssertThrowsError(try stream.consume("{\"choices\":[]}"))
    }
    func testPartialTextStreamsRestoredPlaceholders() {
        let protected = ProtectedText("Run `git status` now")
        let placeholder = protected.text.components(separatedBy: " ")[1]
        XCTAssertEqual(ModelClient.partialText(#"{"text":"Ru"#, protected: protected), "Ru")
        XCTAssertEqual(ModelClient.partialText(#"{"text":"Run \#(placeholder) no"#, protected: protected), "Run `git status` no")
        XCTAssertEqual(ModelClient.partialText(#"{"text":"Run \#(placeholder.prefix(6))"#, protected: protected), "Run ")
        XCTAssertEqual(ModelClient.partialText(#"{"expl"#, protected: protected), "")
    }
    func testProbeListsModels() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = ModelClient(endpoint: "http://127.0.0.1:11434/v1", model: "qwen2.5:14b", key: "secret", language: "繁體中文", session: session)
        let result = try await client.probe()
        XCTAssertEqual(result.models, ["qwen2.5:14b", "qwen2.5:7b"])
        XCTAssertTrue(result.contains("qwen2.5:14b"))
        XCTAssertFalse(result.contains("llama3"))
        let path = await ProbeProtocol.seen
        XCTAssertEqual(path, "/v1/models Bearer secret")
        let remote = ModelClient(endpoint: "http://example.com/v1", model: "x", key: "", language: "繁體中文", session: session)
        do { _ = try await remote.probe(); XCTFail("plain HTTP to a remote host must be refused") } catch {}
    }
    func testPlainModeRequestAndResult() throws {
        let client = ModelClient(endpoint: "http://127.0.0.1:11434/v1", model: "translategemma:4b", key: "", language: "繁體中文", plain: true)
        let (request, protected) = try client.request("Run `git status` now", correct: false)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(body["response_format"], "translation-only models get no JSON schema")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0]["content"]!.hasPrefix("Translate the following segment into Traditional Chinese"))
        XCTAssertTrue(messages[0]["content"]!.hasSuffix(protected.text))
        var stream = CompletionStream()
        try stream.consume(line("現在執行 " + protected.text.components(separatedBy: " ")[1] + "\n"))
        try stream.consume(line(finish: "stop"))
        try stream.consume("data: [DONE]")
        let result = try stream.plainResult(protected: protected)
        XCTAssertEqual(result.text, "現在執行 `git status`")
        XCTAssertEqual(result.explanation, "")
        var truncated = CompletionStream()
        try truncated.consume(line("partial", finish: "length")); try truncated.consume("data: [DONE]")
        XCTAssertThrowsError(try truncated.plainResult(protected: ProtectedText("x")))
    }
    func testStructuredNotesRenderAsLearningLines() throws {
        let json = #"{"text":"I went home.","notes":[{"from":"I has went","to":"I went","why":"過去式"},{"from":"","to":"","why":"其餘正確"}]}"#
        var stream = CompletionStream()
        try stream.consume(line(json, finish: "stop")); try stream.consume("data: [DONE]")
        let result = try stream.result(protected: ProtectedText("I has went home."))
        XCTAssertEqual(result.explanation, "「I has went」→「I went」：過去式\n其餘正確")
        var legacy = CompletionStream()
        try legacy.consume(line(#"{"text":"ok","explanation":"old style"}"#, finish: "stop")); try legacy.consume("data: [DONE]")
        XCTAssertEqual(try legacy.result(protected: ProtectedText("x")).explanation, "old style")
    }
    func testTraditionalSweepAndTargetNames() {
        XCTAssertEqual(ModelClient.traditionalized("工程師们在週一檢查了那個部署服務，发现还有 14 個未處理的請求。", language: "繁體中文"), "工程師們在週一檢查了那個部署服務，發現還有 14 個未處理的請求。")
        XCTAssertEqual(ModelClient.traditionalized("工程師们", language: "English"), "工程師们", "only Traditional targets are swept")
        XCTAssertEqual(ModelClient.traditionalized("Run `git status` now", language: "繁體中文"), "Run `git status` now")
        XCTAssertEqual(ModelClient.plainTargetName("繁體中文"), "Traditional Chinese")
        XCTAssertEqual(ModelClient.plainTargetName("English"), "English")
        XCTAssertEqual(ModelClient.plainTargetName("Deutsch"), "Deutsch")
        XCTAssertTrue(ModelClient.wantsTraditional("zh-Hant"))
        XCTAssertFalse(ModelClient.wantsTraditional("简体中文"))
    }
    func testNotesSplitIntoLines() {
        let joined = "我有以下更正：「has」→「have」(過去時態)；「was」→「were」(複數)；「buyed」→「bought」(不規則動詞): 你寫得很好！"
        let lines = ModelClient.normalizedNotes(joined).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].hasPrefix("「was」"))
        XCTAssertEqual(ModelClient.normalizedNotes("「a」→「b」：one note；fine"), "「a」→「b」：one note；fine", "a single note is left alone")
        XCTAssertEqual(ModelClient.normalizedNotes("「deploy」→「deployment」：<noun form>\\n「it finished」→「it has finished」：<present perfect>"),
                       "「deploy」→「deployment」：noun form\n「it finished」→「it has finished」：present perfect")
        XCTAssertEqual(ModelClient.normalizedNotes("already\nmulti-line →→"), "already\nmulti-line →→")
    }
    func testCorrectionLanguageDriftIsDetected() {
        XCTAssertTrue(ModelClient.translatedInsteadOfCorrected(input: "She dont know.", output: "她不知道。"))
        XCTAssertFalse(ModelClient.translatedInsteadOfCorrected(input: "She dont know.", output: "She doesn't know."))
        XCTAssertFalse(ModelClient.translatedInsteadOfCorrected(input: "我昨天去學校了吗", output: "我昨天去學校了嗎"))
    }
    func testTransportErrorsAreDistinct() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for (path, expected) in [("timeout", "逾時"), ("offline", "無法連線"), ("http", "HTTP 404"), ("cancel", "cancel")] {
            let client = ModelClient(endpoint: "http://localhost/\(path)", model: "test", key: "", language: "繁體中文", session: session)
            do {
                _ = try await client.run("Hello", correct: false)
                XCTFail("Expected failure: \(path)")
            } catch {
                if expected == "cancel" { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription) }
            }
        }
    }
    func testLiveOllama() async throws {
        guard ProcessInfo.processInfo.environment["LINGUAFLOAT_LIVE_TEST"] == "1" else { throw XCTSkip("Opt-in local Ollama integration test") }
        let client = ModelClient(endpoint: "http://127.0.0.1:11434/v1", model: "qwen2.5:14b", key: "", language: "繁體中文")
        let subjects = ["authentication", "billing", "search", "notifications", "storage", "analytics", "deployment", "monitoring", "backup", "routing", "permissions", "scheduling"]
        let templates = [
            "The engineers inspected the %@ service on Monday and discovered %d pending requests. They agreed to review the logs before changing the configuration.",
            "During the afternoon review, the %@ team recorded %d failed checks. The operator must verify the updated settings and notify the owner before restarting.",
            "The latest report for %@ includes %d observations. Each finding requires a separate explanation, a proposed resolution, and a date for the next review."
        ]
        let long = subjects.enumerated().flatMap { index, subject in templates.enumerated().map { offset, template in String(format: template, subject, index * 7 + offset + 1) } }.joined(separator: "\n\n")
        for (name, source, correct) in [("short", "Please check the deployment status.", false), ("correction", "She go to school yesterday. Please check `git status`.", true), ("long", long, false)] {
            let started = Date()
            var updates = 0
            var firstProgress: TimeInterval?
            let result = try await client.run(source, correct: correct) { partial in
                updates += 1
                if !partial.isEmpty, firstProgress == nil { firstProgress = Date().timeIntervalSince(started) }
            }
            XCTAssertFalse(result.text.isEmpty)
            XCTAssertGreaterThan(updates, 0)
            if correct { XCTAssertTrue(result.text.contains("`git status`")) }
            print("LIVE \(name) seconds=\(Date().timeIntervalSince(started)) input=\(source.count) output=\(result.text.count) progress=\(updates) first=\(firstProgress ?? -1)")
        }
    }
    func testLiveCorrectionNotes() async throws {
        guard ProcessInfo.processInfo.environment["LINGUAFLOAT_LIVE_TEST"] == "1" else { throw XCTSkip("Opt-in local Ollama integration test") }
        let model = ProcessInfo.processInfo.environment["LINGUAFLOAT_MODEL"] ?? "qwen2.5:14b"
        let client = ModelClient(endpoint: "http://127.0.0.1:11434/v1", model: model, key: "", language: "繁體中文")
        let started = Date()
        let result = try await client.run("I has went to the store yesterday and buyed three apple, but they was not fresh.", correct: true)
        print("LIVE \(model) seconds=\(Date().timeIntervalSince(started)) corrected: \(result.text)\nLIVE notes:\n\(result.explanation)")
        XCTAssertFalse(result.explanation.isEmpty, "a learner expects notes on every correction")
        XCTAssertTrue(result.explanation.contains("→"), result.explanation)
    }
    func testLivePlainTranslation() async throws {
        guard ProcessInfo.processInfo.environment["LINGUAFLOAT_LIVE_TEST"] == "1" else { throw XCTSkip("Opt-in local Ollama integration test") }
        let model = ProcessInfo.processInfo.environment["LINGUAFLOAT_TRANSLATION_MODEL"] ?? "translategemma:4b"
        let client = ModelClient(endpoint: "http://127.0.0.1:11434/v1", model: model, key: "", language: "繁體中文", plain: true)
        let started = Date()
        let result = try await client.run("The engineers inspected the deployment service on Monday and found 14 pending requests. Run `git status` before changing anything.", correct: false)
        print("LIVE plain \(model) seconds=\(Date().timeIntervalSince(started)) text=\(result.text)")
        XCTAssertTrue(result.text.contains("`git status`"), result.text)
        XCTAssertTrue(result.explanation.isEmpty)
        XCTAssertTrue(ModelClient.translatedInsteadOfCorrected(input: "x", output: result.text), "expected CJK output")
    }
    func testLiveCancellationAndDeadline() async throws {
        guard ProcessInfo.processInfo.environment["LINGUAFLOAT_LIVE_TEST"] == "1" else { throw XCTSkip("Opt-in local Ollama integration test") }
        let source = (1...40).map { "Section \($0): The engineers reviewed the deployment configuration and recorded \($0 * 7) observations before restarting the service." }.joined(separator: "\n")
        let client = ModelClient(endpoint: "http://127.0.0.1:11434/v1", model: "qwen2.5:14b", key: "", language: "繁體中文", timeout: 10)
        let task = Task { try await client.run(source, correct: false) }
        try await Task.sleep(for: .milliseconds(700))
        let cancelled = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 5)
        let started = Date()
        do { _ = try await client.run(source, correct: false); XCTFail("Expected deadline") }
        catch { XCTAssertTrue(error.localizedDescription.contains("逾時"), error.localizedDescription) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        print("LIVE cancellation and 10-second streaming resource deadline verified")
    }
}

private final class ProbeProtocol: URLProtocol {
    nonisolated(unsafe) static var seen = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen = "\(request.url!.path) \(request.value(forHTTPHeaderField: "Authorization") ?? "")"
        let body = #"{"object":"list","data":[{"id":"qwen2.5:14b","object":"model"},{"id":"qwen2.5:7b","object":"model"}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class FailureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path.contains("http") {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let code: URLError.Code = path.contains("timeout") ? .timedOut : path.contains("cancel") ? .cancelled : .cannotConnectToHost
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }
    override func stopLoading() {}
}
