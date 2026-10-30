// swiftc Margin/Geometry.swift checks/main.swift -o /tmp/margin-check && /tmp/margin-check
import CoreGraphics
import Foundation

func check(_ ok: Bool, _ what: String) {
    if !ok { print("FAIL: \(what)"); exit(1) }
}

// Page layout
let a = UUID(), b = UUID(), c = UUID()
check(NoteLayout.origins([100, 200, 50]) == [0, 120, 340], "origins include the gap")
check(NoteLayout.totalHeight([100, 200]) == 320, "total height has one gap")
check(NoteLayout.pageIndex(y: 110, heights: [100, 200]) == 0, "ink in the gap belongs to the page above")
check(NoteLayout.pageIndex(y: 9999, heights: [100, 200]) == 1, "ink past the end clamps to the last page")

let old = [(id: a, height: CGFloat(100)), (id: b, height: 200), (id: c, height: 50)]
let swapped = NoteLayout.shifts(old: old, new: [old[1], old[0], old[2]])
check(swapped[0] == 220 && swapped[1] == -120 && swapped[2] == 0, "swapping pages moves both, not the third")
let deleted = NoteLayout.shifts(old: old, new: [old[0], old[2]])
check(deleted[0] == 0 && deleted[1] == nil && deleted[2] == -220, "deleting drops its ink and pulls later pages up")

// Shape snapping
let wobblyLine = (0...30).map { CGPoint(x: CGFloat($0) * 10, y: 100 + sin(CGFloat($0)) * 3) }
guard case .line = ShapeSnap.recognize(wobblyLine) else { fatalError("wobbly line") }

let circle = (0...60).map { i -> CGPoint in
    let t = CGFloat(i) / 60 * 2 * .pi
    return CGPoint(x: 200 + cos(t) * (100 + sin(t * 5) * 3), y: 200 + sin(t) * 100)
}
guard case .ellipse = ShapeSnap.recognize(circle) else { fatalError("circle") }

let square = ShapeSnap.outline(.rectangle(CGRect(x: 0, y: 0, width: 200, height: 150)))
guard case .rectangle = ShapeSnap.recognize(square) else { fatalError("rectangle") }

let triangle = ShapeSnap.outline(.triangle(CGPoint(x: 100, y: 0), CGPoint(x: 200, y: 180), CGPoint(x: 0, y: 180)))
guard case .triangle = ShapeSnap.recognize(triangle) else { fatalError("triangle") }

let arrow = ShapeSnap.outline(.arrow(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)))
check(arrow.contains(CGPoint(x: 100, y: 0)) && arrow.first == CGPoint(x: 0, y: 0), "arrow runs from start to tip")
let wave = ShapeSnap.squiggle(fromX: 0, toX: 30, y: 10)
check(wave.count == 6 && wave[0].y < 10 && wave[1].y > 10, "squiggle alternates around the line")
check(ShapeSnap.squiggle(fromX: 5, toX: 5, y: 1).count == 1, "zero-width squiggle is safe")

let scribble = (0...200).map { i -> CGPoint in
    CGPoint(x: 100 + cos(CGFloat(i) * 0.9) * 80, y: 100 + sin(CGFloat(i) * 1.7) * 60)
}
check(ShapeSnap.recognize(scribble) == nil, "scribble stays handwriting")
let letterC = (0...40).map { i -> CGPoint in
    let t = CGFloat(i) / 40 * 1.3 * .pi + 0.35 * .pi
    return CGPoint(x: 100 + cos(t) * 60, y: 100 + sin(t) * 60)
}
check(ShapeSnap.recognize(letterC) == nil, "an open curve is not a shape")
check(ShapeSnap.recognize([CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 2), CGPoint(x: 4, y: 4)]) == nil, "a dot is not a line")

// Math
check(Calc.evaluate("2+3*4") == 14, "precedence")
check(Calc.evaluate("2+3=") == 5, "trailing equals, as handwritten")
check(Calc.evaluate("(1+2)^2") == 9, "power")
check(Calc.evaluate("-2^2") == -4, "unary minus binds looser than power")
check(Calc.evaluate("2x", x: 3) == 6, "implicit multiplication")
check(Calc.evaluate("y = 3(x+1)", x: 1) == 6, "equation body and implicit parens")
check(Calc.evaluate("x²+1", x: 2) == 5, "unicode superscript")
check(Calc.evaluate("6÷2×3") == 9, "unicode operators, left to right")
check(abs(Calc.evaluate("sin(pi/2)")! - 1) < 1e-9, "functions and constants")
check(abs(Calc.evaluate("2sinx", x: .pi / 2)! - 2) < 1e-9, "function with no parens")
check(abs(Calc.evaluate("exp(0)+e")! - (1 + M_E)) < 1e-9, "exp is not e times xp")
check(Calc.evaluate("√16") == 4, "root sign")
check(Calc.evaluate("x+1") == nil, "x with no value")
check(Calc.evaluate("1/0") == nil, "division by zero")
check(Calc.evaluate("2+") == nil, "incomplete")
check(Calc.evaluate("hello") == nil, "words")
check(Calc.evaluate("(1+2") == nil, "unbalanced")
check(Calc.evaluate("") == nil, "empty")

// Spaced repetition
let first = SM2.next(ease: 2.5, interval: 0, reps: 0, grade: .good)
check(first.interval == 1 && first.reps == 1, "first good review is one day")
let second = SM2.next(ease: first.ease, interval: first.interval, reps: first.reps, grade: .good)
check(second.interval == 6, "second good review is six days")
let third = SM2.next(ease: second.ease, interval: second.interval, reps: second.reps, grade: .good)
check(third.interval == 6 * second.ease, "then it grows by ease")
let lapse = SM2.next(ease: 2.5, interval: 30, reps: 5, grade: .again)
check(lapse.reps == 0 && lapse.interval < 0.01 && lapse.ease < 2.5, "again resets the card")
var hardEase = 2.5
for _ in 0..<50 { hardEase = SM2.next(ease: hardEase, interval: 1, reps: 3, grade: .hard).ease }
check(hardEase == 1.3, "ease has a floor")
check(SM2.next(ease: 2.5, interval: 10, reps: 3, grade: .easy).interval > SM2.next(ease: 2.5, interval: 10, reps: 3, grade: .good).interval, "easy beats good")

// Scribble-to-erase
let zigzag = (0...40).map { CGPoint(x: 100 + ($0 % 2 == 0 ? 0 : 60), y: 100 + CGFloat($0)) }
check(Scribble.isScribble(zigzag), "zigzag is a scribble")
let cursive = (0...120).map { i -> CGPoint in
    let t = CGFloat(i)
    let x: CGFloat = t * 3 + sin(t * 0.4) * 8
    let y: CGFloat = 100 + sin(t * 0.8) * 16
    return CGPoint(x: x, y: y)
}
check(!Scribble.isScribble(cursive), "writing along a line is not")
check(!Scribble.isScribble(wobblyLine), "a line is not")

// Transcript phrases
let words: [(text: String, time: TimeInterval, duration: TimeInterval)] = [("a", 0, 0.2), ("b", 0.3, 0.2), ("c", 3, 0.2)]
let phrases = TranscriptGroup.lines(words, offset: 10)
check(phrases.count == 2 && phrases[0].text == "a b" && phrases[1].time == 13, "pause breaks a phrase, offset applied")
check(TranscriptGroup.lines([]).isEmpty, "no words, no lines")

// Text helpers
check(TextTools.jsonArray(in: "Sure!\n```json\n[{\"a\":1}]\n```") == "[{\"a\":1}]".data(using: .utf8), "array out of fences")
check(TextTools.jsonArray(in: "no json") == nil, "no array")
check(TextTools.score(query: "what is mitosis", in: "Mitosis divides cells") == 1, "matches words, skips short ones")

check(TextTools.visibleAnswer("<think>\n\n</think>\n\nHello") == "Hello", "finished reasoning is removed")
check(TextTools.visibleAnswer("<think>still going") == "", "unfinished reasoning shows nothing")
check(TextTools.visibleAnswer("Plain answer\n") == "Plain answer", "plain answers pass through")
check(!TextTools.isSpeech("[BLANK_AUDIO]") && !TextTools.isSpeech("(wind blowing)") && !TextTools.isSpeech(""), "noise markers")
check(TextTools.isSpeech("Today we cover mitosis."), "real speech")
let long = String(repeating: "One sentence here. ", count: 500)
let pieces = TextTools.chunks(long, size: 1000)
check(pieces.joined() == long, "chunks lose nothing")
check(pieces.allSatisfy { $0.count <= 1000 }, "chunks respect the size")
check(pieces.dropLast().allSatisfy { $0.hasSuffix(". ") }, "chunks end at a sentence")
check(TextTools.chunks("short", size: 100) == ["short"], "short text stays whole")
check(TextTools.chunks("", size: 100).isEmpty, "empty text has no chunks")
check(TextTools.chunks(String(repeating: "x", count: 250), size: 100).count == 3, "text with no breaks still splits")
var audio = [Float](repeating: 0.5, count: 16000)
for i in 12000..<12640 { audio[i] = 0 }
let cut = TextTools.quietCut(audio, searchingLast: 8000)
check(cut > 12000 && cut <= 12640, "cuts in the pause")
check(TextTools.quietCut([0.1, 0.2], searchingLast: 100) == 2, "too short to search")

print("ok")
