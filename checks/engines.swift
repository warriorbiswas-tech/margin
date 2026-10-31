// Runs the app's real AI code with the real models on a Mac. See checks/run-engines.sh.
import Foundation

func report(_ name: String, _ detail: String, started: Date) {
    print("[\(name)] \(String(format: "%.1f", Date().timeIntervalSince(started)))s\n\(detail)\n")
}

func attempt(_ name: String, _ work: () async throws -> String) async {
    let started = Date()
    do {
        report(name, try await work(), started: started)
    } catch {
        report("\(name) FAILED", "\(error)", started: started)
        failures += 1
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
nonisolated(unsafe) var failures = 0
let arguments = CommandLine.arguments
ModelFile.directory = URL(fileURLWithPath: arguments[1])
let notes = """
Mitosis is cell division that produces two genetically identical daughter cells. Its stages are prophase, metaphase, anaphase and telophase, followed by cytokinesis. In metaphase the chromosomes line up along the cell's equator. Meiosis, by contrast, produces four genetically different cells with half the chromosomes, and it is used to make gametes. Errors in chromosome separation are called nondisjunction.
"""

await attempt("transcribe file") {
    let lines = try await Transcriber.transcribe(file: URL(fileURLWithPath: arguments[2])) { _ in }
    return lines.map { "\(String(format: "%.1f", $0.time)) \($0.text)" }.joined(separator: "\n")
}
await attempt("transcribe, other languages model") {
    guard ModelFile.speechWorld.isInstalled else { return "skipped: model not in the folder" }
    UserDefaults.standard.set("auto", forKey: SpeechLanguage.key)
    defer { UserDefaults.standard.removeObject(forKey: SpeechLanguage.key) }
    let lines = try await Transcriber.transcribe(file: URL(fileURLWithPath: arguments[2])) { _ in }
    guard !lines.isEmpty else { throw AIError.badResponse }
    return lines.map(\.text).joined(separator: " ")
}
await attempt("summary") { try await AI.summary(of: notes) }
await attempt("streaming") {
    let box = Counter()
    let text = try await AI.summary(of: notes) { _ in box.add() }
    guard box.count > 3 else { throw AIError.badResponse }
    return "\(box.count) partial updates, \(text.count) characters"
}
await attempt("flashcards") {
    let cards = try await AI.flashcards(from: notes, count: 4)
    guard !cards.isEmpty else { throw AIError.badResponse }
    return cards.map { "Q: \($0.front)\nA: \($0.back)" }.joined(separator: "\n")
}
await attempt("quiz") {
    let questions = try await AI.quiz(from: notes, count: 3)
    guard !questions.isEmpty else { throw AIError.badResponse }
    return questions.map { "\($0.question) \($0.options) answer=\($0.answer)" }.joined(separator: "\n")
}
await attempt("mind map") {
    let root = try await AI.mindMap(from: notes)
    return "\(root.title): \((root.children ?? []).map(\.title))"
}
await attempt("chat") {
    let system = AI.chatSystem(context: notes)
    return try await AI.complete(system: system, messages: [("user", "How many cells does meiosis produce?")])
}
await attempt("chat follow-up") {
    let system = AI.chatSystem(context: notes)
    return try await AI.complete(system: system, messages: [("user", "How many cells does meiosis produce?"), ("assistant", "Four."), ("user", "And mitosis?")])
}
await attempt("same long question again, reusing what the model already read") {
    let system = AI.chatSystem(context: String(repeating: notes + "\n", count: 12))
    let first = Date()
    _ = try await AI.complete(system: system, messages: [("user", "How many cells does meiosis produce?")], maxTokens: 20)
    let cold = Date().timeIntervalSince(first)
    let second = Date()
    _ = try await AI.complete(system: system, messages: [("user", "How many cells does meiosis produce?")], maxTokens: 20)
    let warm = Date().timeIntervalSince(second)
    return String(format: "first %.2fs, again %.2fs", cold, warm)
}
for mode in AskMode.allCases {
    await attempt(mode.rawValue) {
        let text = mode == .steps ? "A train travels 120 km in 2 hours. What is its average speed?" : notes
        return try await AI.ask(mode, about: text)
    }
}
await attempt("clean up a transcript") {
    try await AI.cleanTranscript("today we are covering my toe sis in meta phase the chromosomes line up along the equator of the cell then in ana phase they are pulled apart")
}
await attempt("teach back") {
    try await AI.reviewExplanation("Mitosis makes two identical cells. Meiosis makes two cells too.", against: notes)
}
await attempt("file into a folder") {
    let chosen = try await AI.folder(for: notes, among: ["Biology", "History", "Work \\ Admin", "Say \"Hi\""])
    guard chosen == "Biology" else { throw AIError.badResponse }
    return chosen
}
await attempt("not in notes") {
    let system = AI.chatSystem(context: notes)
    return try await AI.complete(system: system, messages: [("user", "Who won the 2018 World Cup according to my notes?")])
}
await attempt("math") {
    let math = try await AI.math(fromRecognized: "x2 + 2x + 1 = 0")
    return "\(math.unicode)   LaTeX: \(math.latex)"
}
await attempt("solve") { try await AI.solve("integral of 2x dx from 0 to 3") }
await attempt("translate") { try await AI.translate("Mitosis produces two identical cells.", to: "Hindi") }
await attempt("long note digest") {
    let long = String(repeating: notes + "\n", count: 60)
    let digest = try await AI.digest(long)
    return "\(long.count) characters condensed to \(digest.count)\n\(digest.prefix(300))"
}
await attempt("too long for one request") {
    do {
        _ = try await AI.complete(system: "Reply briefly.", prompt: String(repeating: "word ", count: 12000))
        throw AIError.badResponse
    } catch AIError.tooLong {
        return "refused cleanly"
    }
}
await attempt("cancel mid-answer") {
    let started = Date()
    let task = Task { try await AI.complete(system: "Write a very long essay.", prompt: "Write about the history of Rome.", maxTokens: 1200) }
    try await Task.sleep(for: .seconds(4))
    task.cancel()
    do {
        _ = try await task.value
        throw AIError.badResponse
    } catch is CancellationError {
        return "stopped after \(String(format: "%.1f", Date().timeIntervalSince(started)))s"
    }
}
await attempt("works after cancel") { try await AI.complete(system: "Reply with one word.", prompt: "What color is the sky?", maxTokens: 40) }
LocalLLM.shared.unload()
await attempt("reload after unload") { try await AI.complete(system: "Reply with one word.", prompt: "What is 2+2?", maxTokens: 40) }
await withCheckedContinuation { finished in LocalLLM.shared.unload { finished.resume() } }

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

struct TranscriptLine: Codable, Hashable {
    var time: TimeInterval
    var text: String
}
