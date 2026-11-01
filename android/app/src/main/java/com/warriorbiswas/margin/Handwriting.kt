package com.warriorbiswas.margin

import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.vision.digitalink.DigitalInkRecognition
import com.google.mlkit.vision.digitalink.DigitalInkRecognitionModel
import com.google.mlkit.vision.digitalink.DigitalInkRecognitionModelIdentifier
import com.google.mlkit.vision.digitalink.DigitalInkRecognizer
import com.google.mlkit.vision.digitalink.DigitalInkRecognizerOptions
import com.google.mlkit.vision.digitalink.Ink
import com.google.mlkit.vision.digitalink.RecognitionContext
import com.google.mlkit.vision.digitalink.WritingArea
import kotlinx.coroutines.tasks.await

/** Reads handwriting into text for search and the study tools. It runs on the device, after fetching Google's small recognition model once. */
object Handwriting {
    private var recognizer: DigitalInkRecognizer? = null

    private suspend fun ready(): DigitalInkRecognizer? {
        recognizer?.let { return it }
        return runCatching {
            val id = DigitalInkRecognitionModelIdentifier.fromLanguageTag("en-US")!!
            val model = DigitalInkRecognitionModel.builder(id).build()
            RemoteModelManager.getInstance().download(model, DownloadConditions.Builder().build()).await()
            DigitalInkRecognition.getClient(DigitalInkRecognizerOptions.builder(model).build()).also { recognizer = it }
        }.getOrNull()
    }

    private fun signature(strokes: List<Stroke>) = "${strokes.size}:${strokes.lastOrNull()?.id}"

    /** Reads only the pages that changed. If the model isn't available yet, the note simply keeps what it had. */
    suspend fun read(note: Note, ink: NoteInk): Note {
        val byPage = ink.strokes.filter { it.tool == "pen" }.groupBy { it.pageId }
        val changed = note.pages.filter { page ->
            val strokes = byPage[page.id].orEmpty()
            strokes.isNotEmpty() && note.inkSignatures[page.id] != signature(strokes)
        }
        if (changed.isEmpty()) return note
        val reader = ready() ?: return note
        val text = note.pageText.toMutableMap()
        val signatures = note.inkSignatures.toMutableMap()
        for (page in changed) {
            val strokes = byPage[page.id].orEmpty()
            val lines = lines(strokes).mapNotNull { line -> runCatching { readLine(reader, line) }.getOrNull() }.filter { it.isNotBlank() }
            text[page.id] = lines.joinToString("\n")
            signatures[page.id] = signature(strokes)
        }
        return note.copy(pageText = text, inkSignatures = signatures)
    }

    /** The recognizer reads one line at a time, so strokes are grouped by the height they were written at. */
    fun lines(strokes: List<Stroke>): List<List<Stroke>> {
        class Line(var top: Float, var bottom: Float, val strokes: MutableList<Stroke> = mutableListOf())
        val lines = mutableListOf<Line>()
        for (stroke in strokes.sortedBy { centerY(it) }) {
            var top = Float.MAX_VALUE
            var bottom = -Float.MAX_VALUE
            for (i in 0 until stroke.count) {
                top = minOf(top, stroke.points[i * 3 + 1])
                bottom = maxOf(bottom, stroke.points[i * 3 + 1])
            }
            val center = (top + bottom) / 2
            val line = lines.lastOrNull()
            if (line != null && center <= line.bottom + (line.bottom - line.top).coerceAtLeast(12f) * 0.25f) {
                line.strokes += stroke
                line.top = minOf(line.top, top)
                line.bottom = maxOf(line.bottom, bottom)
            } else {
                lines += Line(top, bottom, mutableListOf(stroke))
            }
        }
        // Back in writing order inside each line, which is what the recognizer expects.
        return lines.map { line -> line.strokes.sortedBy { it.t } }
    }

    private fun centerY(stroke: Stroke): Float {
        var sum = 0f
        for (i in 0 until stroke.count) sum += stroke.points[i * 3 + 1]
        return sum / stroke.count.coerceAtLeast(1)
    }

    private suspend fun readLine(reader: DigitalInkRecognizer, line: List<Stroke>): String? {
        val ink = Ink.builder()
        var time = 0L
        var height = 0f
        for (stroke in line) {
            val builder = Ink.Stroke.builder()
            for (i in 0 until stroke.count) {
                builder.addPoint(Ink.Point.create(stroke.points[i * 3], stroke.points[i * 3 + 1], time))
                time += 16
                height = maxOf(height, stroke.points[i * 3 + 1])
            }
            ink.addStroke(builder.build())
            time += 120
        }
        val context = RecognitionContext.builder().setPreContext("").setWritingArea(WritingArea(NoteLayout.WIDTH, height.coerceAtLeast(40f))).build()
        return reader.recognize(ink.build(), context).await().candidates.firstOrNull()?.text
    }
}
