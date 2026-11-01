package com.warriorbiswas.margin

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.widget.OverScroller
import java.util.concurrent.Executors
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

enum class InkTool { Pen, Highlighter, Eraser, Lasso, Text, Listen }

/**
 * Every page of a note in one view, so ink stays fast at any zoom: a page is a cached bitmap
 * and only the stroke being written is drawn fresh on each frame.
 * A stylus writes and a finger scrolls, unless finger drawing is on, when two fingers scroll.
 */
@SuppressLint("ViewConstructor")
class InkCanvasView(context: Context) : View(context) {
    interface Listener {
        fun onContentChanged()
        fun onHistoryChanged(canUndo: Boolean, canRedo: Boolean)
        fun onPageVisible(index: Int)
        fun onTextTap(pageId: String, x: Float, y: Float, existing: Element?)
        fun onStrokeTap(stroke: Stroke)
        fun onSelectionChanged(hasSelection: Boolean)
        fun onToolFinished(tool: InkTool)
        fun onStylusFirstSeen()
        fun onZoomChanged(percent: Int)
    }

    var listener: Listener? = null
    var tool = InkTool.Pen
        set(value) {
            if (field != value) clearSelection()
            field = value
        }
    var inkColor = "1C1C1E"
    var penWidth = 2.5f
    var highlighterWidth = 22f
    var eraserRadius = 14f
    var fingerDraws = true
    var tiltEnabled = false
    var scratchToErase = true
    var holdForShapes = true
    var tiltStrength = 0.6

    lateinit var note: Note
        private set
    private var strokes = HashMap<String, List<Stroke>>()
    private var pdf: PdfSource? = null

    private class Snapshot(val pageId: String, val strokes: List<Stroke>, val elements: List<Element>)
    private class Change(val before: Snapshot, val after: Snapshot)
    private val undoStack = ArrayDeque<Change>()
    private val redoStack = ArrayDeque<Change>()

    // Layout, in the note's points. The scale fits a page to the width, and zoom multiplies it.
    private var pageTops = FloatArray(0)
    private var contentHeight = 0f
    private var zoom = 1f
    private var tx = 0f
    private var ty = 0f
    private val fitMargin = 12f * resources.displayMetrics.density
    private val fitScale: Float get() = max(1f, width - 2 * fitMargin) / NoteLayout.WIDTH
    private val scale: Float get() = fitScale * zoom

    // Rendered pages. The newest few are kept; the rest are drawn again when they scroll back.
    private class Cached(val bitmap: Bitmap, val renderScale: Float, val generation: Int)
    private val cache = object : LinkedHashMap<String, Cached>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Cached>?) = size > 6
    }
    private val generations = HashMap<String, Int>()
    private val rendering = HashSet<String>()
    private val renderThread = Executors.newSingleThreadExecutor()
    private val maxBitmapPixels = 16_000_000f

    // Input.
    private enum class Mode { None, Ink, Erase, Lasso, MoveSelection, Navigate, Tap }
    private var mode = Mode.None
    private var activePointer = -1
    private var activeIsStylus = false
    private var activePage = -1
    private var livePoints = FloatArray(1024)
    private var liveCount = 0
    private var liveTool = "pen"
    private var liveWidth = 2.5f
    private var liveColor = 0
    private var strokeStart = 0L
    private var stillSince = 0L
    private var stillX = 0f
    private var stillY = 0f
    private var erasedBefore: Snapshot? = null
    private var temporaryEraser = false
    private val pressureVaries = HashSet<Int>()
    private val tiltVaries = HashSet<Int>()
    private var stylusAnnounced = false

    private var navX = 0f
    private var navY = 0f
    private var navSpan = 0f
    private var navCount = 0
    private var tapX = 0f
    private var tapY = 0f
    private var velocity: VelocityTracker? = null
    private val scroller = OverScroller(context)
    private val slop = ViewConfiguration.get(context).scaledTouchSlop.toFloat()
    private var lastVisiblePage = -1

    // Selection.
    private val lassoPath = Path()
    private val lassoPoints = ArrayList<Float>()
    private var selectedStrokes: Set<String> = emptySet()
    private var selectedElements: Set<String> = emptySet()
    private var selectionPage = -1
    private var selectionBounds = RectF()
    private var moveDx = 0f
    private var moveDy = 0f

    private val bitmapPaint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val paperPaint = Paint()
    private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(38, 0, 0, 0) }
    private val selectionPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(200, 50, 47)
        style = Paint.Style.STROKE
        strokeWidth = 1.5f
        pathEffect = DashPathEffect(floatArrayOf(8f, 6f), 0f)
    }
    private val inkPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val eraserPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(120, 120, 120, 120)
        style = Paint.Style.STROKE
        strokeWidth = 1f
    }
    private var eraserX = -1f
    private var eraserY = -1f

    init {
        isFocusable = true
        setBackgroundColor(Color.rgb(226, 226, 230))
    }

    fun setContent(note: Note, ink: NoteInk, pdf: PdfSource?) {
        this.note = note
        this.pdf = pdf
        strokes = HashMap(ink.strokes.groupBy { it.pageId })
        undoStack.clear()
        redoStack.clear()
        cache.clear()
        layoutPages()
        notifyHistory()
        invalidate()
    }

    fun currentInk(): NoteInk = NoteInk(note.pages.flatMap { strokes[it.id].orEmpty() })
    fun strokesOn(pageId: String): List<Stroke> = strokes[pageId].orEmpty()
    fun hasSelection(): Boolean = selectedStrokes.isNotEmpty() || selectedElements.isNotEmpty()
    fun replaceRecordings(recordings: List<Recording>) {
        note = note.copy(recordings = recordings)
        listener?.onContentChanged()
    }

    fun updateNote(change: (Note) -> Note) {
        note = change(note)
    }

    private fun layoutPages() {
        pageTops = FloatArray(note.pages.size)
        var y = 0f
        note.pages.forEachIndexed { index, page ->
            pageTops[index] = y
            y += page.height + NoteLayout.GAP
        }
        contentHeight = max(0f, y - NoteLayout.GAP)
        clampPosition()
    }

    private fun clampPosition() {
        val s = scale
        val contentW = NoteLayout.WIDTH * s
        val contentH = contentHeight * s
        val pad = fitMargin
        tx = if (contentW + 2 * pad <= width) (width - contentW) / 2 else tx.coerceIn(width - contentW - pad, pad)
        val lowest = min(pad, height - contentH - 96 * resources.displayMetrics.density)
        ty = ty.coerceIn(lowest, pad)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (::note.isInitialized) {
            // Keep the same part of the page in view when the screen turns.
            if (oldh > 0) ty = ty * (w.toFloat() / max(1, oldw))
            layoutPages()
        }
    }

    private fun docX(screenX: Float) = (screenX - tx) / scale
    private fun docY(screenY: Float) = (screenY - ty) / scale

    private fun pageAt(doc: Float): Int {
        for (i in note.pages.indices.reversed()) if (doc >= pageTops[i] - NoteLayout.GAP / 2) return i
        return 0
    }

    private fun bump(pageId: String) {
        generations[pageId] = (generations[pageId] ?: 0) + 1
    }

    private fun wantedRenderScale(page: Page): Float {
        val limit = sqrt(maxBitmapPixels / (NoteLayout.WIDTH * page.height))
        return min(scale, limit)
    }

    private fun requestRender(page: Page) {
        if (renderThread.isShutdown || !rendering.add(page.id)) return
        val generation = generations[page.id] ?: 0
        val pageStrokes = strokes[page.id].orEmpty()
        val elements = note.elements.filter { it.pageId == page.id }
        val renderScale = wantedRenderScale(page)
        val folder = Library.dir(note.id)
        val source = pdf
        renderThread.execute {
            val bitmap = runCatching {
                val w = (NoteLayout.WIDTH * renderScale).toInt().coerceAtLeast(1)
                val h = (page.height * renderScale).toInt().coerceAtLeast(1)
                Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).also {
                    PageRenderer.render(Canvas(it), page, pageStrokes, elements, source, renderScale, folder)
                }
            }.getOrNull()
            post {
                rendering.remove(page.id)
                if (bitmap != null) cache[page.id] = Cached(bitmap, renderScale, generation)
                invalidate()
            }
        }
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (!::note.isInitialized || pageTops.isEmpty()) return
        val s = scale
        var firstVisible = -1
        val settled = mode != Mode.Navigate && scroller.isFinished
        note.pages.forEachIndexed { index, page ->
            val top = ty + pageTops[index] * s
            val bottom = top + page.height * s
            if (bottom < 0 || top > height) return@forEachIndexed
            if (firstVisible < 0 || (top <= height / 2f && bottom >= height / 2f)) firstVisible = index
            val rect = RectF(tx, top, tx + NoteLayout.WIDTH * s, bottom)
            canvas.drawRect(rect.left - 1, rect.top - 1, rect.right + 2, rect.bottom + 3, shadowPaint)
            val cached = cache[page.id]
            if (cached != null) {
                canvas.drawBitmap(cached.bitmap, null, rect, bitmapPaint)
                val stale = cached.generation != (generations[page.id] ?: 0)
                val blurry = abs(cached.renderScale - wantedRenderScale(page)) / wantedRenderScale(page) > 0.15f
                if (settled && (stale || blurry)) requestRender(page)
            } else {
                paperPaint.color = page.color.fill
                canvas.drawRect(rect, paperPaint)
                requestRender(page)
            }
            canvas.save()
            canvas.translate(tx, top)
            canvas.scale(s, s)
            canvas.clipRect(0f, 0f, NoteLayout.WIDTH, page.height)
            drawOverlay(canvas, index)
            canvas.restore()
        }
        if (firstVisible != lastVisiblePage && firstVisible >= 0) {
            lastVisiblePage = firstVisible
            post { listener?.onPageVisible(firstVisible) }
        }
    }

    private fun drawOverlay(canvas: Canvas, index: Int) {
        if (mode == Mode.Ink && index == activePage) {
            StrokePainter.draw(canvas, livePoints, liveCount, liveTool, liveColor, liveWidth, inkPaint)
        }
        if (mode == Mode.Lasso && index == activePage) canvas.drawPath(lassoPath, selectionPaint)
        if (mode == Mode.Erase && index == activePage && eraserX >= 0) canvas.drawCircle(eraserX, eraserY, eraserRadius, eraserPaint)
        if (hasSelection() && index == selectionPage) {
            canvas.save()
            canvas.translate(moveDx, moveDy)
            if (mode == Mode.MoveSelection) {
                // A copy follows the pointer until it lands, when the page is drawn again.
                strokes[note.pages[index].id].orEmpty().filter { it.id in selectedStrokes }.forEach { StrokePainter.draw(canvas, it, inkPaint) }
            }
            canvas.drawRect(selectionBounds, selectionPaint)
            canvas.restore()
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!::note.isInitialized) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> down(event)
            MotionEvent.ACTION_POINTER_DOWN -> pointerDown(event)
            MotionEvent.ACTION_MOVE -> move(event)
            MotionEvent.ACTION_POINTER_UP -> pointerUp(event)
            MotionEvent.ACTION_UP -> up(event)
            MotionEvent.ACTION_CANCEL -> cancel()
        }
        return true
    }

    private fun isStylus(event: MotionEvent, index: Int): Boolean {
        val type = event.getToolType(index)
        return type == MotionEvent.TOOL_TYPE_STYLUS || type == MotionEvent.TOOL_TYPE_ERASER
    }

    private fun down(event: MotionEvent) {
        scroller.forceFinished(true)
        startPointer(event, 0)
    }

    private fun startPointer(event: MotionEvent, index: Int) {
        activePointer = event.getPointerId(index)
        activeIsStylus = isStylus(event, index)
        if (activeIsStylus) {
            requestUnbufferedDispatch(event)
            if (!stylusAnnounced) {
                stylusAnnounced = true
                listener?.onStylusFirstSeen()
            }
        }
        if (activeIsStylus || fingerDraws) beginTool(event, index) else beginNavigate(event)
    }

    private fun beginTool(event: MotionEvent, index: Int) {
        val x = docX(event.getX(index))
        val doc = docY(event.getY(index))
        activePage = pageAt(doc).coerceIn(note.pages.indices)
        val y = doc - pageTops[activePage]
        val invertedEnd = event.getToolType(index) == MotionEvent.TOOL_TYPE_ERASER
        val sideButton = event.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY != 0
        temporaryEraser = invertedEnd || sideButton
        val effective = if (temporaryEraser) InkTool.Eraser else tool
        when (effective) {
            InkTool.Pen, InkTool.Highlighter -> {
                clearSelection()
                mode = Mode.Ink
                liveTool = if (effective == InkTool.Pen) "pen" else "highlighter"
                liveWidth = if (effective == InkTool.Pen) penWidth else highlighterWidth
                liveColor = colorOf(inkColor)
                liveCount = 0
                strokeStart = System.currentTimeMillis()
                addSample(event, -1, index)
            }
            InkTool.Eraser -> {
                clearSelection()
                mode = Mode.Erase
                erasedBefore = snapshot(note.pages[activePage].id)
                eraseAt(x, y)
            }
            InkTool.Lasso -> {
                if (hasSelection() && selectionPage == activePage && selectionBounds.contains(x, y)) {
                    mode = Mode.MoveSelection
                    tapX = x
                    tapY = y
                    moveDx = 0f
                    moveDy = 0f
                } else {
                    clearSelection()
                    mode = Mode.Lasso
                    lassoPoints.clear()
                    lassoPoints += x
                    lassoPoints += y
                    lassoPath.reset()
                    lassoPath.moveTo(x, y)
                }
            }
            InkTool.Text, InkTool.Listen -> {
                mode = Mode.Tap
                tapX = event.getX(index)
                tapY = event.getY(index)
            }
        }
        invalidate()
    }

    private fun pointerDown(event: MotionEvent) {
        // A hand usually lands before the stylus does. Whatever the palm started gives way to the stylus.
        if (!activeIsStylus && isStylus(event, event.actionIndex)) {
            if (mode == Mode.Navigate) {
                velocity?.recycle()
                velocity = null
                mode = Mode.None
            } else {
                abandonTool()
            }
            startPointer(event, event.actionIndex)
            invalidate()
            return
        }
        when (mode) {
            Mode.Navigate -> beginNavigate(event)
            // A second finger straight after the first means they meant to scroll, not write.
            Mode.Ink, Mode.Erase, Mode.Lasso, Mode.Tap -> if (!activeIsStylus) {
                abandonTool()
                beginNavigate(event)
            }
            else -> Unit
        }
    }

    private fun move(event: MotionEvent) {
        val index = event.findPointerIndex(activePointer)
        when (mode) {
            Mode.Ink -> {
                if (index < 0) return
                for (h in 0 until event.historySize) addSample(event, h, index)
                addSample(event, -1, index)
                invalidate()
            }
            Mode.Erase -> {
                if (index < 0) return
                for (h in 0 until event.historySize) eraseAt(docX(event.getHistoricalX(index, h)), docY(event.getHistoricalY(index, h)) - pageTops[activePage])
                eraseAt(docX(event.getX(index)), docY(event.getY(index)) - pageTops[activePage])
                invalidate()
            }
            Mode.Lasso -> {
                if (index < 0) return
                val x = docX(event.getX(index))
                val y = docY(event.getY(index)) - pageTops[activePage]
                lassoPoints += x
                lassoPoints += y
                lassoPath.lineTo(x, y)
                invalidate()
            }
            Mode.MoveSelection -> {
                if (index < 0) return
                moveDx = docX(event.getX(index)) - tapX
                moveDy = docY(event.getY(index)) - pageTops[activePage] - tapY
                invalidate()
            }
            Mode.Tap -> {
                if (index < 0) return
                if (hypot(event.getX(index) - tapX, event.getY(index) - tapY) > slop) beginNavigate(event)
            }
            Mode.Navigate -> navigate(event)
            Mode.None -> Unit
        }
    }

    private fun pointerUp(event: MotionEvent) {
        if (mode == Mode.Navigate) {
            // Measure again from the fingers that are left, skipping the one lifting now.
            measureNavigation(event, skip = event.actionIndex)
        } else if (event.getPointerId(event.actionIndex) == activePointer) {
            finishTool(event)
        }
    }

    private fun up(event: MotionEvent) {
        if (mode == Mode.Navigate) {
            velocity?.let { tracker ->
                tracker.addMovement(event)
                tracker.computeCurrentVelocity(1000)
                scroller.fling(tx.toInt(), ty.toInt(), tracker.xVelocity.toInt(), tracker.yVelocity.toInt(), Int.MIN_VALUE / 2, Int.MAX_VALUE / 2, Int.MIN_VALUE / 2, Int.MAX_VALUE / 2)
                tracker.recycle()
            }
            velocity = null
            mode = Mode.None
            postInvalidateOnAnimation()
            return
        }
        finishTool(event)
    }

    private fun cancel() {
        velocity?.recycle()
        velocity = null
        abandonTool()
    }

    /** The system cancels a touch it decides was a palm, so that ink never lands. */
    private fun abandonTool() {
        if (mode == Mode.Erase) {
            erasedBefore?.let { restore(it) }
            erasedBefore = null
        }
        mode = Mode.None
        liveCount = 0
        moveDx = 0f
        moveDy = 0f
        lassoPath.reset()
        invalidate()
    }

    private fun finishTool(event: MotionEvent) {
        when (mode) {
            Mode.Ink -> commitStroke()
            Mode.Erase -> {
                val before = erasedBefore
                erasedBefore = null
                val pageId = note.pages[activePage].id
                if (before != null && before.strokes.size != strokes[pageId].orEmpty().size) {
                    record(before, snapshot(pageId))
                    listener?.onContentChanged()
                }
                mode = Mode.None
                eraserX = -1f
                if (!temporaryEraser) listener?.onToolFinished(InkTool.Eraser)
            }
            Mode.Lasso -> finishLasso()
            Mode.MoveSelection -> finishMove()
            Mode.Tap -> {
                val x = docX(event.x)
                val doc = docY(event.y)
                val index = pageAt(doc).coerceIn(note.pages.indices)
                val page = note.pages[index]
                val y = doc - pageTops[index]
                mode = Mode.None
                if (tool == InkTool.Text) {
                    val hit = note.elements.lastOrNull { it.pageId == page.id && it.imageFile == null && x in it.x..(it.x + it.w) && y in it.y..(it.y + it.h) }
                    listener?.onTextTap(page.id, x, y, hit)
                } else {
                    nearestStroke(page.id, x, y)?.let { listener?.onStrokeTap(it) }
                }
            }
            else -> mode = Mode.None
        }
        invalidate()
    }

    private fun addSample(event: MotionEvent, history: Int, index: Int) {
        val rawX = if (history < 0) event.getX(index) else event.getHistoricalX(index, history)
        val rawY = if (history < 0) event.getY(index) else event.getHistoricalY(index, history)
        val x = docX(rawX)
        val y = docY(rawY) - pageTops[activePage]
        val width = if (liveTool == "highlighter") liveWidth else liveWidth * widthFactor(event, history, index)
        if (liveCount == 0 || hypot(x - stillX, y - stillY) > 3f) {
            stillX = x
            stillY = y
            stillSince = System.currentTimeMillis()
        }
        if (liveCount > 0) {
            // Samples closer than a tenth of a point only add weight to the saved note.
            val last = (liveCount - 1) * 3
            if (hypot(livePoints[last] - x, livePoints[last + 1] - y) < 0.1f) return
        }
        if ((liveCount + 1) * 3 > livePoints.size) livePoints = livePoints.copyOf(livePoints.size * 2)
        val at = liveCount * 3
        livePoints[at] = x
        livePoints[at + 1] = y
        livePoints[at + 2] = width
        liveCount++
    }

    private fun widthFactor(event: MotionEvent, history: Int, index: Int): Float {
        if (!activeIsStylus) return 1f
        val pressure = if (history < 0) event.getPressure(index) else event.getHistoricalPressure(index, history)
        // Some pens report a flat 0 or 1. Until a device shows real readings, its line stays even.
        val device = event.deviceId
        if (pressure > 0f && pressure < 1f) pressureVaries += device
        var factor = if (device in pressureVaries) 0.45f + 1.1f * pressure.coerceIn(0f, 1f).pow(0.8f) else 1f
        if (tiltEnabled) {
            val tilt = if (history < 0) event.getAxisValue(MotionEvent.AXIS_TILT, index) else event.getHistoricalAxisValue(MotionEvent.AXIS_TILT, index, history)
            // A stylus that can't sense tilt reads 0, which would look like one held bolt upright and thin every line.
            if (tilt != 0f) tiltVaries += device
            if (device in tiltVaries) factor *= TiltPressure.scale(PI / 2 - tilt, tiltStrength).toFloat()
        }
        return factor
    }

    private fun commitStroke() {
        mode = Mode.None
        if (liveCount == 0) return
        val page = note.pages[activePage]
        val raw = (0 until liveCount).map { Point(livePoints[it * 3], livePoints[it * 3 + 1]) }
        if (liveTool == "pen" && scratchToErase && Scribble.isScribble(raw) && eraseCovered(page.id, raw)) {
            liveCount = 0
            listener?.onContentChanged()
            return
        }
        val held = System.currentTimeMillis() - stillSince >= ShapeSnap.HOLD_MILLIS
        val snapped = if (liveTool == "pen" && holdForShapes && held) ShapeSnap.recognize(raw) else null
        val points = if (snapped != null) {
            FloatArray(snapped.size * 3) { i -> if (i % 3 == 0) snapped[i / 3].x else if (i % 3 == 1) snapped[i / 3].y else liveWidth }
        } else {
            rounded(livePoints, liveCount)
        }
        val stroke = Stroke(pageId = page.id, tool = liveTool, colorHex = inkColor, width = liveWidth, t = strokeStart, points = points)
        val before = snapshot(page.id)
        strokes[page.id] = strokes[page.id].orEmpty() + stroke
        record(before, snapshot(page.id))
        val cached = cache[page.id]
        if (cached != null) {
            // Painted straight into the page, which saves redrawing it and keeps it on screen without a flicker.
            val canvas = Canvas(cached.bitmap)
            canvas.scale(cached.renderScale, cached.renderScale)
            canvas.clipRect(0f, 0f, NoteLayout.WIDTH, page.height)
            StrokePainter.draw(canvas, stroke, inkPaint)
            // A redraw already under way started before this stroke, so it has to run again.
            if (page.id in rendering) bump(page.id)
        } else {
            bump(page.id)
        }
        liveCount = 0
        growIfEndless(stroke, activePage)
        listener?.onContentChanged()
    }

    /** An endless page gets another page's worth of room as the writing nears its bottom. */
    private fun growIfEndless(stroke: Stroke, index: Int) {
        val page = note.pages[index]
        if (!page.endless) return
        var lowest = 0f
        for (i in 0 until stroke.count) lowest = max(lowest, stroke.points[i * 3 + 1])
        if (lowest < page.height - 240f) return
        note = note.copy(pages = note.pages.map { if (it.id == page.id) it.copy(height = it.height + NoteLayout.PAPER_HEIGHT) else it })
        cache.remove(page.id)
        bump(page.id)
        layoutPages()
    }

    /** A word-sized stroke goes if the scratch touches it. A longer one goes only if a good part of it is covered, so scratching out a word leaves the underline beside it. */
    private fun eraseCovered(pageId: String, scratch: List<Point>): Boolean {
        val area = RectF(scratch.minOf { it.x }, scratch.minOf { it.y }, scratch.maxOf { it.x }, scratch.maxOf { it.y })
        // The scratch has width too, so ink right at its edge counts as covered.
        area.inset(-liveWidth, -liveWidth)
        val existing = strokes[pageId].orEmpty()
        val kept = existing.filterNot { stroke ->
            var inside = 0
            var left = Float.MAX_VALUE
            var top = Float.MAX_VALUE
            var right = -Float.MAX_VALUE
            var bottom = -Float.MAX_VALUE
            for (i in 0 until stroke.count) {
                val x = stroke.points[i * 3]
                val y = stroke.points[i * 3 + 1]
                if (area.contains(x, y)) inside++
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
            }
            val wordSized = max(right - left, bottom - top) <= max(max(area.width(), area.height()) * 3, 150f)
            val share = inside.toFloat() / stroke.count.coerceAtLeast(1)
            if (wordSized) share > 0f else share >= 0.5f
        }
        if (kept.size == existing.size) return false
        val before = snapshot(pageId)
        strokes[pageId] = kept
        bump(pageId)
        record(before, snapshot(pageId))
        return true
    }

    private fun rounded(points: FloatArray, count: Int): FloatArray {
        val result = FloatArray(count * 3)
        for (i in result.indices) result[i] = (points[i] * 100).toInt() / 100f
        return result
    }

    private fun eraseAt(x: Float, y: Float) {
        eraserX = x
        eraserY = y
        val pageId = note.pages[activePage].id
        val existing = strokes[pageId].orEmpty()
        val radius = eraserRadius
        val kept = existing.filterNot { touches(it, x, y, radius) }
        if (kept.size != existing.size) {
            strokes[pageId] = kept
            bump(pageId)
        }
    }

    private fun touches(stroke: Stroke, x: Float, y: Float, radius: Float): Boolean {
        val p = stroke.points
        var i = 0
        while (i < p.size) {
            val reach = radius + p[i + 2] / 2
            if (abs(p[i] - x) <= reach && abs(p[i + 1] - y) <= reach && hypot(p[i] - x, p[i + 1] - y) <= reach) return true
            i += 3
        }
        return false
    }

    private fun nearestStroke(pageId: String, x: Float, y: Float): Stroke? =
        strokes[pageId].orEmpty().lastOrNull { touches(it, x, y, 16f) }

    private fun finishLasso() {
        mode = Mode.None
        lassoPath.reset()
        if (lassoPoints.size < 6) return
        val pageId = note.pages[activePage].id
        val polygon = lassoPoints.toFloatArray()
        selectedStrokes = strokes[pageId].orEmpty().filter { stroke ->
            var inside = 0
            for (i in 0 until stroke.count) if (pointInPolygon(stroke.points[i * 3], stroke.points[i * 3 + 1], polygon)) inside++
            stroke.count > 0 && inside * 10 >= stroke.count * 6
        }.map { it.id }.toSet()
        selectedElements = note.elements.filter { it.pageId == pageId && pointInPolygon(it.x + it.w / 2, it.y + it.h / 2, polygon) }.map { it.id }.toSet()
        selectionPage = activePage
        if (hasSelection()) measureSelection(pageId)
        listener?.onSelectionChanged(hasSelection())
    }

    private fun pointInPolygon(x: Float, y: Float, polygon: FloatArray): Boolean {
        var inside = false
        var j = polygon.size - 2
        var i = 0
        while (i < polygon.size) {
            val xi = polygon[i]
            val yi = polygon[i + 1]
            val xj = polygon[j]
            val yj = polygon[j + 1]
            if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) inside = !inside
            j = i
            i += 2
        }
        return inside
    }

    private fun measureSelection(pageId: String) {
        var left = Float.MAX_VALUE
        var top = Float.MAX_VALUE
        var right = -Float.MAX_VALUE
        var bottom = -Float.MAX_VALUE
        strokes[pageId].orEmpty().filter { it.id in selectedStrokes }.forEach { stroke ->
            for (i in 0 until stroke.count) {
                val px = stroke.points[i * 3]
                val py = stroke.points[i * 3 + 1]
                left = min(left, px)
                right = max(right, px)
                top = min(top, py)
                bottom = max(bottom, py)
            }
        }
        note.elements.filter { it.id in selectedElements }.forEach {
            left = min(left, it.x)
            right = max(right, it.x + it.w)
            top = min(top, it.y)
            bottom = max(bottom, it.y + it.h)
        }
        selectionBounds = RectF(left - 8, top - 8, right + 8, bottom + 8)
    }

    private fun finishMove() {
        mode = Mode.None
        val dx = moveDx
        val dy = moveDy
        moveDx = 0f
        moveDy = 0f
        if (hypot(dx, dy) < 1f) return
        val pageId = note.pages[selectionPage].id
        val before = snapshot(pageId)
        strokes[pageId] = strokes[pageId].orEmpty().map { if (it.id in selectedStrokes) it.moved(dx, dy) else it }
        note = note.copy(elements = note.elements.map { if (it.id in selectedElements) it.copy(x = it.x + dx, y = it.y + dy) else it })
        bump(pageId)
        selectionBounds.offset(dx, dy)
        record(before, snapshot(pageId))
        listener?.onContentChanged()
    }

    fun clearSelection() {
        if (!hasSelection()) return
        selectedStrokes = emptySet()
        selectedElements = emptySet()
        selectionPage = -1
        listener?.onSelectionChanged(false)
        invalidate()
    }

    fun deleteSelection() {
        if (!hasSelection()) return
        val pageId = note.pages[selectionPage].id
        val before = snapshot(pageId)
        strokes[pageId] = strokes[pageId].orEmpty().filter { it.id !in selectedStrokes }
        note = note.copy(elements = note.elements.filter { it.id !in selectedElements })
        bump(pageId)
        record(before, snapshot(pageId))
        clearSelection()
        listener?.onContentChanged()
        invalidate()
    }

    private fun snapshot(pageId: String) = Snapshot(pageId, strokes[pageId].orEmpty(), note.elements.filter { it.pageId == pageId })

    private fun restore(snapshot: Snapshot) {
        strokes[snapshot.pageId] = snapshot.strokes
        note = note.copy(elements = note.elements.filter { it.pageId != snapshot.pageId } + snapshot.elements)
        bump(snapshot.pageId)
    }

    private fun record(before: Snapshot, after: Snapshot) {
        undoStack.addLast(Change(before, after))
        if (undoStack.size > 200) undoStack.removeFirst()
        redoStack.clear()
        notifyHistory()
    }

    private fun notifyHistory() = listener?.onHistoryChanged(undoStack.isNotEmpty(), redoStack.isNotEmpty())

    fun undo() {
        val change = undoStack.removeLastOrNull() ?: return
        clearSelection()
        restore(change.before)
        redoStack.addLast(change)
        notifyHistory()
        listener?.onContentChanged()
        invalidate()
    }

    fun redo() {
        val change = redoStack.removeLastOrNull() ?: return
        clearSelection()
        restore(change.after)
        undoStack.addLast(change)
        notifyHistory()
        listener?.onContentChanged()
        invalidate()
    }

    fun addElement(element: Element) = changingPage(element.pageId) { note = note.copy(elements = note.elements + element) }

    fun replaceElement(element: Element) = changingPage(element.pageId) {
        note = note.copy(elements = note.elements.map { if (it.id == element.id) element else it })
    }

    fun removeElement(element: Element) = changingPage(element.pageId) {
        note = note.copy(elements = note.elements.filter { it.id != element.id })
    }

    private fun changingPage(pageId: String, change: () -> Unit) {
        val before = snapshot(pageId)
        change()
        bump(pageId)
        record(before, snapshot(pageId))
        listener?.onContentChanged()
        invalidate()
    }

    /** Where a new box or picture goes: the middle of what's on screen, on the page showing there. */
    fun viewCenterOnPage(): Pair<String, Pair<Float, Float>> {
        val doc = docY(height / 2f)
        val index = pageAt(doc).coerceIn(note.pages.indices)
        return note.pages[index].id to (docX(width / 2f) to (doc - pageTops[index]).coerceIn(0f, note.pages[index].height))
    }

    fun insertPage(page: Page, after: Int) {
        val pages = note.pages.toMutableList()
        pages.add((after + 1).coerceIn(0, pages.size), page)
        note = note.copy(pages = pages)
        layoutPages()
        listener?.onContentChanged()
        invalidate()
    }

    /** A deleted page can't come back through undo, so the screen asks first. */
    fun removePage(index: Int) {
        if (note.pages.size <= 1 || index !in note.pages.indices) return
        val page = note.pages[index]
        clearSelection()
        strokes.remove(page.id)
        cache.remove(page.id)
        undoStack.removeAll { it.before.pageId == page.id }
        redoStack.removeAll { it.before.pageId == page.id }
        note = note.copy(pages = note.pages.filter { it.id != page.id }, elements = note.elements.filter { it.pageId != page.id })
        layoutPages()
        notifyHistory()
        listener?.onContentChanged()
        invalidate()
    }

    fun duplicatePage(index: Int) {
        val page = note.pages.getOrNull(index) ?: return
        val copy = page.copy(id = newId())
        strokes[copy.id] = strokes[page.id].orEmpty().map { Stroke(newId(), copy.id, it.tool, it.colorHex, it.width, it.t, it.points) }
        note = note.copy(elements = note.elements + note.elements.filter { it.pageId == page.id }.map { it.copy(id = newId(), pageId = copy.id) })
        insertPage(copy, index)
    }

    fun setZoomPercent(percent: Int) {
        val center = docY(height / 2f)
        zoom = (percent / 100f).coerceIn(1f, 6f)
        ty = height / 2f - center * scale
        tx = (width - NoteLayout.WIDTH * scale) / 2
        clampPosition()
        listener?.onZoomChanged(percent)
        invalidate()
    }

    fun scrollToPage(index: Int) {
        if (index !in pageTops.indices) return
        scroller.forceFinished(true)
        ty = fitMargin - pageTops[index] * scale
        clampPosition()
        invalidate()
    }

    private fun beginNavigate(event: MotionEvent) {
        if (mode != Mode.Navigate) {
            velocity?.recycle()
            velocity = VelocityTracker.obtain()
        }
        mode = Mode.Navigate
        measureNavigation(event, skip = -1)
        velocity?.addMovement(event)
    }

    private fun measureNavigation(event: MotionEvent, skip: Int) {
        var sumX = 0f
        var sumY = 0f
        var count = 0
        for (i in 0 until event.pointerCount) {
            if (i == skip) continue
            sumX += event.getX(i)
            sumY += event.getY(i)
            count++
        }
        if (count == 0) return
        navX = sumX / count
        navY = sumY / count
        var span = 0f
        for (i in 0 until event.pointerCount) {
            if (i == skip) continue
            span += hypot(event.getX(i) - navX, event.getY(i) - navY)
        }
        navSpan = span / count
        navCount = count
    }

    private fun navigate(event: MotionEvent) {
        velocity?.addMovement(event)
        val lastX = navX
        val lastY = navY
        val lastSpan = navSpan
        val lastCount = navCount
        measureNavigation(event, skip = -1)
        if (navCount != lastCount) return
        tx += navX - lastX
        ty += navY - lastY
        if (navCount >= 2 && lastSpan > 8f) {
            val oldScale = scale
            zoom = (zoom * navSpan / lastSpan).coerceIn(1f, 6f)
            listener?.onZoomChanged((zoom * 100).toInt())
            val ratio = scale / oldScale
            tx = navX - (navX - tx) * ratio
            ty = navY - (navY - ty) * ratio
        }
        clampPosition()
        invalidate()
    }

    override fun computeScroll() {
        if (scroller.computeScrollOffset()) {
            tx = scroller.currX.toFloat()
            ty = scroller.currY.toFloat()
            val beforeX = tx
            val beforeY = ty
            clampPosition()
            if (beforeX != tx && beforeY != ty) scroller.forceFinished(true)
            postInvalidateOnAnimation()
        } else if (mode == Mode.None) {
            // Fling over: let onDraw swap in a sharp page if zoom has changed.
            invalidate()
        }
    }

    /** Only for when the note closes. The view also leaves the window while the study tools are open, and comes back. */
    fun release() = renderThread.shutdown()
}
