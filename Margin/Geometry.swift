import CoreGraphics
import Foundation

/// A note is one long drawing; pages are horizontal bands of it, stacked with a gap.
enum NoteLayout {
    static let width: CGFloat = 768
    static let paperHeight: CGFloat = 994 // US Letter ratio
    static let gap: CGFloat = 20

    static func origins(_ heights: [CGFloat]) -> [CGFloat] {
        var y: CGFloat = 0
        return heights.map { h in
            defer { y += h + gap }
            return y
        }
    }

    static func totalHeight(_ heights: [CGFloat]) -> CGFloat {
        heights.reduce(0, +) + gap * CGFloat(max(heights.count - 1, 0))
    }

    /// Ink in a gap belongs to the page above it.
    static func pageIndex(y: CGFloat, heights: [CGFloat]) -> Int {
        var bottom: CGFloat = 0
        for (i, h) in heights.enumerated() {
            bottom += h + gap
            if y < bottom { return i }
        }
        return max(heights.count - 1, 0)
    }

    static func shifts(old: [(id: UUID, height: CGFloat)], new: [(id: UUID, height: CGFloat)]) -> [CGFloat?] {
        let oldOrigins = origins(old.map(\.height))
        let newOrigins = origins(new.map(\.height))
        let newByID = Dictionary(uniqueKeysWithValues: zip(new.map(\.id), newOrigins))
        return old.enumerated().map { i, page in
            newByID[page.id].map { $0 - oldOrigins[i] }
        }
    }
}

enum SnappedShape: Equatable {
    case line(CGPoint, CGPoint)
    case ellipse(CGRect)
    case rectangle(CGRect)
    case triangle(CGPoint, CGPoint, CGPoint)
    case arrow(CGPoint, CGPoint)
}

enum ShapeSnap {
    static func recognize(_ points: [CGPoint]) -> SnappedShape? {
        guard points.count >= 3, let first = points.first, let last = points.last else { return nil }
        let length = zip(points, points.dropFirst()).reduce(0) { $0 + dist($1.0, $1.1) }
        guard length > 24 else { return nil }
        if dist(first, last) / length > 0.92 { return .line(first, last) }

        let xs = points.map(\.x), ys = points.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        guard box.width > 16, box.height > 16,
              dist(first, last) < 0.25 * max(box.width, box.height),
              length < 1.5 * 2 * (box.width + box.height) // more than once round is a scribble
        else { return nil }

        // Normalised so the bounding box spans -1...1: an ellipse has radius 1, a rectangle max(|x|,|y|) = 1.
        var ellipseError: CGFloat = 0, rectError: CGFloat = 0
        for p in points {
            let nx = (p.x - box.midX) / (box.width / 2), ny = (p.y - box.midY) / (box.height / 2)
            ellipseError += abs(hypot(nx, ny) - 1)
            rectError += abs(max(abs(nx), abs(ny)) - 1)
        }
        ellipseError /= CGFloat(points.count)
        rectError /= CGFloat(points.count)
        if min(ellipseError, rectError) < 0.1 {
            return ellipseError <= rectError ? .ellipse(box) : .rectangle(box)
        }
        let corners = simplify(points, tolerance: 0.1 * max(box.width, box.height))
        if corners.count == 4, dist(corners[0], corners[3]) < 0.25 * max(box.width, box.height) {
            return .triangle(corners[0], corners[1], corners[2])
        }
        return nil
    }

    /// Control points for the shape. Corners repeat so the stroke's spline keeps them sharp.
    static func outline(_ shape: SnappedShape) -> [CGPoint] {
        switch shape {
        case let .line(a, b):
            return subdivide(a, b, into: 8)
        case let .ellipse(r):
            return (0...48).map { i in
                let t = CGFloat(i) / 48 * 2 * .pi
                return CGPoint(x: r.midX + cos(t) * r.width / 2, y: r.midY + sin(t) * r.height / 2)
            }
        case let .rectangle(r):
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                           CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
                           CGPoint(x: r.minX, y: r.minY)]
            return zip(corners, corners.dropFirst()).flatMap { a, b in
                [a, a] + subdivide(a, b, into: 6) + [b, b]
            }
        case let .triangle(a, b, c):
            return [(a, b), (b, c), (c, a)].flatMap { p, q in
                [p, p] + subdivide(p, q, into: 6) + [q, q]
            }
        case let .arrow(a, b):
            let angle = atan2(b.y - a.y, b.x - a.x), head = min(max(dist(a, b) * 0.25, 10), 26)
            let left = CGPoint(x: b.x - head * cos(angle - .pi / 6), y: b.y - head * sin(angle - .pi / 6))
            let right = CGPoint(x: b.x - head * cos(angle + .pi / 6), y: b.y - head * sin(angle + .pi / 6))
            return subdivide(a, b, into: 8) + [b, b] + subdivide(b, left, into: 3) + [left, left]
                + subdivide(left, b, into: 3) + [b, b] + subdivide(b, right, into: 3) + [right, right]
        }
    }

    /// Ramer-Douglas-Peucker: keeps only the points that define the outline's corners.
    private static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, let a = points.first, let b = points.last else { return points }
        let length = max(dist(a, b), 0.001)
        var farthest = 0, distance: CGFloat = 0
        for i in 1..<(points.count - 1) {
            let p = points[i]
            let d = dist(a, b) < 0.001 ? dist(p, a) : abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / length
            if d > distance {
                distance = d
                farthest = i
            }
        }
        guard distance > tolerance else { return [a, b] }
        return simplify(Array(points[...farthest]), tolerance: tolerance).dropLast() + simplify(Array(points[farthest...]), tolerance: tolerance)
    }

    /// True when the pen stayed put at the end of a stroke for at least `seconds`.
    static func heldAtEnd(_ points: [(location: CGPoint, time: TimeInterval)], seconds: TimeInterval = 0.45, tolerance: CGFloat = 5) -> Bool {
        guard points.count >= 2, let end = points.last else { return false }
        let lastMove = points.last { dist($0.location, end.location) > tolerance }?.time ?? points[0].time
        return end.time - lastMove >= seconds
    }

    /// A wavy underline along a line of text.
    static func squiggle(fromX start: CGFloat, toX end: CGFloat, y: CGFloat, amplitude: CGFloat = 2.5, step: CGFloat = 6) -> [CGPoint] {
        guard end > start else { return [CGPoint(x: start, y: y)] }
        return stride(from: start, through: end, by: step).enumerated().map { i, x in
            CGPoint(x: x, y: y + (i % 2 == 0 ? -amplitude : amplitude))
        }
    }

    private static func subdivide(_ a: CGPoint, _ b: CGPoint, into n: Int) -> [CGPoint] {
        (0...n).map { i in
            let t = CGFloat(i) / CGFloat(n)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

/// Spaced repetition (SM-2 family). `interval` is in days.
enum SM2 {
    enum Grade: Int, CaseIterable, Identifiable {
        case again = 1, hard = 3, good = 4, easy = 5
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .again: "Again"
            case .hard: "Hard"
            case .good: "Good"
            case .easy: "Easy"
            }
        }
    }

    static func next(ease: Double, interval: Double, reps: Int, grade: Grade) -> (ease: Double, interval: Double, reps: Int) {
        let q = Double(grade.rawValue)
        let newEase = max(1.3, ease + 0.1 - (5 - q) * (0.08 + (5 - q) * 0.02))
        guard grade != .again else { return (newEase, 10.0 / 1440, 0) } // back in ten minutes
        let newReps = reps + 1
        let days: Double
        switch (newReps, grade) {
        case (1, _): days = 1
        case (2, .hard): days = 3
        case (2, _): days = 6
        case (_, .hard): days = interval * 1.2
        case (_, .easy): days = interval * newEase * 1.3
        default: days = interval * newEase
        }
        return (newEase, days, newReps)
    }
}

/// Small math parser for handwriting results and graphs. NSExpression is unusable here: bad input raises an uncatchable exception.
enum Calc {
    static func normalize(_ s: String) -> String {
        var out = s.lowercased()
        for (from, to) in [("×", "*"), ("÷", "/"), ("−", "-"), ("–", "-"), ("·", "*"), ("π", "pi"), ("√", "sqrt"), ("²", "^2"), ("³", "^3"), (" ", ""), ("\n", "")] {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out
    }

    static func body(_ s: String) -> String {
        normalize(s).split(separator: "=").last.map(String.init) ?? ""
    }

    static func evaluate(_ s: String, x: Double? = nil) -> Double? {
        var parser = Parser(chars: Array(body(s)), x: x)
        guard let value = parser.expression(), parser.atEnd, value.isFinite else { return nil }
        return value
    }

    private struct Parser {
        let chars: [Character]
        let x: Double?
        var i = 0

        var atEnd: Bool { i == chars.count }
        private var peek: Character? { i < chars.count ? chars[i] : nil }

        private mutating func eat(_ c: Character) -> Bool {
            guard peek == c else { return false }
            i += 1
            return true
        }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while true {
                if eat("+") {
                    guard let r = term() else { return nil }
                    value += r
                } else if eat("-") {
                    guard let r = term() else { return nil }
                    value -= r
                } else {
                    return value
                }
            }
        }

        private mutating func term() -> Double? {
            guard var value = unary() else { return nil }
            while true {
                if eat("*") {
                    guard let r = unary() else { return nil }
                    value *= r
                } else if eat("/") {
                    guard let r = unary() else { return nil }
                    value /= r
                } else if let c = peek, c.isLetter || c.isNumber || c == "(" { // implicit: 2x, 3(x+1)
                    guard let r = power() else { return nil }
                    value *= r
                } else {
                    return value
                }
            }
        }

        private mutating func unary() -> Double? {
            if eat("-") { return unary().map { -$0 } }
            if eat("+") { return unary() }
            return power()
        }

        private mutating func power() -> Double? {
            guard let base = atom() else { return nil }
            guard eat("^") else { return base }
            return unary().map { pow(base, $0) }
        }

        // Longest names first, so "asin" isn't read as "a" then "sin".
        private static let functions = ["asin", "acos", "atan", "sqrt", "sin", "cos", "tan", "abs", "exp", "log", "ln"]

        private static func apply(_ name: String, _ v: Double) -> Double {
            switch name {
            case "asin": asin(v)
            case "acos": acos(v)
            case "atan": atan(v)
            case "sqrt": sqrt(v)
            case "sin": sin(v)
            case "cos": cos(v)
            case "tan": tan(v)
            case "abs": abs(v)
            case "exp": exp(v)
            case "log": log10(v)
            default: log(v)
            }
        }

        private mutating func atom() -> Double? {
            if eat("(") {
                guard let value = expression(), eat(")") else { return nil }
                return value
            }
            guard let c = peek else { return nil }
            if c.isNumber || c == "." {
                let start = i
                while let d = peek, d.isNumber || d == "." { i += 1 }
                return Double(String(chars[start..<i]))
            }
            for name in Self.functions where matches(name) {
                i += name.count
                return unary().map { Self.apply(name, $0) }
            }
            if matches("pi") { i += 2; return .pi }
            if eat("x") { return x }
            if eat("e") { return M_E }
            return nil
        }

        private func matches(_ name: String) -> Bool {
            let n = Array(name)
            return i + n.count <= chars.count && Array(chars[i..<i + n.count]) == n
        }
    }
}

enum Scribble {
    static func isScribble(_ points: [CGPoint]) -> Bool {
        guard points.count >= 12, var extreme = points.first?.x else { return false }
        var direction: CGFloat = 0, reversals = 0
        for p in points {
            let delta = p.x - extreme
            if direction == 0 {
                if abs(delta) > 6 { direction = delta > 0 ? 1 : -1; extreme = p.x }
            } else if delta * direction > 0 {
                extreme = p.x
            } else if abs(delta) > 6 {
                reversals += 1
                direction = -direction
                extreme = p.x
            }
        }
        let xs = points.map(\.x)
        return reversals >= 5 && (xs.max()! - xs.min()!) > 24
    }
}

/// Undo and redo over whole states, which stay cheap to keep because their parts share storage until they change.
struct History<State: Equatable> {
    private var past: [State] = []
    private var future: [State] = []
    let limit: Int

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    mutating func record(_ state: State) {
        guard past.last != state else { return }
        past.append(state)
        if past.count > limit { past.removeFirst() }
        future.removeAll()
    }

    /// A step that wouldn't change anything is skipped, so one undo always does something visible.
    mutating func undo(from current: State) -> State? {
        while let state = past.popLast() {
            guard state != current else { continue }
            future.append(current)
            return state
        }
        return nil
    }

    mutating func redo(from current: State) -> State? {
        while let state = future.popLast() {
            guard state != current else { continue }
            past.append(current)
            return state
        }
        return nil
    }

    mutating func clear() {
        past.removeAll()
        future.removeAll()
    }
}

enum TextTools {
    private static let commonWords: Set<String> = [
        "an", "as", "at", "be", "by", "do", "if", "in", "is", "it", "of", "on", "or", "to", "about", "after", "again", "also", "and", "are", "but", "can", "could", "did", "does", "for", "from", "give", "had", "has", "have",
        "how", "into", "its", "may", "more", "not", "our", "shall", "should", "tell", "than", "that", "the", "their", "them", "then", "there",
        "these", "they", "this", "was", "were", "what", "when", "where", "which", "who", "why", "will", "with", "would", "you", "your",
    ]

    /// Words reduced to a rough stem, so "dividing" finds "divides". Numbers and short terms like "dna" stay as they are.
    private static func terms(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.compactMap { word in
            guard word.count > 1, !commonWords.contains(String(word)) else { return nil }
            for suffix in ["ing", "ies", "ed", "es", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
                return String(word.dropLast(suffix.count))
            }
            return String(word)
        }
    }

    /// The passages most likely to answer a question, up to `limit` characters, best first, ranked by BM25: a rare
    /// word counts for more than a common one, and a passage can't win just by being long.
    /// Falls back to the opening passages when no words match, so a broad question still gets an answer.
    static func bestPassages(query: String, passages: [String], limit: Int) -> [Int] {
        let wanted = Set(terms(in: query))
        var lengths = [Int](repeating: 0, count: passages.count)
        var counts = [[String: Int]](repeating: [:], count: passages.count)
        var containing: [String: Int] = [:]
        for (i, passage) in passages.enumerated() {
            let words = terms(in: passage)
            lengths[i] = words.count
            for word in words where wanted.contains(word) { counts[i][word, default: 0] += 1 }
            for word in counts[i].keys { containing[word, default: 0] += 1 }
        }
        let total = Double(passages.count), average = max(Double(lengths.reduce(0, +)) / max(total, 1), 1)
        let scored: [(index: Int, score: Double)] = passages.indices.compactMap { i in
            guard !passages[i].isEmpty else { return nil }
            let score = counts[i].reduce(0.0) { sum, entry in
                let rarity = log(1 + (total - Double(containing[entry.key] ?? 0) + 0.5) / (Double(containing[entry.key] ?? 0) + 0.5))
                let frequency = Double(entry.value)
                return sum + rarity * frequency * 2.2 / (frequency + 1.2 * (0.25 + 0.75 * Double(lengths[i]) / average))
            }
            return (i, score)
        }
        let ranked = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        var chosen: [Int] = [], used = 0
        for item in ranked {
            let size = passages[item.index].count
            if !chosen.isEmpty, used + size > limit { continue }
            chosen.append(item.index)
            used += size
            if used >= limit { break }
        }
        return chosen
    }

    /// The small subset of Markdown the model writes, for showing on screen.
    static func styled(_ answer: String) -> AttributedString {
        let lines = answer.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? "" : "**\(title)**"
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let indent = String(line.prefix { $0 == " " })
                return indent + "•  " + trimmed.dropFirst(2)
            }
            return line
        }
        let source = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
    }

    /// The same text without its markers, for placing into a note as plain type.
    static func plain(_ answer: String) -> String {
        String(styled(answer).characters)
    }

    /// Models often write "A. Paris" even though the option's position already says which it is.
    static func withoutOptionLabel(_ option: String) -> String {
        let trimmed = option.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first.isLetter, first.isUppercase, trimmed.dropFirst().first == "." || trimmed.dropFirst().first == ")" else { return trimmed }
        return trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
    }

    /// Drops the reasoning block this model family can open with, finished or still being written.
    static func visibleAnswer(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\u{FFFD}", with: "")
        if let end = text.range(of: "</think>") {
            text = String(text[end.upperBound...])
        } else if text.hasPrefix("<think>") {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper marks silence and noises as "[BLANK_AUDIO]" or "(wind blowing)"; those aren't words anyone said.
    static func isSpeech(_ line: String) -> Bool {
        guard let first = line.first, let last = line.last else { return false }
        return !((first == "[" && last == "]") || (first == "(" && last == ")"))
    }

    /// Splits at paragraph or sentence ends where possible, so no chunk starts mid-thought.
    static func chunks(_ text: String, size: Int) -> [String] {
        var pieces: [String] = [], rest = Substring(text)
        while rest.count > size {
            let window = rest.prefix(size)
            let tail = window.suffix(size / 4)
            let cut = tail.range(of: "\n", options: .backwards)?.upperBound
                ?? tail.range(of: ". ", options: .backwards)?.upperBound
                ?? window.endIndex
            pieces.append(String(rest[..<cut]))
            rest = rest[cut...]
        }
        if !rest.isEmpty { pieces.append(String(rest)) }
        return pieces
    }

    /// Where to end an audio chunk: the quietest 20 ms within the last stretch of samples.
    static func quietCut(_ samples: [Float], searchingLast span: Int) -> Int {
        let window = 320
        guard samples.count > window else { return samples.count }
        var best = samples.count, quietest = Float.greatestFiniteMagnitude
        var end = samples.count
        let start = max(samples.count - span, window)
        while end >= start {
            var energy: Float = 0
            for i in (end - window)..<end { energy += samples[i] * samples[i] }
            if energy < quietest {
                quietest = energy
                best = end
            }
            end -= window
        }
        return best
    }

    /// Models sometimes wrap JSON in prose or code fences; take the outermost array.
    static func jsonArray(in text: String) -> Data? {
        guard let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]"), a < b else { return nil }
        return String(text[a...b]).data(using: .utf8)
    }

    /// Extracts the concise final answer from a calculation response, stripping explanations and markdown.
    static func cleanMathAnswer(_ raw: String) -> String {
        var text = visibleAnswer(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = text.range(of: "(?i)final answer:?\\s*", options: .regularExpression) {
            text = String(text[match.upperBound...])
        } else if let match = text.range(of: "(?i)answer:?\\s*", options: .regularExpression) {
            text = String(text[match.upperBound...])
        }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let last = lines.last {
            text = last
        }
        text = String(text.filter { !$0.unicodeScalars.contains { $0.properties.isEmojiPresentation } })
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "`*$= \t\n\r"))
        return text
    }

}
