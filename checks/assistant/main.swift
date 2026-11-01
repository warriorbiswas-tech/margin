// clang -c -fsanitize=thread checks/assistant/engine.c -o /tmp/engine.o && swiftc -sanitize=thread -import-objc-header checks/assistant/engine.h Margin/Geometry.swift Margin/AI.swift checks/assistant/main.swift /tmp/engine.o -o /tmp/assistant && /tmp/assistant
// The assistant's own code against a stand-in engine: streaming, stopping, leaving the screen, many questions at once, long notes and structured answers.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
func check(_ ok: Bool, _ what: @autoclosure () -> String) {
    if !ok { print("FAIL: \(what())"); exit(1) }
}
final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ s: String) { lock.withLock { values.append(s) } }
    var all: [String] { lock.withLock { values } }
}

let models = FileManager.default.temporaryDirectory.appendingPathComponent("mock-models-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: models) }
ModelFile.directory = models
_ = FileManager.default.createFile(atPath: ModelFile.writing.path.path, contents: Data())
check(AI.isAvailable, "the model counts as installed")

// An answer streams, and the model's reasoning block never shows.
let partials = Box()
let summary = try await AI.summary(of: "Mitosis divides a cell.") { partials.add($0) }
check(summary.hasPrefix("Answer"), "answer text: \(summary.prefix(40))")
check(!summary.contains("think>"), "reasoning is hidden")
check(partials.all.count >= 2, "streamed \(partials.all.count) updates")
check(partials.all.allSatisfy { !$0.contains("think>") }, "partial answers never show the reasoning")

// Stopping ends the answer at once, and the next one works.
mock_set_tokens(1_000_000)
let long = Task { try await AI.complete(system: "s", prompt: "p") }
try await Task.sleep(for: .milliseconds(40))
let stopped = Date()
long.cancel()
do { _ = try await long.value; check(false, "a stopped answer should throw") } catch is CancellationError {}
check(Date().timeIntervalSince(stopped) < 1, "stops promptly")
mock_set_tokens(40)
check(try await AI.complete(system: "s", prompt: "p").hasPrefix("Answer"), "works after a stop")

// Leaving the screen stops the answer and refuses new ones until the app is back.
mock_set_tokens(1_000_000)
let background = Task { try await AI.complete(system: "s", prompt: "p") }
try await Task.sleep(for: .milliseconds(40))
LocalLLM.shared.setInBackground(true)
do { _ = try await background.value; check(false, "going to the background should stop it") } catch is CancellationError {}
do { _ = try await AI.complete(system: "s", prompt: "p"); check(false, "no new work in the background") } catch is CancellationError {}
LocalLLM.shared.setInBackground(false)
mock_set_tokens(40)
check(try await AI.complete(system: "s", prompt: "p").hasPrefix("Answer"), "works again back on screen")

// Many questions at once wait their turn.
let answers = try await withThrowingTaskGroup(of: String.self) { group in
    for i in 0..<12 { group.addTask { try await AI.complete(system: "s", prompt: "q\(i)") } }
    var all: [String] = []
    for try await answer in group { all.append(answer) }
    return all
}
check(answers.count == 12 && answers.allSatisfy { $0.hasPrefix("Answer") }, "twelve at once are all answered")

// Asking while others are being stopped and the app comes and goes.
try await withThrowingTaskGroup(of: Void.self) { group in
    for i in 0..<30 {
        group.addTask {
            let task = Task { try await AI.complete(system: "s", prompt: "r\(i)") }
            if i % 3 == 0 { task.cancel() }
            _ = try? await task.value
        }
    }
    group.addTask {
        for _ in 0..<5 {
            LocalLLM.shared.setInBackground(true)
            try await Task.sleep(for: .milliseconds(3))
            LocalLLM.shared.setInBackground(false)
            LocalLLM.shared.unload()
            LocalLLM.shared.warmUp()
        }
    }
    try await group.waitForAll()
}
check(try await AI.complete(system: "s", prompt: "p").hasPrefix("Answer"), "still answers after the commotion")

// A long note is condensed in pieces, and what was condensed is kept.
let book = (0..<5000).map { "Fact \($0): cells divide in stages. " }.joined()
check(book.count > 100_000, "the book is long enough")
let cache = models.appendingPathComponent("digest-cache.json")
let progress = Box()
var calls = mock_calls()
_ = try await AI.digest(book, using: Digester(cacheURL: cache) { done, total in progress.add("\(done)/\(total)") })
let pieces = TextTools.chunks(book, size: 20_000).count
check(mock_calls() - calls == pieces, "a long note is read in \(pieces) pieces, not \(mock_calls() - calls)")
check(progress.all.first == "0/\(pieces)", "progress starts at the first piece")
calls = mock_calls()
_ = try await AI.digest(book, using: Digester(cacheURL: cache) { _, _ in })
check(mock_calls() == calls, "the second time reads nothing again")

// A piece too long for the model is split until it fits.
mock_set_too_long(9000)
calls = mock_calls()
let dense = try await AI.digest(String(repeating: "Dense text. ", count: 3000))
check(!dense.isEmpty && mock_calls() - calls > 4, "refused pieces were split, \(mock_calls() - calls) requests")
mock_set_too_long(0)

// Structured answers.
let cards = try await AI.flashcards(from: "Mitosis")
check(cards.first?.front == "What is mitosis?", "flashcards decode")
let quiz = try await AI.quiz(from: "Mitosis")
check(quiz.first?.options.first == "Prophase" && quiz.first?.answer == 1, "a quiz decodes and loses its option labels")
let map = try await AI.mindMap(from: "Mitosis")
check(map.title == "Mitosis" && map.children?.first?.children?.first?.title == "Metaphase", "a mind map decodes")
let math = try await AI.math(fromRecognized: "x2 + 1")
check(math.unicode == "x² + 1" && math.latex == "x^{2} + 1", "math decodes")
check(try await AI.folder(for: "Mitosis", among: ["Biology", "History"]) == "Biology", "a folder comes from the list")

// NVIDIA answers first, and anything wrong with it falls back to the model on the iPad.
final class FakeNVIDIA: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var stream = ""
    nonisolated(unsafe) static var offline = false
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var lastKey: String?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "integrate.api.nvidia.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        Self.lastKey = request.value(forHTTPHeaderField: "Authorization")
        if Self.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.stream.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
URLProtocol.registerClass(FakeNVIDIA.self)
func sse(_ words: String...) -> String {
    words.map { #"data: {"choices":[{"delta":{"content":"\#($0)"}}]}"# + "\n\n" }.joined() + "data: [DONE]\n\n"
}
let hello: [(role: String, text: String)] = [("user", "hello")]
FakeNVIDIA.stream = sse("From ", "NVIDIA")
var localCalls = mock_calls()
check(try await AI.respond(cloudKey: "secret", messages: hello, maxTokens: 50) == "From NVIDIA", "NVIDIA answers first")
check(mock_calls() == localCalls, "the model on the iPad isn't touched")
check(FakeNVIDIA.lastKey == "Bearer secret", "the key goes in the header")
let cloudPartials = Box()
_ = try await AI.respond(cloudKey: "secret", messages: hello, maxTokens: 50) { cloudPartials.add($0) }
check(cloudPartials.all.last == "From NVIDIA", "the whole answer reaches the screen")
FakeNVIDIA.requests = 0
check(try await AI.respond(cloudKey: nil, messages: hello, maxTokens: 50).hasPrefix("Answer"), "no key means the iPad's model")
check(FakeNVIDIA.requests == 0, "and nothing is sent")
for status in [401, 410, 429, 500] {
    FakeNVIDIA.status = status
    check(try await AI.respond(cloudKey: "secret", messages: hello, maxTokens: 50).hasPrefix("Answer"), "falls back after a \(status)")
}
FakeNVIDIA.status = 200
FakeNVIDIA.offline = true
check(try await AI.respond(cloudKey: "secret", messages: hello, maxTokens: 50).hasPrefix("Answer"), "falls back with no connection")
FakeNVIDIA.offline = false
FakeNVIDIA.stream = #"data: {"choices":[{"delta":{"content":"Cut o"}}]}"# + "\n\n"
check(try await AI.respond(cloudKey: "secret", messages: hello, maxTokens: 50).hasPrefix("Answer"), "falls back from an answer cut off halfway")
FakeNVIDIA.stream = sse("not", " json")
check(try await AI.respond(cloudKey: "secret", messages: hello, maxTokens: 50, accept: { $0.hasPrefix("[") }).hasPrefix("Answer"), "falls back from an answer of the wrong shape")
FakeNVIDIA.stream = "data: [DONE]\n\n"
check(try await AI.respond(cloudKey: "secret", messages: hello, maxTokens: 50).hasPrefix("Answer"), "falls back from an empty answer")
FakeNVIDIA.offline = true
mock_set_tokens(1_000_000)
let stoppedCloud = Task { try await AI.respond(cloudKey: "secret", messages: hello, maxTokens: 50) }
stoppedCloud.cancel()
do { _ = try await stoppedCloud.value; check(false, "a stopped answer doesn't carry on") } catch is CancellationError {}
mock_set_tokens(40)
FakeNVIDIA.offline = false

// Unloading frees the model, and the next question opens it again.
let opens = mock_opens()
LocalLLM.shared.unload()
check(try await AI.complete(system: "s", prompt: "p").hasPrefix("Answer"), "answers after unloading")
check(mock_opens() == opens + 1, "opened again once")
print("ok")
