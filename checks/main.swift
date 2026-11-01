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

// Scratching out, in any direction, against writing that also turns back on itself
func back(and turns: Int, width: CGFloat, drift: CGFloat, vertical: Bool = false, per: Int = 6) -> [CGPoint] {
    (0...(turns * per)).map { i in
        let t = CGFloat(i) / CGFloat(per), phase = t.truncatingRemainder(dividingBy: 2)
        let leg = (phase < 1 ? phase : 2 - phase) * width, moved = t * drift
        return vertical ? CGPoint(x: moved, y: leg) : CGPoint(x: leg, y: moved)
    }
}
check(Scribble.isScribble(back(and: 10, width: 110, drift: 2.4)), "side to side")
check(Scribble.isScribble(back(and: 10, width: 40, drift: 9, vertical: true)), "up and down")
check(Scribble.isScribble(back(and: 8, width: 14, drift: 1)), "tiny and tight")
check(Scribble.isScribble(back(and: 4, width: 90, drift: 2, per: 8)), "just a few strokes back and forth")
check(Scribble.isScribble(back(and: 8, width: 110, drift: 3, per: 2)), "fast, with few points")
check(!Scribble.isScribble(back(and: 3, width: 40, drift: 15, vertical: true)), "the letter W moves along")
check(!Scribble.isScribble(back(and: 6, width: 14, drift: 12, vertical: true)), "mmmm moves along")
let loops = (0...100).map { i -> CGPoint in let t = CGFloat(i) * 0.3; return CGPoint(x: t * 6 + cos(t) * 16, y: sin(t) * 16) }
check(!Scribble.isScribble(loops), "loops aren't scratching")
check(!Scribble.isScribble([CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5)]), "a dot isn't scratching")
check(Scribble.share(of: [CGPoint(x: 1, y: 1), CGPoint(x: 50, y: 50)], in: CGRect(x: 0, y: 0, width: 10, height: 10)) == 0.5, "share of a stroke in an area")

// Live Text stays where it was written
let readLines = [CGRect(x: 90, y: 100, width: 120, height: 40), CGRect(x: 90, y: 200, width: 120, height: 40)]
let written = [CGRect(x: 100, y: 105, width: 30, height: 30), CGRect(x: 140, y: 108, width: 40, height: 30), CGRect(x: 110, y: 210, width: 50, height: 25)]
let placed = NoteLayout.inkBounds(ofLines: readLines, strokes: written)
check(placed[0] == CGRect(x: 100, y: 105, width: 80, height: 33), "a line sits exactly on its own strokes")
check(placed[1] == written[2], "strokes go to the nearest line")
check(NoteLayout.inkBounds(ofLines: readLines, strokes: []) == readLines, "no strokes falls back to what was read")

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

let moving: [(location: CGPoint, time: TimeInterval)] = (0...10).map { (CGPoint(x: CGFloat($0) * 20, y: 0), Double($0) * 0.02) }
check(!ShapeSnap.heldAtEnd(moving), "a stroke that keeps moving isn't held")
check(ShapeSnap.heldAtEnd(moving + [(CGPoint(x: 201, y: 1), 0.8)]), "a pause at the end is a hold")
check(!ShapeSnap.heldAtEnd(moving + [(CGPoint(x: 201, y: 1), 0.3)]), "a brief pause isn't")
check(!ShapeSnap.heldAtEnd([(CGPoint.zero, 0)]), "a single point isn't")

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

// Text helpers
check(TextTools.jsonArray(in: "Sure!\n```json\n[{\"a\":1}]\n```") == "[{\"a\":1}]".data(using: .utf8), "array out of fences")
check(TextTools.jsonArray(in: "no json") == nil, "no array")

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

check(TextTools.cleanMathAnswer("42") == "42", "plain number answer")
check(TextTools.cleanMathAnswer("Steps\nFinal answer: 📌 9") == "9", "stray emoji come off")
check(TextTools.cleanMathAnswer("The answer is:\n\nFinal answer: `9`") == "9", "extracts final answer with backticks")
check(TextTools.cleanMathAnswer("$$\n\\int 2x dx = 9\n$$\nFinal Answer: 9") == "9", "extracts final answer from math explanation")

// Finding the right pages in a long document
let book = ["Intro to the course", "Mitosis divides cells. Mitosis has stages.", "", "Photosynthesis in plants", "More on mitosis"]
let found = TextTools.bestPassages(query: "what is mitosis", passages: book, limit: 60)
check(found.contains(1) && found.contains(4) && !found.contains(3), "picks the matching pages")
check(TextTools.bestPassages(query: "mitosis", passages: ["mitosis and plants and rivers", "mitosis and mitosis and mitosis"], limit: 30).first == 1, "more mentions rank higher")
check(!TextTools.bestPassages(query: "zebra", passages: book, limit: 20).isEmpty, "no match still gives something to read")
check(!TextTools.bestPassages(query: "zebra", passages: book, limit: 1000).contains(2), "empty pages are skipped")
check(TextTools.bestPassages(query: "x", passages: [], limit: 10).isEmpty, "no pages, no passages")
check(TextTools.bestPassages(query: "mitosis", passages: [String(repeating: "mitosis ", count: 100)], limit: 10) == [0], "the best page is kept even if it's over the limit")
check(TextTools.withoutOptionLabel("A. Paris") == "Paris" && TextTools.withoutOptionLabel("B) Rome") == "Rome", "option labels come off")
check(TextTools.withoutOptionLabel("Paris") == "Paris", "plain options stay")

// A rare word outranks a common one, and word endings don't matter
let rarity = ["cells cells cells cells in the body", "cells and mitochondria", "cells of the skin", "cells of the liver"]
check(TextTools.bestPassages(query: "what do mitochondria do in cells", passages: rarity, limit: 10).first == 1, "the rare word decides")
check(TextTools.bestPassages(query: "dividing", passages: ["plants grow", "a cell divides in two"], limit: 10).first == 1, "stems match")

// Text the model writes
check(TextTools.plain("## Topic\n- **Bold** point") == "Topic\n•  Bold point", "markers come off")
check(TextTools.plain("2 * 3 = 6") == "2 * 3 = 6", "a lone asterisk is just a character")

// LaTeX the model writes anyway
check(TextTools.withoutLaTeX("$$\\text{Speed} = \\frac{120}{2} = 60 \\, \\text{km/h}$$").trimmingCharacters(in: .whitespaces) == "Speed = 120/2 = 60 km/h", "display math becomes text")
check(TextTools.withoutLaTeX("$ \\boxed{60} $").trimmingCharacters(in: .whitespaces) == "60", "a boxed answer is just the answer")
check(TextTools.withoutLaTeX("\\frac{a+b}{c}") == "(a+b)/c", "a sum stays grouped")
check(TextTools.withoutLaTeX("\\frac{\\sqrt{x}}{2}") == "√x/2", "nested commands")
check(TextTools.withoutLaTeX("x \\rightarrow y") == "x → y", "a longer command isn't cut short")
check(TextTools.withoutLaTeX("It costs $5 and $6 today.") == "It costs $5 and $6 today.", "money stays")
check(TextTools.withoutLaTeX("$x^{2} = 4$") == "x^2 = 4", "inline math loses its dollars")

// Answers that ran out of room
check(TextTools.withoutCutOffLine("- One.\n- Two states that") == "- One.", "an unfinished last line goes")
check(TextTools.withoutCutOffLine("- One.\n- Two.\n") == "- One.\n- Two.", "a finished answer stays")
check(TextTools.withoutCutOffLine("Only one line") == "Only one line", "a single line is never emptied")

// Tilt for pressure
let degrees = CGFloat.pi / 180
check(abs(TiltPressure.scale(altitude: 56 * degrees, strength: 1) - 1) < 0.001, "a normal writing angle keeps the pen's width")
check(abs(TiltPressure.scale(altitude: 20 * degrees, strength: 1) - 3) < 0.001, "leaning over thickens the line, up to a limit")
check(abs(TiltPressure.scale(altitude: 90 * degrees, strength: 1) - 1 / 3) < 0.001, "upright thins it, down to a limit")
check(TiltPressure.scale(altitude: 40 * degrees, strength: 0.3) < TiltPressure.scale(altitude: 40 * degrees, strength: 1), "strength sets how much it changes")

check(TiltPressure.size(3, visibleFrom: 2, altitude: 20 * degrees, strength: 1) == 5, "only the visible part of a line is scaled")
check(TiltPressure.size(1.5, visibleFrom: 2, altitude: 20 * degrees, strength: 1) == 1.5, "a tapered end stays as it was")

// Undo and redo
var history = History<Int>(limit: 3)
check(history.undo(from: 0) == nil && !history.canUndo, "nothing to undo at first")
history.record(0)
history.record(0)
check(history.undo(from: 1) == 0 && !history.canUndo, "the same state isn't recorded twice")
check(history.redo(from: 0) == 1 && !history.canRedo, "redo returns what undo left")
history.record(1)
check(!history.canRedo, "a new change ends redo")
check(history.undo(from: 1) == 0, "a step that would change nothing is skipped")
var capped = History<Int>(limit: 2)
for state in 1...3 { capped.record(state) }
check(capped.undo(from: 4) == 3 && capped.undo(from: 3) == 2 && capped.undo(from: 2) == nil, "only the newest steps are kept")

print("ok")
