package com.warriorbiswas.margin

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BlendMode
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import java.io.File
import kotlin.math.hypot

/** PdfRenderer can only open one page at a time, so every use takes the lock. */
class PdfSource(file: File) : AutoCloseable {
    private val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    private val renderer = PdfRenderer(descriptor)
    private val lock = Any()

    fun draw(canvas: Canvas, index: Int, width: Float, height: Float, scale: Float) {
        val pixelWidth = (width * scale).toInt().coerceAtLeast(1)
        val pixelHeight = (height * scale).toInt().coerceAtLeast(1)
        val bitmap = Bitmap.createBitmap(pixelWidth, pixelHeight, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.WHITE)
        synchronized(lock) {
            if (index !in 0 until renderer.pageCount) return
            renderer.openPage(index).use { it.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY) }
        }
        canvas.drawBitmap(bitmap, null, RectF(0f, 0f, width, height), Paint(Paint.FILTER_BITMAP_FLAG))
        bitmap.recycle()
    }

    override fun close() {
        synchronized(lock) {
            renderer.close()
            descriptor.close()
        }
    }

    companion object {
        /** Each page's height as a share of its width, or null if the file isn't a PDF that can be read. */
        fun pageShapes(file: File): List<Float>? = runCatching {
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                PdfRenderer(descriptor).use { renderer ->
                    (0 until renderer.pageCount).map { index ->
                        renderer.openPage(index).use { it.height.toFloat() / it.width.coerceAtLeast(1) }
                    }
                }
            }
        }.getOrNull()
    }
}

object StrokePainter {
    private val inkPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    /** Pens vary in width along the line, so they're short segments. Highlighters are even, and must not darken where segments overlap. */
    fun draw(canvas: Canvas, stroke: Stroke, paint: Paint = Paint(inkPaint)) {
        draw(canvas, stroke.points, stroke.count, stroke.tool, colorOf(stroke.colorHex), stroke.width, paint)
    }

    fun draw(canvas: Canvas, points: FloatArray, count: Int, tool: String, color: Int, width: Float, paint: Paint = Paint(inkPaint)) {
        if (count == 0) return
        if (tool == "highlighter") {
            paint.color = color
            paint.alpha = 96
            paint.strokeWidth = width
            paint.blendMode = BlendMode.MULTIPLY
            val path = Path()
            path.moveTo(points[0], points[1])
            if (count == 1) path.lineTo(points[0] + 0.1f, points[1])
            for (i in 1 until count) {
                val x = points[i * 3]
                val y = points[i * 3 + 1]
                val px = points[(i - 1) * 3]
                val py = points[(i - 1) * 3 + 1]
                path.quadTo(px, py, (px + x) / 2, (py + y) / 2)
                if (i == count - 1) path.lineTo(x, y)
            }
            canvas.drawPath(path, paint)
            return
        }
        paint.color = color
        paint.alpha = 255
        paint.blendMode = null
        if (count == 1) {
            paint.strokeWidth = points[2]
            canvas.drawPoint(points[0], points[1], paint)
            return
        }
        // Catmull-Rom through the points keeps fast curves round without moving the ink off where it was written.
        for (i in 0 until count - 1) {
            val a = (i - 1).coerceAtLeast(0) * 3
            val b = i * 3
            val c = (i + 1) * 3
            val d = (i + 2).coerceAtMost(count - 1) * 3
            val length = hypot(points[c] - points[b], points[c + 1] - points[b + 1])
            val steps = (length / 3f).toInt().coerceIn(1, 8)
            var lastX = points[b]
            var lastY = points[b + 1]
            for (s in 1..steps) {
                val t = s.toFloat() / steps
                val x = catmull(points[a], points[b], points[c], points[d], t)
                val y = catmull(points[a + 1], points[b + 1], points[c + 1], points[d + 1], t)
                paint.strokeWidth = points[b + 2] + (points[c + 2] - points[b + 2]) * t
                canvas.drawLine(lastX, lastY, x, y, paint)
                lastX = x
                lastY = y
            }
        }
    }

    private fun catmull(p0: Float, p1: Float, p2: Float, p3: Float, t: Float): Float {
        val t2 = t * t
        val t3 = t2 * t
        return 0.5f * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t3)
    }
}

object PageRenderer {
    /** Paints a whole page at `scale` pixels per point: paper or PDF, then typed boxes and pictures, then ink. */
    fun render(canvas: Canvas, page: Page, strokes: List<Stroke>, elements: List<Element>, pdf: PdfSource?, scale: Float, folder: File) {
        canvas.save()
        canvas.scale(scale, scale)
        canvas.clipRect(0f, 0f, NoteLayout.WIDTH, page.height)
        canvas.drawColor(page.color.fill)
        if (page.pdfPage != null && pdf != null) {
            pdf.draw(canvas, page.pdfPage, NoteLayout.WIDTH, page.height, scale)
        } else {
            Paper.draw(canvas, page.style, page.color, NoteLayout.WIDTH, page.height)
        }
        elements.forEach { drawElement(canvas, it, folder, scale) }
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }
        strokes.forEach { StrokePainter.draw(canvas, it, paint) }
        canvas.restore()
    }

    fun drawElement(canvas: Canvas, element: Element, folder: File, scale: Float) {
        val image = element.imageFile
        if (image != null) {
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            val file = File(folder, image)
            BitmapFactory.decodeFile(file.path, options)
            var sample = 1
            while (options.outWidth / (sample * 2) >= element.w * scale && options.outHeight / (sample * 2) >= element.h * scale) sample *= 2
            val bitmap = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return
            canvas.drawBitmap(bitmap, null, RectF(element.x, element.y, element.x + element.w, element.y + element.h), Paint(Paint.FILTER_BITMAP_FLAG))
            bitmap.recycle()
            return
        }
        val layout = layoutFor(element)
        val box = RectF(element.x, element.y, element.x + element.w, element.y + element.h)
        canvas.save()
        if (element.stamp) canvas.rotate(-4f, box.centerX(), box.centerY())
        element.fillHex?.let { fill ->
            canvas.drawRoundRect(box, 6f, 6f, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = colorOf(fill)
                setShadowLayer(6f, 0f, 2f, Color.argb(50, 0, 0, 0))
            })
        }
        if (element.stamp) {
            canvas.drawRoundRect(box, 6f, 6f, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = colorOf(element.colorHex)
                style = Paint.Style.STROKE
                strokeWidth = 2.5f
            })
        }
        canvas.translate(element.x + element.inset, element.y + element.inset)
        layout.draw(canvas)
        canvas.restore()
    }

    fun layoutFor(element: Element): StaticLayout {
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = colorOf(element.colorHex)
            textSize = element.fontSize
            isFakeBoldText = element.stamp
            letterSpacing = if (element.stamp) 0.08f else 0f
        }
        return StaticLayout.Builder.obtain(element.text, 0, element.text.length, paint, (element.w - 2 * element.inset).toInt().coerceAtLeast(40))
            .setAlignment(if (element.stamp) Layout.Alignment.ALIGN_CENTER else Layout.Alignment.ALIGN_NORMAL)
            .build()
    }
}

object Paper {
    fun draw(canvas: Canvas, style: PaperStyle, color: PaperColor, w: Float, h: Float) {
        val line = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = color.line
            strokeWidth = 1f
            this.style = Paint.Style.STROKE
        }
        val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = color.line
            this.style = Paint.Style.FILL
        }
        val red = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = Color.argb(115, 255, 59, 48)
            strokeWidth = 1f
            this.style = Paint.Style.STROKE
        }
        val label = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = color.label
            textSize = 13f
        }

        fun rules(step: Float, from: Float = step) {
            var y = from
            while (y < h) {
                canvas.drawLine(0f, y, w, y, line)
                y += step
            }
        }

        fun grid(step: Float, paint: Paint = line) {
            var x = step
            while (x < w) {
                canvas.drawLine(x, 0f, x, h, paint)
                x += step
            }
            var y = step
            while (y < h) {
                canvas.drawLine(0f, y, w, y, paint)
                y += step
            }
        }

        fun dots(step: Float, radius: Float) {
            var y = step
            while (y < h) {
                var x = step
                while (x < w) {
                    canvas.drawCircle(x, y, radius, dot)
                    x += step
                }
                y += step
            }
        }

        when (style) {
            PaperStyle.blank -> Unit
            PaperStyle.ruled -> rules(34f)
            PaperStyle.wide -> rules(44f)
            PaperStyle.narrow -> rules(24f)
            PaperStyle.legal -> {
                rules(34f)
                canvas.drawLine(84f, 0f, 84f, h, red)
                canvas.drawLine(89f, 0f, 89f, h, red)
            }
            PaperStyle.margin -> {
                rules(34f)
                canvas.drawLine(90f, 0f, 90f, h, red)
            }
            PaperStyle.gregg -> {
                rules(30f)
                canvas.drawLine(w / 2, 0f, w / 2, h, line)
            }
            PaperStyle.handwriting -> {
                val dashed = Paint(line).apply { pathEffect = DashPathEffect(floatArrayOf(6f, 5f), 0f) }
                var top = 60f
                while (top < h - 60) {
                    canvas.drawLine(28f, top, w - 28, top, line)
                    canvas.drawLine(28f, top + 48, w - 28, top + 48, line)
                    canvas.drawLine(28f, top + 24, w - 28, top + 24, dashed)
                    top += 84
                }
            }
            PaperStyle.grid -> grid(28f)
            PaperStyle.graphSmall -> grid(14f)
            PaperStyle.graphLarge -> grid(48f)
            PaperStyle.engineering -> {
                grid(14f)
                grid(70f, Paint(line).apply { strokeWidth = 1.6f })
            }
            PaperStyle.dots -> dots(28f, 1.25f)
            PaperStyle.dotsSmall -> dots(14f, 0.9f)
            PaperStyle.cornell -> {
                canvas.drawText("Title", 28f, 34f, label)
                canvas.drawLine(0f, 52f, w, 52f, line)
                canvas.drawLine(210f, 52f, 210f, h - 170, line)
                canvas.drawLine(0f, h - 170, w, h - 170, line)
                canvas.drawText("Cues", 20f, 76f, label)
                canvas.drawText("Notes", 226f, 76f, label)
                canvas.drawText("Summary", 20f, h - 146, label)
            }
            PaperStyle.todo -> {
                var y = 60f
                while (y < h - 36) {
                    canvas.drawRoundRect(RectF(36f, y - 24, 54f, y - 6), 3f, 3f, line)
                    canvas.drawLine(64f, y - 4, w - 36, y - 4, line)
                    y += 40
                }
            }
            PaperStyle.meeting -> {
                canvas.drawText("Meeting", 28f, 34f, label)
                canvas.drawLine(90f, 38f, 430f, 38f, line)
                canvas.drawText("Date", 460f, 34f, label)
                canvas.drawLine(498f, 38f, w - 28, 38f, line)
                canvas.drawText("People", 28f, 70f, label)
                canvas.drawLine(80f, 74f, w - 28, 74f, line)
                canvas.drawText("Notes", 28f, 112f, label)
                rules(34f, 130f)
            }
        }
    }
}
