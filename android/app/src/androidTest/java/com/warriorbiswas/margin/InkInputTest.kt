package com.warriorbiswas.margin

import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.PI

/** Real touch events through the real view, for the input a stylus can't send from a script. */
@RunWith(AndroidJUnit4::class)
class InkInputTest {
    private val leaning = (70 * PI / 180).toFloat() // 20 degrees off the page
    private val nearlyUpright = 0.0001f

    private fun onMain(work: () -> Unit) = InstrumentationRegistry.getInstrumentation().runOnMainSync(work)

    private fun canvas(tilt: Boolean = false, fingerDraws: Boolean = false): InkCanvasView {
        val view = InkCanvasView(InstrumentationRegistry.getInstrumentation().targetContext)
        view.measure(View.MeasureSpec.makeMeasureSpec(1536, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(2000, View.MeasureSpec.EXACTLY))
        view.layout(0, 0, 1536, 2000)
        view.fingerDraws = fingerDraws
        view.tiltEnabled = tilt
        view.tiltStrength = 1.0
        view.penWidth = 2f
        view.setContent(Note(), NoteInk(), null)
        return view
    }

    private fun event(action: Int, x: Float, y: Float, stylus: Boolean, pressure: Float, tilt: Float, down: Long): MotionEvent {
        val properties = MotionEvent.PointerProperties().apply {
            id = 0
            toolType = if (stylus) MotionEvent.TOOL_TYPE_STYLUS else MotionEvent.TOOL_TYPE_FINGER
        }
        val coords = MotionEvent.PointerCoords().apply {
            this.x = x
            this.y = y
            this.pressure = pressure
            size = 0.1f
            setAxisValue(MotionEvent.AXIS_TILT, tilt)
        }
        val source = if (stylus) InputDevice.SOURCE_STYLUS else InputDevice.SOURCE_TOUCHSCREEN
        return MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, 1, arrayOf(properties), arrayOf(coords), 0, 0, 1f, 1f, 0, 0, source, 0)
    }

    private fun line(view: InkCanvasView, stylus: Boolean = true, pressure: Float = 0.5f, tilt: Float = 0f, end: Int = MotionEvent.ACTION_UP) = onMain {
        val down = SystemClock.uptimeMillis()
        view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 200f, 300f, stylus, pressure, tilt, down))
        for (i in 1..6) view.dispatchTouchEvent(event(MotionEvent.ACTION_MOVE, 200f + i * 40, 300f, stylus, pressure, tilt, down))
        view.dispatchTouchEvent(event(end, 440f, 300f, stylus, pressure, tilt, down))
    }

    private fun widthOf(view: InkCanvasView, index: Int = 0): Float = view.currentInk().strokes[index].points[2]

    @Test
    fun stylusWrites() {
        val view = canvas()
        line(view)
        assertEquals(1, view.currentInk().strokes.size)
        assertTrue(view.currentInk().strokes[0].count >= 5)
    }

    @Test
    fun pressingHarderDrawsThicker() {
        val view = canvas()
        line(view, pressure = 0.2f)
        line(view, pressure = 0.9f)
        assertTrue(widthOf(view, 1) > widthOf(view, 0) * 1.5f)
    }

    @Test
    fun aPenWithFlatPressureDrawsEvenly() {
        val view = canvas()
        line(view, pressure = 1f)
        assertEquals(2f, widthOf(view), 0.01f)
    }

    @Test
    fun tiltForPressureThickensALeaningStylus() {
        val lean = canvas(tilt = true)
        line(lean, tilt = leaning)
        val upright = canvas(tilt = true)
        line(upright, tilt = nearlyUpright)
        assertEquals(9f, widthOf(lean) / widthOf(upright), 0.2f)
    }

    @Test
    fun tiltIsIgnoredWhenItsSwitchedOff() {
        val off = canvas(tilt = false)
        line(off, tilt = leaning)
        val still = canvas(tilt = false)
        line(still, tilt = nearlyUpright)
        assertEquals(widthOf(still), widthOf(off), 0.01f)
    }

    @Test
    fun aStylusThatCantSenseTiltIsLeftAlone() {
        val off = canvas(tilt = false)
        line(off)
        val on = canvas(tilt = true)
        line(on, tilt = 0f)
        assertEquals(widthOf(off), widthOf(on), 0.01f)
    }

    @Test
    fun aFingerScrollsInsteadOfWriting() {
        val view = canvas(fingerDraws = false)
        line(view, stylus = false)
        assertEquals(0, view.currentInk().strokes.size)
    }

    @Test
    fun aFingerWritesWhenItsAllowedTo() {
        val view = canvas(fingerDraws = true)
        line(view, stylus = false, pressure = 0.3f)
        assertEquals(2f, widthOf(view), 0.01f)
    }

    @Test
    fun aRejectedPalmLeavesNoInk() {
        val view = canvas(fingerDraws = true)
        line(view, stylus = false, end = MotionEvent.ACTION_CANCEL)
        assertEquals(0, view.currentInk().strokes.size)
    }

    @Test
    fun undoAndRedo() {
        val view = canvas()
        line(view)
        onMain { view.undo() }
        assertEquals(0, view.currentInk().strokes.size)
        onMain { view.redo() }
        assertEquals(1, view.currentInk().strokes.size)
    }

    @Test
    fun theEraserRemovesAStrokeAndUndoBringsItBack() {
        val view = canvas()
        line(view)
        view.tool = InkTool.Eraser
        line(view)
        assertEquals(0, view.currentInk().strokes.size)
        onMain { view.undo() }
        assertEquals(1, view.currentInk().strokes.size)
    }

    @Test
    fun aDeletedPageTakesItsInkWithIt() {
        val view = canvas()
        onMain { view.insertPage(Page(), 0) }
        line(view)
        assertEquals(1, view.currentInk().strokes.size)
        onMain { view.removePage(0) }
        assertEquals(0, view.currentInk().strokes.size)
        assertEquals(1, view.note.pages.size)
    }

    private fun path(view: InkCanvasView, points: List<Pair<Float, Float>>, holdMillis: Long = 0) {
        val down = SystemClock.uptimeMillis()
        onMain { view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, points[0].first, points[0].second, true, 0.5f, 0f, down)) }
        onMain { points.drop(1).forEach { view.dispatchTouchEvent(event(MotionEvent.ACTION_MOVE, it.first, it.second, true, 0.5f, 0f, down)) } }
        if (holdMillis > 0) Thread.sleep(holdMillis)
        val end = points.last()
        onMain { view.dispatchTouchEvent(event(MotionEvent.ACTION_UP, end.first, end.second, true, 0.5f, 0f, down)) }
    }

    @Test
    fun scratchingOutDeletesWhatsUnderIt() {
        val view = canvas()
        line(view)
        val scratch = (0..24).map { i -> (200f + (if (i % 2 == 0) 0f else 240f)) to 300f + i * 0.5f }
        path(view, scratch)
        assertEquals(0, view.currentInk().strokes.size)
        onMain { view.undo() }
        assertEquals(1, view.currentInk().strokes.size)
    }

    @Test
    fun holdingAtTheEndStraightensALine() {
        val view = canvas()
        val wobbly = (0..30).map { i -> (200f + i * 20) to 300f + (if (i % 2 == 0) 4f else -4f) }
        path(view, wobbly, holdMillis = 600)
        val points = view.currentInk().strokes.single().points
        val ys = (0 until points.size / 3).map { points[it * 3 + 1] }
        assertTrue(ys.max() - ys.min() < 12f)
        assertEquals(9, points.size / 3)
    }

    @Test
    fun aQuickWobblyLineStaysAsWritten() {
        val view = canvas()
        val wobbly = (0..30).map { i -> (200f + i * 20) to 300f + (if (i % 2 == 0) 4f else -4f) }
        path(view, wobbly)
        assertTrue(view.currentInk().strokes.single().count > 9)
    }

    @Test
    fun anEndlessPageGrowsNearItsBottom() {
        val view = canvas()
        val start = view.note.pages[0].height
        onMain { view.updateNote { it.copy(pages = it.pages.map { page -> page.copy(endless = true) }) } }
        onMain { view.setContent(view.note, NoteInk(), null) }
        val bottomY = 1900f
        path(view, listOf(200f to bottomY, 400f to bottomY))
        assertTrue(view.note.pages[0].height > start)
    }

    private fun twoPointers(action: Int, down: Long, stylusX: Float): MotionEvent {
        val palm = MotionEvent.PointerProperties().apply {
            id = 0
            toolType = MotionEvent.TOOL_TYPE_FINGER
        }
        val pen = MotionEvent.PointerProperties().apply {
            id = 1
            toolType = MotionEvent.TOOL_TYPE_STYLUS
        }
        val palmAt = MotionEvent.PointerCoords().apply {
            x = 900f
            y = 1500f
            pressure = 0.5f
            size = 0.1f
        }
        val penAt = MotionEvent.PointerCoords().apply {
            x = stylusX
            y = 300f
            pressure = 0.5f
            size = 0.1f
        }
        return MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, 2, arrayOf(palm, pen), arrayOf(palmAt, penAt), 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN or InputDevice.SOURCE_STYLUS, 0)
    }

    @Test
    fun aPalmLandingFirstDoesntStopTheStylusWriting() {
        for (fingerDraws in listOf(false, true)) {
            val view = canvas(fingerDraws = fingerDraws)
            onMain {
                val down = SystemClock.uptimeMillis()
                view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 900f, 1500f, false, 0.5f, 0f, down))
                val second = MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT)
                view.dispatchTouchEvent(twoPointers(second, down, 200f))
                for (i in 1..6) view.dispatchTouchEvent(twoPointers(MotionEvent.ACTION_MOVE, down, 200f + i * 40))
                val lift = MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT)
                view.dispatchTouchEvent(twoPointers(lift, down, 440f))
                view.dispatchTouchEvent(event(MotionEvent.ACTION_UP, 900f, 1500f, false, 0.5f, 0f, down))
            }
            val strokes = view.currentInk().strokes
            assertEquals(1, strokes.size)
            assertTrue(strokes[0].count >= 5)
        }
    }
}
