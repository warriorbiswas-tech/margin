// swiftc -O Margin/Geometry.swift Margin/Sync.swift checks/stress/main.swift -o /tmp/margin-stress && /tmp/margin-stress [seed]
// Random input against everything that runs without a screen, then three devices editing and syncing at random.
import CoreGraphics
import Foundation

/// SplitMix64, so a failing run can be repeated from its seed.
struct Dice: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

let seed = CommandLine.arguments.count > 1 ? UInt64(CommandLine.arguments[1]) ?? 1 : UInt64(Date().timeIntervalSince1970)
var dice = Dice(state: seed)
setvbuf(stdout, nil, _IOLBF, 0)

func check(_ ok: Bool, _ what: @autoclosure () -> String) {
    guard !ok else { return }
    print("FAIL (seed \(seed)): \(what())")
    exit(1)
}

func roll(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &dice) }
func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &dice) < p }
func text(from alphabet: [String], length: ClosedRange<Int>) -> String {
    (0..<roll(length)).map { _ in alphabet.randomElement(using: &dice)! }.joined()
}
/// Ids from the seed, so a run makes the same choices again. Copies kept from a conflict still get random ones.
func freshID() -> String {
    var bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &dice) }
    bytes[6] = bytes[6] & 0x0F | 0x40
    bytes[8] = bytes[8] & 0x3F | 0x80
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
}

func point(in size: CGFloat) -> CGPoint {
    CGPoint(x: CGFloat.random(in: -size...size, using: &dice), y: CGFloat.random(in: -size...size, using: &dice))
}

func timed(_ name: String, _ work: () -> Void) {
    let start = Date()
    work()
    print(name.padding(toLength: 28, withPad: " ", startingAt: 0) + String(format: "%6.2fs", Date().timeIntervalSince(start)))
}

// MARK: Math typed or read from handwriting

timed("calculator") {
    let symbols = ["0", "1", "2", "7", "9", ".", "+", "-", "*", "/", "^", "(", ")", "x", "e", "π", "√", "²", "×", "÷", "=", " ", "sin", "log", "sqrt", "pi", "abs", "q"]
    for _ in 0..<200_000 {
        let input = text(from: symbols, length: 0...24)
        if let value = Calc.evaluate(input, x: Double.random(in: -10...10, using: &dice)) {
            check(value.isFinite, "“\(input)” gave \(value)")
        }
    }
    let deep = String(repeating: "(", count: 400) + "2" + String(repeating: ")", count: 400)
    check(Calc.evaluate(deep) == 2, "deeply nested parentheses")
    check(Calc.evaluate(String(repeating: "-", count: 400) + "3") == 3, "a long run of minus signs")
    check(Calc.evaluate(String(repeating: "1+", count: 5000) + "1") == 5001, "a very long sum")
}

// MARK: Scratching out and shapes

timed("scratch-out detection") {
    for _ in 0..<40_000 {
        let size = CGFloat([1, 10, 200, 100_000].randomElement(using: &dice)!)
        var points = (0..<roll(0...300)).map { _ in point(in: size) }
        if chance(0.1) { points = Array(repeating: point(in: size), count: roll(0...50)) }
        _ = Scribble.isScribble(points)
        let area = CGRect(origin: point(in: size), size: CGSize(width: size, height: size))
        let share = Scribble.share(of: points, in: area)
        check(share >= 0 && share <= 1, "share out of range")
    }
}

timed("shape snapping") {
    for _ in 0..<40_000 {
        let size = CGFloat([0.5, 30, 400].randomElement(using: &dice)!)
        var points = (0..<roll(0...400)).map { _ in point(in: size) }
        if chance(0.1) { points = Array(repeating: .zero, count: roll(0...20)) }
        if chance(0.1) { points = (0..<roll(2...200)).map { CGPoint(x: CGFloat($0), y: CGFloat($0) * 2) } }
        guard let shape = ShapeSnap.recognize(points) else { continue }
        let outline = ShapeSnap.outline(shape)
        check(!outline.isEmpty && outline.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "outline of \(shape)")
    }
    // A long closed stroke that is no clean shape sends every point through the corner finder.
    let blob = (0...20_000).map { i -> CGPoint in
        let t = CGFloat(i) / 20_000 * 2 * .pi
        let r = 100 + 30 * sin(t * 7)
        return CGPoint(x: cos(t) * r, y: sin(t) * r)
    }
    _ = ShapeSnap.recognize(blob)
    let timeline = (0..<500).map { (location: point(in: 100), time: Double($0) * 0.004) }
    _ = ShapeSnap.heldAtEnd(timeline)
    check(ShapeSnap.squiggle(fromX: 0, toX: 100_000, y: 0).count > 1000, "a squiggle across a whiteboard")
}

timed("tilt and spaced repetition") {
    for _ in 0..<100_000 {
        let scale = TiltPressure.scale(altitude: CGFloat.random(in: 0...(.pi / 2), using: &dice), strength: Double.random(in: 0.2...1, using: &dice))
        check(scale.isFinite && scale >= 1 / 3 - 1e-9 && scale <= 3 + 1e-9, "tilt scale \(scale)")
    }
    for _ in 0..<2000 {
        var ease = 2.5, interval = 0.0, reps = 0
        for _ in 0..<roll(1...60) {
            (ease, interval, reps) = SM2.next(ease: ease, interval: interval, reps: reps, grade: SM2.Grade.allCases.randomElement(using: &dice)!)
            check(ease >= 1.3 && interval > 0 && interval.isFinite && reps >= 0, "card schedule \(ease) \(interval) \(reps)")
        }
    }
}

// MARK: Page layout

timed("page layout") {
    for _ in 0..<20_000 {
        let heights = (0..<roll(1...40)).map { _ in CGFloat(roll(1...4000)) }
        let origins = NoteLayout.origins(heights)
        check(zip(origins, origins.dropFirst()).allSatisfy { $0 < $1 }, "pages overlap")
        let y = CGFloat.random(in: -100...(NoteLayout.totalHeight(heights) + 100), using: &dice)
        check(heights.indices.contains(NoteLayout.pageIndex(y: y, heights: heights)), "page for y \(y)")

        let ids = heights.map { _ in UUID() }
        let old = Array(zip(ids, heights)).map { (id: $0.0, height: $0.1) }
        var new = old.shuffled(using: &dice)
        if chance(0.5), new.count > 1 { new.remove(at: roll(0...(new.count - 1))) }
        let shifts = NoteLayout.shifts(old: old, new: new)
        let newOrigins = NoteLayout.origins(new.map(\.height))
        for (i, page) in old.enumerated() {
            if let at = new.firstIndex(where: { $0.id == page.id }) {
                check(shifts[i] == newOrigins[at] - origins[i], "a moved page lands on its new place")
            } else {
                check(shifts[i] == nil, "a deleted page's ink goes with it")
            }
        }

        let lines = (0..<roll(0...6)).map { _ in CGRect(origin: point(in: 500), size: CGSize(width: 80, height: 30)) }
        let strokes = (0..<roll(0...30)).map { _ in CGRect(origin: point(in: 500), size: CGSize(width: 10, height: 20)) }
        check(NoteLayout.inkBounds(ofLines: lines, strokes: strokes).count == lines.count, "one box per line")
    }
}

// MARK: Text from the model and from notes

timed("text tools") {
    let words = ["mitosis", "cell", "the", "Divides", " ", "\n", ". ", "x", "2", "dna", "é", "日本", "🙂"]
    let latex = ["\\frac{", "\\sqrt{", "\\text{", "}", "{", "$", "$$", "^", "_", "\\to", "\\right", "a", "1", " ", "\\", "\n"]
    for _ in 0..<20_000 {
        let input = text(from: latex, length: 0...40)
        _ = TextTools.withoutLaTeX(input)
        _ = TextTools.cleanMathAnswer(input)
        _ = TextTools.visibleAnswer(["<think>", "</think>", "\u{FFFD}", "answer"].randomElement(using: &dice)! + input)
        _ = TextTools.jsonArray(in: input + ["[", "]", "[1]"].randomElement(using: &dice)!)
        #if canImport(Darwin)
        _ = TextTools.plain(text(from: ["#", "-", "*", "**", "_", "`", "a", " ", "\n"], length: 0...30))
        #endif
    }
    for _ in 0..<5000 {
        let body = text(from: words, length: 0...400), size = roll(1...300)
        let pieces = TextTools.chunks(body, size: size)
        check(pieces.joined() == body, "chunks lose nothing")
        check(pieces.allSatisfy { !$0.isEmpty && $0.count <= size }, "chunks stay within \(size)")
    }
    for _ in 0..<3000 {
        let passages = (0..<roll(0...40)).map { _ in text(from: words, length: 0...60) }
        let limit = roll(1...2000)
        let chosen = TextTools.bestPassages(query: text(from: words, length: 0...8), passages: passages, limit: limit)
        check(Set(chosen).count == chosen.count && chosen.allSatisfy(passages.indices.contains), "passages picked once and in range")
        check(chosen.count <= 1 || chosen.map { passages[$0].count }.reduce(0, +) <= limit, "passages stay within the limit")
        check(chosen.allSatisfy { !passages[$0].isEmpty }, "empty pages are never read")
    }
    for _ in 0..<2000 {
        let samples = (0..<roll(0...5000)).map { _ in Float.random(in: -1...1, using: &dice) }
        let cut = TextTools.quietCut(samples, searchingLast: roll(0...8000))
        check(cut >= 0 && cut <= samples.count, "audio cut inside the samples")
    }
}

// MARK: Undo and redo

timed("undo history") {
    for _ in 0..<2000 {
        let limit = roll(1...30)
        var history = History<Int>(limit: limit)
        var current = 0, next = 1
        for _ in 0..<roll(1...400) {
            switch roll(0...2) {
            case 0:
                history.record(current)
                current = next
                next += 1
            case 1:
                let before = current
                guard let state = history.undo(from: current) else { continue }
                check(state != before, "undo always changes something")
                let redone = history.redo(from: state)
                check(redone == before, "redo puts back what undo took")
                current = history.undo(from: before) ?? before
            default:
                if let state = history.redo(from: current) { current = state }
            }
        }
        var steps = 0
        while let state = history.undo(from: current) {
            current = state
            steps += 1
        }
        check(steps <= limit, "kept \(steps) steps with a limit of \(limit)")
    }
}

// MARK: Three devices syncing through one folder

/// Each version of a note carries a token in its ink. A token may only disappear once a later version,
/// made from it, has taken its place. Anything else means an edit was lost.
final class World {
    let fm = FileManager.default
    let base: URL, remote: URL
    var devices: [URL] = []
    var stamps: [[String: Double]] = []
    var pendingDeletes: [Set<String>] = []
    var ancestors: [String: Set<String>] = [:]
    var deletedForever: Set<String> = []
    /// Every version each note has held, on any device.
    var held: [String: Set<String>] = [:]
    var clock = 0.0

    init(devices count: Int) throws {
        base = fm.temporaryDirectory.appendingPathComponent("margin-stress-\(UUID().uuidString)")
        remote = base.appendingPathComponent("remote")
        try fm.createDirectory(at: remote, withIntermediateDirectories: true)
        for i in 0..<count {
            let dir = base.appendingPathComponent("device\(i)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            devices.append(dir)
            stamps.append([:])
            pendingDeletes.append([])
        }
    }

    deinit { try? fm.removeItem(at: base) }

    func notes(on dir: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { UUID(uuidString: $0) != nil }.sorted()
    }

    func json(_ dir: URL, _ id: String) -> [String: Any]? {
        (try? Data(contentsOf: dir.appendingPathComponent(id).appendingPathComponent("note.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func token(_ dir: URL, _ id: String) -> String? {
        (try? Data(contentsOf: dir.appendingPathComponent(id).appendingPathComponent("drawing.data"))).map { String(decoding: $0, as: UTF8.self) }
    }

    func write(_ device: Int, _ id: String, trashed: Bool? = nil, pages: Int = 1) throws {
        let dir = devices[device].appendingPathComponent(id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = token(devices[device], id)
        let fresh = freshID()
        ancestors[fresh] = previous.map { (ancestors[$0] ?? []).union([$0]) } ?? []
        clock += 1
        var note: [String: Any] = ["id": id, "title": "Note", "updatedAt": clock]
        let wasTrashed = json(devices[device], id)?["deletedAt"] != nil
        if trashed ?? wasTrashed { note["deletedAt"] = clock }
        try Data(fresh.utf8).write(to: dir.appendingPathComponent("drawing.data"))
        held[id, default: []].insert(fresh)
        // Pages come and go, so files must disappear from the other side too.
        for old in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where old.hasPrefix("img-") {
            try fm.removeItem(at: dir.appendingPathComponent(old))
        }
        for i in 0..<pages { try Data(repeating: UInt8(i), count: 64 * (i + 1)).write(to: dir.appendingPathComponent("img-\(i).png")) }
        try JSONSerialization.data(withJSONObject: note).write(to: dir.appendingPathComponent("note.json"))
    }

    func sync(_ device: Int, open: Set<String> = []) throws {
        _ = try Sync.reconcile(notes: devices[device], remote: remote, stamps: &stamps[device], open: open, deleted: pendingDeletes[device])
        pendingDeletes[device] = []
        // A sync is the only way a version moves into another note, as the copy kept from a conflict.
        for dir in [devices[device], remote] {
            for id in notes(on: dir) {
                if let t = token(dir, id) { held[id, default: []].insert(t) }
            }
        }
    }

    func step() throws {
        let device = roll(0...(devices.count - 1))
        let mine = notes(on: devices[device])
        switch roll(0...9) {
        case 0, 1:
            try write(device, freshID(), pages: roll(0...3))
        case 2, 3, 4:
            guard let id = mine.randomElement(using: &dice) else { return }
            try write(device, id, pages: roll(0...3))
        case 5:
            guard let id = mine.randomElement(using: &dice) else { return }
            try write(device, id, trashed: chance(0.7))
        case 6:
            guard let id = mine.first(where: { json(devices[device], $0)?["deletedAt"] != nil }) else { return }
            if let t = token(devices[device], id) { held[id, default: []].insert(t) }
            try fm.removeItem(at: devices[device].appendingPathComponent(id))
            pendingDeletes[device].insert(id)
            deletedForever.insert(id)
        default:
            // Sometimes with a note open in the editor, which a sync must leave alone.
            let open = chance(0.3) ? Set(mine.filter { _ in chance(0.3) }) : []
            let before = Dictionary(uniqueKeysWithValues: open.compactMap { id in token(devices[device], id).map { (id, $0) } })
            try sync(device, open: open)
            for (id, kept) in before {
                check(token(devices[device], id) == kept, "a sync changed a note that was open")
            }
        }
    }

    func settle() throws {
        for _ in 0..<3 {
            for device in devices.indices { try sync(device) }
        }
    }

    func verify() {
        func state(_ dir: URL) -> [String: String] {
            Dictionary(uniqueKeysWithValues: notes(on: dir).map { id in
                (id, "\(json(dir, id)?["updatedAt"] ?? "?") \(token(dir, id) ?? "?") \(((try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(id).path)) ?? []).sorted())")
            })
        }
        let first = state(devices[0])
        for dir in devices.dropFirst() + [remote] {
            check(state(dir) == first, "\(dir.lastPathComponent) didn't settle on the same notes as device0")
        }
        let present = Set(notes(on: devices[0]).compactMap { token(devices[0], $0) })
        let covered = present.union(present.flatMap { ancestors[$0] ?? [] })
        for (made, _) in ancestors where !covered.contains(made) {
            check(isFromDeletedNote(made), "an edit was lost (token \(made))")
        }
    }

    /// Deleting forever is allowed to remove what was in that note, and the versions it was made from.
    private func isFromDeletedNote(_ made: String) -> Bool {
        held.contains { id, versions in
            deletedForever.contains(id) && versions.contains { $0 == made || ancestors[$0]?.contains(made) == true }
        }
    }
}

timed("sync between three devices") {
    for round in 0..<40 {
        do {
            let world = try World(devices: 3)
            for _ in 0..<roll(50...300) { try world.step() }
            try world.settle()
            world.verify()
        } catch {
            check(false, "sync round \(round) threw \(error)")
        }
    }
}

print("ok, seed \(seed)")
