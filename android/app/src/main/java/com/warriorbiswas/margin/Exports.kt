package com.warriorbiswas.margin

import android.content.Context
import android.content.Intent
import android.graphics.pdf.PdfDocument
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

object Exports {
    /** Everything readable in the note as plain text, page by page. */
    suspend fun shareText(context: Context, note: Note) {
        val file = withContext(Dispatchers.IO) {
            val folder = File(context.cacheDir, "exports").apply { mkdirs() }
            val safe = note.title.replace(Regex("[^\\p{L}\\p{N} ._-]"), "").trim().ifBlank { "Note" }
            File(folder, "$safe.txt").apply { writeText(note.title + "\n\n" + note.passages().joinToString("\n\n") { "Page ${it.first}\n${it.second}" }) }
        }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(send, "Share ${note.title}"))
    }

    /** Writes the note as a PDF with ink kept as vector lines, and opens the system's share sheet. */
    suspend fun sharePdf(context: Context, note: Note, ink: NoteInk, pdf: PdfSource?) {
        val file = withContext(Dispatchers.IO) {
            val folder = File(context.cacheDir, "exports").apply { mkdirs() }
            val safe = note.title.replace(Regex("[^\\p{L}\\p{N} ._-]"), "").trim().ifBlank { "Note" }
            val output = File(folder, "$safe.pdf")
            val document = PdfDocument()
            try {
                val byPage = ink.strokes.groupBy { it.pageId }
                note.pages.forEachIndexed { index, page ->
                    val info = PdfDocument.PageInfo.Builder(NoteLayout.WIDTH.toInt(), page.height.toInt(), index + 1).create()
                    val out = document.startPage(info)
                    PageRenderer.render(out.canvas, page, byPage[page.id].orEmpty(), note.elements.filter { it.pageId == page.id }, pdf, 1f, Library.dir(note.id))
                    document.finishPage(out)
                }
                output.outputStream().use { document.writeTo(it) }
            } finally {
                document.close()
            }
            output
        }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "application/pdf"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(send, "Share ${note.title}"))
    }
}
