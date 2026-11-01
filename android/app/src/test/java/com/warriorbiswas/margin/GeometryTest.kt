package com.warriorbiswas.margin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI

/** The same promises checks/main.swift holds the iPad to. */
class GeometryTest {
    private val degrees = PI / 180

    @Test
    fun tiltKeepsAWritingAngleEven() = assertEquals(1.0, TiltPressure.scale(56 * degrees, 1.0), 0.001)

    @Test
    fun leaningThickensUpToALimit() = assertEquals(3.0, TiltPressure.scale(20 * degrees, 1.0), 0.001)

    @Test
    fun uprightThinsDownToALimit() = assertEquals(1.0 / 3, TiltPressure.scale(90 * degrees, 1.0), 0.001)

    @Test
    fun strengthSetsHowMuchItChanges() = assertTrue(TiltPressure.scale(40 * degrees, 0.3) < TiltPressure.scale(40 * degrees, 1.0))

    @Test
    fun againComesBackInTenMinutes() {
        val next = SM2.next(2.5, 6.0, 3, SM2.Grade.Again)
        assertEquals(0, next.reps)
        assertEquals(10.0 / 1440, next.interval, 1e-9)
    }

    @Test
    fun goodReviewsSpreadOut() {
        val first = SM2.next(2.5, 0.0, 0, SM2.Grade.Good)
        val second = SM2.next(first.ease, first.interval, first.reps, SM2.Grade.Good)
        val third = SM2.next(second.ease, second.interval, second.reps, SM2.Grade.Good)
        assertEquals(1.0, first.interval, 1e-9)
        assertEquals(6.0, second.interval, 1e-9)
        assertTrue(third.interval > 6.0)
    }

    @Test
    fun easeNeverFallsBelowItsFloor() = assertEquals(1.3, SM2.next(1.3, 1.0, 1, SM2.Grade.Again).ease, 1e-9)

    @Test
    fun reasoningIsHidden() {
        assertEquals("", TextTools.visibleAnswer("<think>still going"))
        assertEquals("Answer", TextTools.visibleAnswer("<think>hmm</think>\n Answer "))
    }

    @Test
    fun aCutOffLastLineGoes() = assertEquals("One.", TextTools.withoutCutOffLine("One.\nTwo and th"))

    @Test
    fun optionLabelsComeOff() {
        assertEquals("Paris", TextTools.withoutOptionLabel("A. Paris"))
        assertEquals("Paris", TextTools.withoutOptionLabel("Paris"))
    }

    @Test
    fun chunksKeepAllTheText() {
        val text = (1..5000).joinToString(" ") { "word$it" }
        val parts = TextTools.chunks(text, 1000)
        assertTrue(parts.all { it.length <= 1000 })
        assertEquals(text.replace(" ", ""), parts.joinToString("").replace(" ", ""))
    }

    @Test
    fun passagesAskedAboutComeFirst() {
        val passages = listOf(1 to "Mitochondria make energy.", 2 to "The French Revolution began in 1789.")
        val picked = TextTools.relevantPassages(passages, "When did the revolution begin?", 60)
        assertTrue(picked.startsWith("Page 2:"))
    }

    @Test
    fun oldNotesStillLoad() {
        val note = MarginJson.decodeFromString(Note.serializer(), """{"id":"a","title":"Old","pages":[{"id":"p","style":"someFutureStyle"}],"somethingNew":1}""")
        assertEquals("Old", note.title)
        assertEquals(PaperStyle.ruled, note.pages[0].style)
    }

    @Test
    fun inkSurvivesSaving() {
        val ink = NoteInk(listOf(Stroke(pageId = "p", tool = "pen", colorHex = "000000", width = 2f, points = floatArrayOf(1f, 2f, 3f))))
        val back = MarginJson.decodeFromString(NoteInk.serializer(), MarginJson.encodeToString(NoteInk.serializer(), ink))
        assertEquals(1, back.strokes[0].count)
        assertEquals(2f, back.strokes[0].points[1], 0f)
    }

    @Test
    fun shapesAreRecognized() {
        val circle = (0..40).map { val t = it / 40.0 * 2 * PI; Point(200 + 100 * kotlin.math.cos(t).toFloat(), 200 + 100 * kotlin.math.sin(t).toFloat()) }
        assertTrue(ShapeSnap.recognize(circle)!!.size == 49)
        assertTrue(ShapeSnap.recognize(listOf(Point(0f, 0f), Point(50f, 1f), Point(100f, 0f))) != null)
        val box = listOf(0f to 0f, 100f to 0f, 100f to 100f, 0f to 100f, 0f to 0f).zipWithNext { a, b -> (0..10).map { i -> Point(a.first + (b.first - a.first) * i / 10, a.second + (b.second - a.second) * i / 10) } }.flatten()
        assertEquals(28, ShapeSnap.recognize(box)!!.size)
    }

    @Test
    fun aScribbleIsNotAWord() {
        assertTrue(Scribble.isScribble((0..24).map { Point(if (it % 2 == 0) 0f else 100f, it * 0.5f) }))
        assertTrue(!Scribble.isScribble((0..24).map { Point(it * 10f, 0f) }))
        assertTrue(!Scribble.isScribble((0..40).map { val t = it / 40.0 * 2 * PI; Point(100 * kotlin.math.cos(t).toFloat(), 100 * kotlin.math.sin(t).toFloat()) }))
    }
}
