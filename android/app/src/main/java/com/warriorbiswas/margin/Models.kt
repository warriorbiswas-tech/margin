package com.warriorbiswas.margin

import android.graphics.Color
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.util.UUID

fun newId(): String = UUID.randomUUID().toString()

object NoteLayout {
    const val WIDTH = 768f
    const val PAPER_HEIGHT = 994f // US Letter ratio
    const val GAP = 20f
}

fun colorOf(hex: String): Int = try {
    Color.parseColor("#$hex")
} catch (_: IllegalArgumentException) {
    Color.BLACK
}

@Serializable
enum class PaperColor(val title: String, val fillHex: String) {
    white("White", "FFFFFF"),
    cream("Cream", "FBF6E9"),
    yellow("Yellow", "FFF6C7"),
    blue("Blue", "EAF1F8"),
    green("Green", "EDF3EA"),
    gray("Gray", "E9EAEC"),
    dark("Dark", "1F2125");

    val fill: Int get() = colorOf(fillHex)
    val line: Int get() = if (this == dark) Color.argb(41, 255, 255, 255) else Color.argb(64, 64, 102, 166)
    val label: Int get() = if (this == dark) Color.argb(140, 255, 255, 255) else Color.argb(178, 64, 64, 64)
}

@Serializable
enum class PaperStyle(val title: String) {
    blank("Blank"),
    ruled("Ruled"),
    wide("Wide Ruled"),
    narrow("Narrow Ruled"),
    legal("Legal"),
    margin("Ruled with Margin"),
    gregg("Center Line"),
    handwriting("Handwriting Practice"),
    grid("Grid"),
    graphSmall("Small Graph"),
    graphLarge("Large Graph"),
    engineering("Engineering"),
    dots("Dots"),
    dotsSmall("Fine Dots"),
    cornell("Cornell"),
    todo("To-Do List"),
    meeting("Meeting Notes"),
}

enum class NoteSetup(val title: String, val paper: PaperStyle) {
    Lecture("Lecture", PaperStyle.cornell),
    Math("Math", PaperStyle.grid),
    Meeting("Meeting", PaperStyle.meeting),
}

enum class PageSize(val title: String, val height: Float) {
    letter("US Letter", NoteLayout.PAPER_HEIGHT),
    a4("A4", 1086f),
    square("Square", 768f),
    slide("Slide (16:9)", 432f),
    long("Long Whiteboard", 3072f),
}

@Serializable
data class Page(
    val id: String = newId(),
    val height: Float = NoteLayout.PAPER_HEIGHT,
    val style: PaperStyle = PaperStyle.ruled,
    val color: PaperColor = PaperColor.white,
    val pdfPage: Int? = null, // index into source.pdf; null for plain paper
    val bookmarked: Boolean = false,
    val endless: Boolean = false, // grows as you write instead of turning over to a new page
)

/** A typed box or a picture, placed on a page under the ink. */
@Serializable
data class Element(
    val id: String = newId(),
    val pageId: String,
    val x: Float,
    val y: Float,
    val w: Float,
    val h: Float,
    val text: String = "",
    val fontSize: Float = 20f,
    val colorHex: String = "1C1C1E",
    val imageFile: String? = null,
    val fillHex: String? = null, // sticky note background
    val stamp: Boolean = false,
) {
    val inset: Float get() = if (fillHex == null && !stamp) 0f else 10f
}

@Serializable
data class Recording(
    val id: String = newId(),
    val file: String,
    val startedAt: Long,
    val durationMs: Long,
)

@Serializable
data class Flashcard(
    val id: String = newId(),
    val front: String,
    val back: String,
    val ease: Double = 2.5,
    val interval: Double = 0.0,
    val reps: Int = 0,
    val due: Long = System.currentTimeMillis(),
) {
    fun applying(grade: SM2.Grade): Flashcard {
        val next = SM2.next(ease, interval, reps, grade)
        return copy(ease = next.ease, interval = next.interval, reps = next.reps, due = System.currentTimeMillis() + (next.interval * 86_400_000).toLong())
    }
}

@Serializable
data class Subject(
    val id: String = newId(),
    val name: String,
    val colorHex: String = "6B7A90",
    val parentId: String? = null,
)

@Serializable
data class Note(
    val id: String = newId(),
    val title: String = "Untitled",
    val subjectId: String? = null,
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
    val favorite: Boolean = false,
    val deletedAt: Long? = null,
    val pages: List<Page> = listOf(Page()),
    val elements: List<Element> = emptyList(),
    val recordings: List<Recording> = emptyList(),
    val printedText: Map<String, String> = emptyMap(), // a PDF's own text, by page
    val pageText: Map<String, String> = emptyMap(), // recognised handwriting, by page
    val inkSignatures: Map<String, String> = emptyMap(), // which ink pageText was read from
    val flashcards: List<Flashcard> = emptyList(),
    val tags: List<String> = emptyList(),
    val locked: Boolean = false,
    val isTemplate: Boolean = false,
    val coverHex: String? = null,
) {
    /** Everything readable in the note, labelled by page so answers can name theirs. */
    fun passages(): List<Pair<Int, String>> = pages.mapIndexedNotNull { index, page ->
        val typed = elements.filter { it.pageId == page.id && it.text.isNotBlank() }.joinToString("\n") { it.text }
        val text = listOf(printedText[page.id].orEmpty(), pageText[page.id].orEmpty(), typed).filter { it.isNotBlank() }.joinToString("\n")
        if (text.isBlank()) null else (index + 1) to text
    }

    fun fullText(): String = passages().joinToString("\n\n") { it.second }
}

/** Ink lives apart from note.json, since it's far larger and changes with every stroke. */
@Serializable
class Stroke(
    val id: String = newId(),
    val pageId: String,
    val tool: String, // "pen" or "highlighter"
    val colorHex: String,
    val width: Float,
    val t: Long = System.currentTimeMillis(), // when it was written, so a tap can find it in a recording
    val points: FloatArray, // x, y, width for each point, in page coordinates
) {
    val count: Int get() = points.size / 3

    fun moved(dx: Float, dy: Float): Stroke {
        val shifted = points.copyOf()
        var i = 0
        while (i < shifted.size) {
            shifted[i] += dx
            shifted[i + 1] += dy
            i += 3
        }
        return Stroke(id, pageId, tool, colorHex, width, t, shifted)
    }
}

@Serializable
class NoteInk(val strokes: List<Stroke> = emptyList())

// Saved notes must survive app updates: a field added later falls back to its default.
val MarginJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    coerceInputValues = true
}
