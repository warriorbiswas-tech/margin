package com.warriorbiswas.margin

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/** Turns how far a stylus leans into how hard it seems to press, for a stylus that can't feel pressure. */
object TiltPressure {
    private val writingAngle = 56 * PI / 180
    private val fullLean = 20 * PI / 180

    /** A line width multiplier: 1 at a normal writing angle, up to 3 leaning over and down to a third upright, at full strength. */
    fun scale(altitude: Double, strength: Double): Double {
        val lean = max(-1.0, min(1.0, (writingAngle - altitude) / fullLean))
        return 3.0.pow(lean * strength)
    }
}

data class Point(val x: Float, val y: Float)

private fun dist(a: Point, b: Point) = hypot(a.x - b.x, a.y - b.y)

/** The same shapes as the iPad: draw one, keep the pen still at the end, and it comes out clean. */
object ShapeSnap {
    const val HOLD_MILLIS = 450L

    fun recognize(points: List<Point>): List<Point>? {
        if (points.size < 3) return null
        val first = points.first()
        val last = points.last()
        val length = points.zipWithNext { a, b -> dist(a, b) }.sum()
        if (length <= 24) return null
        if (dist(first, last) / length > 0.92f) return subdivide(first, last, 8)

        val left = points.minOf { it.x }
        val right = points.maxOf { it.x }
        val top = points.minOf { it.y }
        val bottom = points.maxOf { it.y }
        val w = right - left
        val h = bottom - top
        // More than once round is a scribble.
        if (w <= 16 || h <= 16 || dist(first, last) >= 0.25f * max(w, h) || length >= 1.5f * 2 * (w + h)) return null

        // Normalised so the bounding box spans -1...1: an ellipse has radius 1, a rectangle max(|x|,|y|) = 1.
        val midX = (left + right) / 2
        val midY = (top + bottom) / 2
        var ellipseError = 0f
        var rectError = 0f
        for (p in points) {
            val nx = (p.x - midX) / (w / 2)
            val ny = (p.y - midY) / (h / 2)
            ellipseError += abs(hypot(nx, ny) - 1)
            rectError += abs(max(abs(nx), abs(ny)) - 1)
        }
        ellipseError /= points.size
        rectError /= points.size
        if (min(ellipseError, rectError) < 0.1f) {
            if (ellipseError <= rectError) {
                return (0..48).map { i ->
                    val t = i / 48.0 * 2 * PI
                    Point(midX + cos(t).toFloat() * w / 2, midY + sin(t).toFloat() * h / 2)
                }
            }
            return polygon(listOf(Point(left, top), Point(right, top), Point(right, bottom), Point(left, bottom), Point(left, top)))
        }
        val corners = simplify(points, 0.1f * max(w, h))
        if (corners.size == 4 && dist(corners[0], corners[3]) < 0.25f * max(w, h)) {
            return polygon(listOf(corners[0], corners[1], corners[2], corners[0]))
        }
        return null
    }

    private fun polygon(corners: List<Point>) = corners.zipWithNext { a, b -> subdivide(a, b, 6) }.flatten()

    private fun subdivide(a: Point, b: Point, parts: Int) = (0..parts).map { i ->
        val t = i.toFloat() / parts
        Point(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
    }

    /** Ramer-Douglas-Peucker: keeps only the points that define the outline's corners. */
    private fun simplify(points: List<Point>, tolerance: Float): List<Point> {
        if (points.size <= 2) return points
        val a = points.first()
        val b = points.last()
        val length = max(dist(a, b), 0.001f)
        var farthest = 0
        var distance = 0f
        for (i in 1 until points.size - 1) {
            val p = points[i]
            val d = if (dist(a, b) < 0.001f) dist(p, a) else abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / length
            if (d > distance) {
                distance = d
                farthest = i
            }
        }
        if (distance <= tolerance) return listOf(a, b)
        return simplify(points.subList(0, farthest + 1), tolerance).dropLast(1) + simplify(points.subList(farthest, points.size), tolerance)
    }
}

/** Scratching out in any direction: a stroke that goes back and forth along one line, and travels far for the patch it covers. */
object Scribble {
    fun isScribble(points: List<Point>): Boolean {
        if (points.size < 6) return false
        // The direction most of the stroke runs along. Doubling the angles lets opposite directions count as one.
        var cosine = 0f
        var sine = 0f
        var length = 0f
        for ((a, b) in points.zipWithNext()) {
            val dx = b.x - a.x
            val dy = b.y - a.y
            val size = hypot(dx, dy)
            if (size <= 0) continue
            cosine += (dx * dx - dy * dy) / size
            sine += 2 * dx * dy / size
            length += size
        }
        // Loops run every way equally, so they have no direction to go back and forth in.
        if (length <= 0 || hypot(cosine, sine) / length < 0.5f) return false
        val angle = atan2(sine, cosine) / 2
        val ax = cos(angle)
        val ay = sin(angle)
        val along = points.map { it.x * ax + it.y * ay }
        val across = points.map { it.y * ax - it.x * ay }
        val reach = along.max() - along.min()
        val spread = across.max() - across.min()
        if (reach < 8) return false

        var extreme = along[0]
        var heading = 0f
        var turns = 0
        val slack = max(reach * 0.3f, 3f)
        for (value in along) {
            val moved = value - extreme
            if (heading == 0f) {
                if (abs(moved) > slack) {
                    heading = if (moved > 0) 1f else -1f
                    extreme = value
                }
            } else if (moved * heading > 0) {
                extreme = value
            } else if (abs(moved) > slack) {
                turns += 1
                heading = -heading
                extreme = value
            }
        }
        // Letters like M and W turn back too, but scratching travels several times the size of the patch it covers.
        return turns >= 3 && length / hypot(reach, spread) >= 3.4f
    }
}

object SM2 {
    enum class Grade(val value: Int, val title: String) {
        Again(1, "Again"),
        Hard(3, "Hard"),
        Good(4, "Good"),
        Easy(5, "Easy"),
    }

    data class Next(val ease: Double, val interval: Double, val reps: Int)

    fun next(ease: Double, interval: Double, reps: Int, grade: Grade): Next {
        val q = grade.value.toDouble()
        val newEase = max(1.3, ease + 0.1 - (5 - q) * (0.08 + (5 - q) * 0.02))
        if (grade == Grade.Again) return Next(newEase, 10.0 / 1440, 0) // back in ten minutes
        val newReps = reps + 1
        val days = when {
            newReps == 1 -> 1.0
            newReps == 2 && grade == Grade.Hard -> 3.0
            newReps == 2 -> 6.0
            grade == Grade.Hard -> interval * 1.2
            grade == Grade.Easy -> interval * newEase * 1.3
            else -> interval * newEase
        }
        return Next(newEase, days, newReps)
    }
}

object TextTools {
    /** Drops the reasoning block this model family can open with, finished or still being written. */
    fun visibleAnswer(raw: String): String {
        var text = raw.replace("�", "")
        val end = text.indexOf("</think>")
        if (end >= 0) {
            text = text.substring(end + "</think>".length)
        } else if (text.startsWith("<think>")) {
            return ""
        }
        return text.trim()
    }

    /** An answer that ran out of room stops mid-sentence, so its unfinished last line goes. */
    fun withoutCutOffLine(text: String): String {
        val trimmed = text.trim()
        val last = trimmed.lastOrNull() ?: return trimmed
        val lineStart = trimmed.lastIndexOf('\n')
        if (last in ".!?:)*" || lineStart < 0) return trimmed
        return trimmed.substring(0, lineStart).trim()
    }

    fun withoutOptionLabel(option: String): String {
        val trimmed = option.trim()
        if (trimmed.length < 2 || !trimmed[0].isUpperCase() || (trimmed[1] != '.' && trimmed[1] != ')')) return trimmed
        return trimmed.substring(2).trim()
    }

    fun jsonArray(text: String): String? {
        val a = text.indexOf('[')
        val b = text.lastIndexOf(']')
        return if (a in 0 until b) text.substring(a, b + 1) else null
    }

    fun chunks(text: String, size: Int): List<String> {
        val result = mutableListOf<String>()
        var rest = text
        while (rest.length > size) {
            val breakAt = rest.lastIndexOf('\n', size).takeIf { it > size / 2 } ?: rest.lastIndexOf(' ', size).takeIf { it > size / 2 } ?: size
            result += rest.substring(0, breakAt)
            rest = rest.substring(breakAt).trimStart()
        }
        if (rest.isNotBlank()) result += rest
        return result
    }

    /** Words in the question scored against each passage, so only what's relevant goes to the model. */
    fun relevantPassages(passages: List<Pair<Int, String>>, question: String, limit: Int): String {
        val words = question.lowercase().split(Regex("\\W+")).filter { it.length > 2 }.toSet()
        val pieces = passages.flatMap { (page, text) -> chunks(text, 1500).map { page to it } }
        val ranked = pieces.withIndex().sortedByDescending { (index, piece) ->
            val lower = piece.second.lowercase()
            words.count { it in lower } * 1000 - index
        }
        val picked = StringBuilder()
        for ((_, piece) in ranked) {
            val labelled = "Page ${piece.first}: ${piece.second}\n\n"
            if (picked.length + labelled.length > limit) break
            picked.append(labelled)
        }
        return picked.toString().trim()
    }
}
