import UIKit

enum PaperCategory: String, CaseIterable, Identifiable {
    case writing = "Writing"
    case grids = "Graph and Grids"
    case study = "Study"
    case planning = "Planning"
    case work = "Work"
    case life = "Life"
    case creative = "Creative"
    case music = "Music"
    var id: String { rawValue }
}

enum PaperStyle: String, Codable, CaseIterable, Identifiable {
    case blank, ruled, wide, narrow, legal, margin, gregg, handwriting, calligraphy, journal
    case grid, graphSmall, graphLarge, engineering, dots, dotsSmall, isometric, hexagon, triangle, coordinate, polar
    case cornell, lecture, vocabulary, problemSet, formula, labReport, readingLog, bookNotes, flashcards, essay
    case daily, weekly, monthly, yearly, timetable, todo, checklist, habits, goals, kanban, timeline
    case meeting, oneOnOne, actionItems, swot, prosCons, retrospective, projectBrief
    case budget, expenses, mealPlan, workout, travel, gratitude
    case storyboard, comic, venn, mindHub, tabletFrame, phoneFrame
    case music, guitarTab, lyrics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wide: "Wide Ruled"
        case .narrow: "Narrow Ruled"
        case .margin: "Ruled with Margin"
        case .gregg: "Center Line"
        case .handwriting: "Handwriting Practice"
        case .graphSmall: "Small Graph"
        case .graphLarge: "Large Graph"
        case .dotsSmall: "Fine Dots"
        case .coordinate: "Coordinate Plane"
        case .polar: "Polar Grid"
        case .lecture: "Lecture Notes"
        case .problemSet: "Problem Set"
        case .formula: "Formula Sheet"
        case .labReport: "Lab Report"
        case .readingLog: "Reading Log"
        case .bookNotes: "Book Notes"
        case .essay: "Essay Outline"
        case .daily: "Daily Planner"
        case .weekly: "Weekly Planner"
        case .monthly: "Monthly Calendar"
        case .yearly: "Year at a Glance"
        case .timetable: "Class Timetable"
        case .todo: "To-Do List"
        case .habits: "Habit Tracker"
        case .kanban: "Kanban Board"
        case .meeting: "Meeting Notes"
        case .oneOnOne: "One-on-One"
        case .actionItems: "Action Items"
        case .swot: "SWOT Analysis"
        case .prosCons: "Pros and Cons"
        case .projectBrief: "Project Brief"
        case .mealPlan: "Meal Plan"
        case .travel: "Travel Plan"
        case .comic: "Comic Panels"
        case .venn: "Venn Diagram"
        case .mindHub: "Mind Map"
        case .tabletFrame: "Tablet Wireframe"
        case .phoneFrame: "Phone Wireframe"
        case .music: "Music Staff"
        case .guitarTab: "Guitar Tab"
        case .lyrics: "Lyric Sheet"
        default: rawValue.capitalized
        }
    }

    var category: PaperCategory {
        switch self {
        case .blank, .ruled, .wide, .narrow, .legal, .margin, .gregg, .handwriting, .calligraphy, .journal: .writing
        case .grid, .graphSmall, .graphLarge, .engineering, .dots, .dotsSmall, .isometric, .hexagon, .triangle, .coordinate, .polar: .grids
        case .cornell, .lecture, .vocabulary, .problemSet, .formula, .labReport, .readingLog, .bookNotes, .flashcards, .essay: .study
        case .daily, .weekly, .monthly, .yearly, .timetable, .todo, .checklist, .habits, .goals, .kanban, .timeline: .planning
        case .meeting, .oneOnOne, .actionItems, .swot, .prosCons, .retrospective, .projectBrief: .work
        case .budget, .expenses, .mealPlan, .workout, .travel, .gratitude: .life
        case .storyboard, .comic, .venn, .mindHub, .tabletFrame, .phoneFrame: .creative
        case .music, .guitarTab, .lyrics: .music
        }
    }
}

/// Draws a paper design in y-down coordinates. Runs on background threads while pages paint.
struct PaperArt {
    let ctx: CGContext
    let size: CGSize
    let lineColor: UIColor
    let labelColor: UIColor

    private var w: CGFloat { size.width }
    private var h: CGFloat { size.height }

    private func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
        ctx.move(to: CGPoint(x: x1, y: y1))
        ctx.addLine(to: CGPoint(x: x2, y: y2))
    }

    private func rules(_ step: CGFloat, from top: CGFloat = 72, to bottom: CGFloat? = nil, x: CGFloat = 0, end: CGFloat? = nil) {
        for y in stride(from: top, to: bottom ?? h, by: step) { line(x, y, end ?? w, y) }
    }

    private func grid(_ step: CGFloat) {
        rules(step, from: 0)
        for x in stride(from: CGFloat(0), to: w, by: step) { line(x, 0, x, h) }
    }

    private func dots(_ step: CGFloat, radius: CGFloat) {
        for y in stride(from: step, to: h, by: step) {
            for x in stride(from: step, to: w, by: step) {
                ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
        }
    }

    private func label(_ text: String, _ x: CGFloat, _ y: CGFloat, size fontSize: CGFloat = 13) {
        NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: labelColor,
        ]).draw(at: CGPoint(x: x, y: y))
    }

    private func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
        ctx.addRect(CGRect(x: x, y: y, width: width, height: height))
    }

    /// Labelled sections stacked down the page; each entry is a title and its share of the height.
    private func sections(_ parts: [(String, CGFloat)], top: CGFloat = 28) {
        var y = top
        let room = h - top - 20
        for (title, share) in parts {
            label(title, 28, y + 8)
            y += room * share
            line(28, y, w - 28, y)
        }
    }

    private func table(_ headers: [String], widths: [CGFloat], top: CGFloat = 60, rowHeight: CGFloat = 36) {
        let inner = w - 56, total = widths.reduce(0, +)
        var x: CGFloat = 28
        for (title, share) in zip(headers, widths) {
            label(title, x + 6, top + 8)
            line(x, top, x, h - 28)
            x += inner * share / total
        }
        line(w - 28, top, w - 28, h - 28)
        for y in stride(from: top, through: h - 28, by: rowHeight) { line(28, y, w - 28, y) }
    }

    private func checkboxes(from top: CGFloat, step: CGFloat, x: CGFloat, end: CGFloat) {
        for y in stride(from: top, to: h - 36, by: step) {
            box(x, y + step - 26, 18, 18)
            line(x + 28, y + step - 6, end, y + step - 6)
        }
    }

    func draw(_ style: PaperStyle) {
        ctx.setStrokeColor(lineColor.cgColor)
        ctx.setFillColor(lineColor.cgColor)
        ctx.setLineWidth(1)
        switch style {
        case .blank: break
        case .ruled: rules(34)
        case .wide: rules(44)
        case .narrow: rules(24)
        case .legal:
            rules(34)
            ctx.strokePath()
            ctx.setStrokeColor(UIColor.systemRed.withAlphaComponent(0.45).cgColor)
            line(84, 0, 84, h)
            line(89, 0, 89, h)
        case .margin:
            rules(34)
            ctx.strokePath()
            ctx.setStrokeColor(UIColor.systemRed.withAlphaComponent(0.45).cgColor)
            line(90, 0, 90, h)
        case .gregg:
            rules(30)
            line(w / 2, 0, w / 2, h)
        case .handwriting:
            for top in stride(from: CGFloat(60), to: h - 60, by: 84) {
                line(28, top, w - 28, top)
                line(28, top + 48, w - 28, top + 48)
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [6, 5])
                line(28, top + 24, w - 28, top + 24)
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            }
        case .calligraphy:
            rules(40, from: 48)
            let rise = h * tan(.pi / 10)
            for x in stride(from: -rise, to: w, by: 64) { line(x, h, x + rise, 0) }
        case .journal:
            label("Date", 28, 28)
            line(70, 44, 260, 44)
            rules(34, from: 90)
        case .grid: grid(28)
        case .graphSmall: grid(14)
        case .graphLarge: grid(48)
        case .engineering:
            grid(14)
            ctx.strokePath()
            ctx.setLineWidth(1.6)
            grid(70)
        case .dots: dots(28, radius: 1.25)
        case .dotsSmall: dots(14, radius: 0.9)
        case .isometric:
            let step: CGFloat = 32, rise = w * tan(.pi / 6)
            for x in stride(from: CGFloat(0), to: w, by: step * cos(.pi / 6)) { line(x, 0, x, h) }
            for y in stride(from: -rise, to: h + rise, by: step) {
                line(0, y, w, y + rise)
                line(0, y + rise, w, y)
            }
        case .triangle:
            let step: CGFloat = 36, rise = w * tan(.pi / 3)
            rules(step * sin(.pi / 3), from: 0)
            for y in stride(from: -rise, to: h + rise, by: step * 2 * sin(.pi / 3)) {
                line(0, y, w, y + rise)
                line(0, y + rise, w, y)
            }
        case .hexagon:
            let r: CGFloat = 22, dx = r * 1.5, dy = r * sqrt(3)
            for (column, x) in stride(from: CGFloat(0), to: w + dx, by: dx).enumerated() {
                let shift = column % 2 == 0 ? 0 : dy / 2
                for y in stride(from: -dy, to: h + dy, by: dy) {
                    let cy = y + shift
                    for side in 0..<6 {
                        let a = CGFloat(side) * .pi / 3, b = CGFloat(side + 1) * .pi / 3
                        line(x + r * cos(a), cy + r * sin(a), x + r * cos(b), cy + r * sin(b))
                    }
                }
            }
        case .coordinate:
            grid(28)
            ctx.strokePath()
            ctx.setStrokeColor(labelColor.cgColor)
            ctx.setLineWidth(1.6)
            let cx = (w / 2 / 28).rounded() * 28, cy = (h / 2 / 28).rounded() * 28
            line(cx, 0, cx, h)
            line(0, cy, w, cy)
        case .polar:
            let center = CGPoint(x: w / 2, y: h / 2), reach = hypot(w, h) / 2
            for radius in stride(from: CGFloat(40), to: reach, by: 40) {
                ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
            for degree in stride(from: CGFloat(0), to: 360, by: 15) {
                let a = degree * .pi / 180
                line(center.x, center.y, center.x + cos(a) * reach, center.y + sin(a) * reach)
            }
        case .cornell:
            let summary = max(h - 170, h * 0.7)
            rules(34, to: summary)
            ctx.strokePath()
            ctx.setLineWidth(2)
            line(190, 0, 190, summary)
            line(0, summary, w, summary)
            label("Cues", 16, 40)
            label("Notes", 206, 40)
            label("Summary", 16, summary + 10)
        case .lecture:
            label("Course", 28, 24)
            label("Date", w - 220, 24)
            label("Topic", 28, 54)
            line(28, 80, w - 28, 80)
            rules(34, from: 114)
        case .vocabulary: table(["Word", "Meaning", "Example"], widths: [1, 1.5, 1.5], rowHeight: 62)
        case .problemSet:
            grid(28)
            ctx.strokePath()
            label("Name", 28, 24)
            label("Due", w - 220, 24)
            line(28, 50, w - 28, 50)
            for (i, y) in stride(from: CGFloat(70), to: h - 100, by: 210).enumerated() { label("\(i + 1).", 34, y) }
        case .formula:
            label("Formula Sheet", 28, 24, size: 16)
            let bw = (w - 76) / 2, bh = (h - 96) / 6
            for row in 0..<6 {
                for column in 0..<2 { box(28 + CGFloat(column) * (bw + 20), 60 + CGFloat(row) * bh, bw, bh - 8) }
            }
        case .labReport:
            sections([("Title and Date", 0.08), ("Question", 0.1), ("Hypothesis", 0.1), ("Materials", 0.12), ("Procedure", 0.18), ("Results", 0.24), ("Conclusion", 0.18)])
        case .readingLog: table(["Title", "Author", "Pages", "Finished"], widths: [2, 1.4, 0.6, 0.8])
        case .bookNotes:
            sections([("Title and Author", 0.1), ("Key Ideas", 0.32), ("Favorite Passages", 0.24), ("Questions", 0.14), ("What I'll Do Differently", 0.2)])
        case .flashcards:
            let bw = (w - 76) / 2, bh = (h - 76) / 5
            for row in 0..<5 {
                for column in 0..<2 { box(28 + CGFloat(column) * (bw + 20), 28 + CGFloat(row) * bh, bw, bh - 16) }
                label("Question", 36, 36 + CGFloat(row) * bh)
                label("Answer", 36 + bw + 20, 36 + CGFloat(row) * bh)
            }
        case .essay:
            sections([("Thesis", 0.12), ("Introduction", 0.14), ("Point One", 0.17), ("Point Two", 0.17), ("Point Three", 0.17), ("Conclusion", 0.14), ("Sources", 0.09)])
        case .daily:
            label("Date", 28, 28)
            line(28, 56, w - 28, 56)
            let hours = 7...21, row = (h - 80) / CGFloat(hours.count)
            for (i, hour) in hours.enumerated() {
                let y = 68 + CGFloat(i) * row
                label(String(format: "%02d:00", hour), 28, y + 4)
                line(84, y + row, w - 28, y + row)
            }
            line(84, 68, 84, h - 12)
        case .weekly:
            label("Week of", 28, 28)
            let days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "Notes"]
            let bw = (w - 56) / 2, bh = (h - 80) / 4
            for (i, day) in days.enumerated() {
                let x = 28 + CGFloat(i % 2) * bw, y = 60 + CGFloat(i / 2) * bh
                box(x, y, bw, bh)
                label(day, x + 10, y + 8)
            }
        case .monthly:
            label("Month", 28, 24, size: 16)
            let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], cw = (w - 56) / 7, ch = (h - 110) / 6
            for (i, day) in days.enumerated() { label(day, 28 + CGFloat(i) * cw + 6, 66) }
            for row in 0..<6 {
                for column in 0..<7 { box(28 + CGFloat(column) * cw, 90 + CGFloat(row) * ch, cw, ch) }
            }
        case .yearly:
            let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
            let bw = (w - 56) / 3, bh = (h - 56) / 4
            for (i, month) in months.enumerated() {
                let x = 28 + CGFloat(i % 3) * bw, y = 28 + CGFloat(i / 3) * bh
                box(x, y, bw, bh)
                label(month, x + 10, y + 8)
            }
        case .timetable:
            table(["Time", "Mon", "Tue", "Wed", "Thu", "Fri"], widths: [0.8, 1, 1, 1, 1, 1], rowHeight: 74)
        case .todo:
            label("To Do", 28, 36)
            checkboxes(from: 62, step: 44, x: 28, end: w - 28)
        case .checklist:
            label("Today", 28, 28)
            label("This Week", w / 2 + 10, 28)
            checkboxes(from: 50, step: 40, x: 28, end: w / 2 - 14)
            checkboxes(from: 50, step: 40, x: w / 2 + 10, end: w - 28)
        case .habits:
            label("Month", 28, 24, size: 16)
            let first: CGFloat = 170, cell = (w - 28 - first) / 31
            for day in 0..<31 where day % 2 == 0 { label("\(day + 1)", first + CGFloat(day) * cell, 56, size: 8) }
            for y in stride(from: CGFloat(74), through: h - 28, by: 34) { line(28, y, w - 28, y) }
            for day in 0...31 { line(first + CGFloat(day) * cell, 74, first + CGFloat(day) * cell, h - 28) }
            line(28, 74, 28, h - 28)
        case .goals:
            for (i, name) in ["Goal One", "Goal Two", "Goal Three"].enumerated() {
                let top = 28 + CGFloat(i) * (h - 56) / 3, height = (h - 56) / 3
                box(28, top, w - 56, height - 14)
                label(name, 40, top + 10)
                label("Why it matters", 40, top + height * 0.26)
                label("Next steps", 40, top + height * 0.5)
            }
        case .kanban:
            let bw = (w - 56) / 3
            for (i, name) in ["To Do", "Doing", "Done"].enumerated() {
                let x = 28 + CGFloat(i) * bw
                box(x, 28, bw, h - 56)
                label(name, x + 10, 38)
                line(x, 64, x + bw, 64)
            }
        case .timeline:
            label("Project", 28, 24, size: 16)
            line(60, 70, 60, h - 28)
            for y in stride(from: CGFloat(90), to: h - 40, by: 110) {
                ctx.addEllipse(in: CGRect(x: 54, y: y - 6, width: 12, height: 12))
                line(84, y + 44, w - 28, y + 44)
                line(84, y + 84, w - 28, y + 84)
            }
        case .meeting:
            label("Meeting", 28, 28)
            label("Date", w - 240, 28)
            line(28, 56, w - 28, 56)
            label("Attendees", 28, 68)
            line(28, 130, w - 28, 130)
            label("Agenda", 28, 142)
            line(28, h * 0.36, w - 28, h * 0.36)
            label("Notes", 28, h * 0.36 + 12)
            line(28, h * 0.76, w - 28, h * 0.76)
            label("Action Items", 28, h * 0.76 + 12)
        case .oneOnOne:
            sections([("Name and Date", 0.08), ("How Are Things Going?", 0.2), ("Wins", 0.16), ("Blockers", 0.18), ("Growth", 0.16), ("Next Steps", 0.22)])
        case .actionItems: table(["Done", "Task", "Owner", "Due"], widths: [0.5, 3, 1, 0.9], rowHeight: 46)
        case .swot:
            let bw = (w - 56) / 2, bh = (h - 56) / 2
            for (i, name) in ["Strengths", "Weaknesses", "Opportunities", "Threats"].enumerated() {
                let x = 28 + CGFloat(i % 2) * bw, y = 28 + CGFloat(i / 2) * bh
                box(x, y, bw, bh)
                label(name, x + 10, y + 8)
            }
        case .prosCons:
            label("Decision", 28, 24, size: 16)
            line(28, 56, w - 28, 56)
            line(w / 2, 56, w / 2, h - 28)
            label("Pros", 40, 68)
            label("Cons", w / 2 + 12, 68)
            rules(34, from: 96, to: h - 28, x: 28, end: w - 28)
        case .retrospective:
            let bw = (w - 56) / 3
            for (i, name) in ["Went Well", "Could Be Better", "Try Next"].enumerated() {
                box(28 + CGFloat(i) * bw, 28, bw, h - 56)
                label(name, 38 + CGFloat(i) * bw, 38)
            }
        case .projectBrief:
            sections([("Project", 0.08), ("Goal", 0.14), ("Audience", 0.12), ("Scope", 0.2), ("Milestones", 0.22), ("Risks", 0.12), ("Contacts", 0.12)])
        case .budget:
            label("Month", 28, 24, size: 16)
            table(["Category", "Planned", "Actual", "Difference"], widths: [2, 1, 1, 1])
        case .expenses: table(["Date", "Item", "Category", "Amount"], widths: [0.8, 2, 1, 0.8])
        case .mealPlan:
            let row = (h - 100) / 8
            table(["Day", "Breakfast", "Lunch", "Dinner"], widths: [0.7, 1, 1, 1], rowHeight: row)
            for (i, day) in ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].enumerated() { label(day, 36, 68 + row * CGFloat(i + 1)) }
        case .workout: table(["Exercise", "Sets", "Reps", "Weight", "Notes"], widths: [2, 0.6, 0.6, 0.8, 1.5], rowHeight: 42)
        case .travel:
            sections([("Destination and Dates", 0.1), ("Bookings", 0.16), ("Itinerary", 0.34), ("Packing", 0.22), ("Budget", 0.18)])
        case .gratitude:
            sections([("Date", 0.08), ("Three Things I'm Grateful For", 0.28), ("What Would Make Today Great", 0.22), ("Today's Thought", 0.14), ("Tonight, Looking Back", 0.28)])
        case .storyboard:
            let bw = (w - 84) / 2, row = (h - 56) / 3
            for i in 0..<6 {
                let x = 28 + CGFloat(i % 2) * (bw + 28), y = 28 + CGFloat(i / 2) * row
                box(x, y, bw, row * 0.66)
                line(x, y + row * 0.76, x + bw, y + row * 0.76)
                line(x, y + row * 0.88, x + bw, y + row * 0.88)
            }
        case .comic:
            let top = (h - 72) * 0.3, middle = (h - 72) * 0.36, bottom = (h - 72) * 0.34
            box(28, 28, w - 56, top)
            box(28, 36 + top, (w - 64) * 0.4, middle)
            box(36 + (w - 64) * 0.4, 36 + top, (w - 64) * 0.6, middle)
            box(28, 44 + top + middle, (w - 72) / 3, bottom)
            box(36 + (w - 72) / 3, 44 + top + middle, (w - 72) / 3, bottom)
            box(44 + (w - 72) * 2 / 3, 44 + top + middle, (w - 72) / 3, bottom)
        case .venn:
            let radius = min(w, h) * 0.3, y = h / 2
            ctx.addEllipse(in: CGRect(x: w / 2 - radius * 1.5, y: y - radius, width: radius * 2, height: radius * 2))
            ctx.addEllipse(in: CGRect(x: w / 2 - radius * 0.5, y: y - radius, width: radius * 2, height: radius * 2))
            label("A", w / 2 - radius * 1.1, y - radius - 24)
            label("B", w / 2 + radius, y - radius - 24)
        case .mindHub:
            let c = CGPoint(x: w / 2, y: h / 2)
            ctx.addEllipse(in: CGRect(x: c.x - 80, y: c.y - 44, width: 160, height: 88))
            for spoke in 0..<6 {
                let a = CGFloat(spoke) * .pi / 3 + .pi / 6, r = min(w, h) * 0.36
                let end = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                line(c.x + cos(a) * 86, c.y + sin(a) * 50, end.x, end.y)
                ctx.addEllipse(in: CGRect(x: end.x - 58, y: end.y - 30, width: 116, height: 60))
            }
        case .tabletFrame:
            let frame = CGRect(x: 60, y: (h - (w - 120) * 1.33) / 2, width: w - 120, height: (w - 120) * 1.33)
            ctx.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 22).cgPath)
            line(frame.minX, frame.minY + 44, frame.maxX, frame.minY + 44)
        case .phoneFrame:
            let fw = (w - 96) / 3, fh = fw * 2.05
            for row in 0..<2 {
                for column in 0..<3 {
                    let frame = CGRect(x: 28 + CGFloat(column) * (fw + 20), y: 40 + CGFloat(row) * (fh + 40), width: fw, height: fh)
                    ctx.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 18).cgPath)
                }
            }
        case .music:
            for top in stride(from: CGFloat(64), to: h - 60, by: 100) {
                for i in 0..<5 { line(36, top + CGFloat(i) * 10, w - 36, top + CGFloat(i) * 10) }
            }
        case .guitarTab:
            for top in stride(from: CGFloat(64), to: h - 70, by: 104) {
                for i in 0..<6 { line(36, top + CGFloat(i) * 9, w - 36, top + CGFloat(i) * 9) }
                label("T", 20, top - 4, size: 11)
                label("A", 20, top + 13, size: 11)
                label("B", 20, top + 30, size: 11)
            }
        case .lyrics:
            label("Title", 28, 24, size: 16)
            for top in stride(from: CGFloat(70), to: h - 80, by: 180) {
                label("Chords", 28, top)
                for row in 0..<4 { line(28, top + 36 + CGFloat(row) * 34, w - 28, top + 36 + CGFloat(row) * 34) }
            }
        }
        ctx.strokePath()
    }
}
