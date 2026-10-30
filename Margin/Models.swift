import Foundation
import UIKit

enum PaperColor: String, Codable, CaseIterable, Identifiable {
    case white, cream, gray, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// Dark pages swap the paper: light sheets go dark, and the dark sheet goes light.
    func fill(dark: Bool) -> UIColor {
        switch (self, dark) {
        case (.white, false): .white
        case (.cream, false): UIColor(hex: "FBF6E9")
        case (.gray, false): UIColor(hex: "E9EAEC")
        case (.dark, false): UIColor(hex: "1F2125")
        case (.white, true): UIColor(hex: "1C1C1E")
        case (.cream, true): UIColor(hex: "221F18")
        case (.gray, true): UIColor(hex: "2B2C30")
        case (.dark, true): UIColor(hex: "F5F5F2")
        }
    }
    func line(dark: Bool) -> UIColor {
        (self == .dark) != dark ? UIColor(white: 1, alpha: 0.16) : UIColor(red: 0.25, green: 0.4, blue: 0.65, alpha: 0.25)
    }
    func label(dark: Bool) -> UIColor {
        (self == .dark) != dark ? UIColor(white: 1, alpha: 0.55) : UIColor(white: 0.25, alpha: 0.7)
    }
}

enum PageSize: String, CaseIterable, Identifiable {
    case letter, a4, square, slide, long
    var id: String { rawValue }
    var title: String {
        switch self {
        case .letter: "US Letter"
        case .a4: "A4"
        case .square: "Square"
        case .slide: "Slide (16:9)"
        case .long: "Long Whiteboard"
        }
    }
    var height: CGFloat {
        switch self {
        case .letter: NoteLayout.paperHeight
        case .a4: 1086
        case .square: 768
        case .slide: 432
        case .long: 3072
        }
    }
}

struct Page: Codable, Identifiable, Hashable {
    var id = UUID()
    var height: CGFloat = NoteLayout.paperHeight
    var style: PaperStyle = .ruled
    var color: PaperColor = .white
    var pdfPage: Int? // index into source.pdf; nil for plain paper
    var backgroundFile: String? // custom template image in the note's folder
    var bookmarked = false
}

struct Element: Codable, Identifiable, Hashable {
    var id = UUID()
    var rect: CGRect
    var text = ""
    var fontSize: CGFloat = 20
    var colorHex = "1C1C1E"
    var imageFile: String?
    var fillHex: String? // sticky note background
    var isTape = false // covers the ink until tapped
    var revealed = false
    var fontName = "sans"
    var bold = false
    var link: String? // "note:<id>" or a web address
    var cover: String? // "redact" or "whiteout": hides what's beneath, on screen and in exports
    var stamp = false
    var comment: String?

    var inset: CGFloat { fillHex == nil && !stamp ? 0 : 10 }
}

struct TranscriptLine: Codable, Hashable {
    var time: TimeInterval
    var text: String
}

struct Recording: Codable, Identifiable, Hashable {
    var id = UUID()
    var file: String
    var startedAt: Date
    var duration: TimeInterval
    var transcript: [TranscriptLine]?
    var flags: [TimeInterval]?

    func covers(_ date: Date) -> Bool {
        date >= startedAt && date <= startedAt.addingTimeInterval(duration)
    }
}

struct Flashcard: Codable, Identifiable, Hashable {
    var id = UUID()
    var front: String
    var back: String
    var frontImage: String?
    var ease = 2.5
    var interval = 0.0
    var reps = 0
    var due = Date()
}

extension Flashcard {
    mutating func apply(_ grade: SM2.Grade) {
        let next = SM2.next(ease: ease, interval: interval, reps: reps, grade: grade)
        ease = next.ease
        interval = next.interval
        reps = next.reps
        due = Date().addingTimeInterval(next.interval * 86_400)
    }
}

struct Excerpt: Codable, Identifiable, Hashable {
    var id = UUID()
    var imageFile: String?
    var text: String?
    var pageID: UUID
    var rect: CGRect
    var createdAt = Date()
}

struct Subject: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var colorHex: String
}

struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var subjectID: UUID?
    var createdAt = Date()
    var updatedAt = Date()
    var favorite = false
    var deletedAt: Date?
    var pages: [Page] = [Page()]
    var elements: [Element] = []
    var recordings: [Recording] = []
    var searchText = "" // recognised handwriting + PDF text
    var tags: [String] = []
    var locked = false
    var flashcards: [Flashcard] = []
    var excerpts: [Excerpt] = []
    var isTemplate = false
}

// Saved notes must survive app updates: a field added later falls back to its default, so
// an older note.json still loads. The library skips files it can't decode, so a strict decoder would hide notes.
private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

extension Page {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try c.decode(UUID.self, forKey: .id)
        height = c.value(.height, height)
        style = c.value(.style, style)
        color = c.value(.color, color)
        pdfPage = c.value(.pdfPage, nil)
        backgroundFile = c.value(.backgroundFile, nil)
        bookmarked = c.value(.bookmarked, false)
    }
}

extension Element {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(rect: try c.decode(CGRect.self, forKey: .rect))
        id = try c.decode(UUID.self, forKey: .id)
        text = c.value(.text, "")
        fontSize = c.value(.fontSize, fontSize)
        colorHex = c.value(.colorHex, colorHex)
        imageFile = c.value(.imageFile, nil)
        fillHex = c.value(.fillHex, nil)
        isTape = c.value(.isTape, false)
        revealed = c.value(.revealed, false)
        fontName = c.value(.fontName, "sans")
        bold = c.value(.bold, false)
        link = c.value(.link, nil)
        cover = c.value(.cover, nil)
        stamp = c.value(.stamp, false)
        comment = c.value(.comment, nil)
    }
}

extension Note {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(title: c.value(.title, "Untitled"))
        id = try c.decode(UUID.self, forKey: .id)
        subjectID = c.value(.subjectID, nil)
        createdAt = c.value(.createdAt, createdAt)
        updatedAt = c.value(.updatedAt, updatedAt)
        favorite = c.value(.favorite, false)
        deletedAt = c.value(.deletedAt, nil)
        pages = c.value(.pages, pages)
        elements = c.value(.elements, [])
        recordings = c.value(.recordings, [])
        searchText = c.value(.searchText, "")
        tags = c.value(.tags, [])
        locked = c.value(.locked, false)
        flashcards = c.value(.flashcards, [])
        excerpts = c.value(.excerpts, [])
        isTemplate = c.value(.isTemplate, false)
    }
}

enum NoteSetup: String, CaseIterable, Identifiable {
    case lecture = "Lecture", math = "Math", meeting = "Meeting"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .lecture: "graduationcap"
        case .math: "function"
        case .meeting: "person.2"
        }
    }
    var paper: PaperStyle {
        switch self {
        case .lecture: .cornell
        case .math: .grid
        case .meeting: .meeting
        }
    }
}

enum Prefs {
    private static var d: UserDefaults { .standard }
    static var paperStyle: PaperStyle { PaperStyle(rawValue: d.string(forKey: "defaultPaper") ?? "") ?? .ruled }
    static var paperColor: PaperColor { PaperColor(rawValue: d.string(forKey: "defaultColor") ?? "") ?? .white }
    static var pageSize: PageSize { PageSize(rawValue: d.string(forKey: "defaultSize") ?? "") ?? .letter }
    static var snapToText: Bool { d.object(forKey: "snapToText") as? Bool ?? true }
    static var scribbleErase: Bool { d.bool(forKey: "scribbleErase") }
    static var eraserReturns: Bool { d.object(forKey: "eraserReturns") as? Bool ?? true }
    static var liveTranscribe: Bool { d.object(forKey: "liveTranscribe") as? Bool ?? true }

    static func newPage() -> Page { Page(height: pageSize.height, style: paperStyle, color: paperColor) }
}

extension UIColor {
    /// How a stored color shows on a dark page: grays flip, and colors stay bright enough to read.
    var forDarkPage: UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return UIColor(hue: h, saturation: s, brightness: s < 0.25 ? 1 - b : max(b, 0.75), alpha: a)
    }

    convenience init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0
        self.init(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ c: CGFloat) -> Int { Int((min(max(c, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}
