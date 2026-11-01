package com.warriorbiswas.margin

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.util.AtomicFile
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import java.io.File
import java.io.FileOutputStream

/** Every note is a folder: note.json, ink.json, source.pdf, recordings and pictures. */
object Library {
    private lateinit var appContext: Context
    private lateinit var root: File
    private lateinit var subjectsFile: File

    @OptIn(ExperimentalCoroutinesApi::class)
    private val writer = Dispatchers.IO.limitedParallelism(1)
    private val scope = CoroutineScope(SupervisorJob() + writer)

    private val _notes = MutableStateFlow<List<Note>>(emptyList())
    val notes: StateFlow<List<Note>> = _notes
    private val _subjects = MutableStateFlow<List<Subject>>(emptyList())
    val subjects: StateFlow<List<Subject>> = _subjects
    private val _tabs = MutableStateFlow<List<String>>(emptyList())
    val tabs: StateFlow<List<String>> = _tabs
    private val _thumbnails = MutableStateFlow(0)
    val thumbnails: StateFlow<Int> = _thumbnails // goes up when a note's picture is ready, which is just after it closes

    fun init(context: Context) {
        if (::appContext.isInitialized) return
        appContext = context.applicationContext
        root = File(appContext.filesDir, "notes").apply { mkdirs() }
        subjectsFile = File(appContext.filesDir, "subjects.json")
        PDFBoxResourceLoader.init(appContext)
        load()
    }

    private fun load() {
        // A file that can't be read is skipped, not fatal, so one bad note can't hide the rest.
        _notes.value = root.listFiles().orEmpty().mapNotNull { folder ->
            runCatching { MarginJson.decodeFromString<Note>(File(folder, "note.json").readText()) }.getOrNull()
        }.sortedByDescending { it.updatedAt }
        _subjects.value = runCatching { MarginJson.decodeFromString<List<Subject>>(subjectsFile.readText()) }.getOrDefault(emptyList())
        val known = _notes.value.filter { it.deletedAt == null }.map { it.id }.toSet()
        _tabs.value = Prefs.string(appContext, "tabs").split(",").filter { it in known }
    }

    fun dir(id: String): File = File(root, id).apply { mkdirs() }
    fun thumbFile(id: String): File = File(dir(id), "thumb.jpg")
    fun pdfFile(id: String): File = File(dir(id), "source.pdf")
    fun note(id: String): Note? = _notes.value.firstOrNull { it.id == id }

    fun loadInk(id: String): NoteInk {
        val file = File(dir(id), "ink.json")
        if (!file.exists()) return NoteInk()
        return runCatching { MarginJson.decodeFromString<NoteInk>(file.readText()) }.getOrDefault(NoteInk())
    }

    private fun atomicWrite(file: File, text: String) {
        val atomic = AtomicFile(file)
        val stream: FileOutputStream = atomic.startWrite()
        try {
            stream.write(text.toByteArray())
            atomic.finishWrite(stream)
        } catch (e: Exception) {
            atomic.failWrite(stream)
            throw e
        }
    }

    private fun publish(note: Note) {
        _notes.update { list -> (list.filter { it.id != note.id } + note).sortedByDescending { it.updatedAt } }
    }

    /** Shows the change at once and writes it behind the scenes, always in order. */
    fun save(note: Note, ink: NoteInk? = null) {
        publish(note)
        val noteJson = MarginJson.encodeToString(note)
        val inkJson = ink?.let { MarginJson.encodeToString(it) }
        scope.launch {
            atomicWrite(File(dir(note.id), "note.json"), noteJson)
            if (inkJson != null) atomicWrite(File(dir(note.id), "ink.json"), inkJson)
        }
    }

    private fun edit(id: String, change: (Note) -> Note) {
        val note = note(id) ?: return
        save(change(note))
    }

    fun rename(id: String, title: String) = edit(id) { it.copy(title = title, updatedAt = System.currentTimeMillis()) }
    fun toggleFavorite(id: String) = edit(id) { it.copy(favorite = !it.favorite) }
    fun move(id: String, subject: String?) = edit(id) { it.copy(subjectId = subject) }
    fun trash(id: String) {
        closeTab(id)
        edit(id) { it.copy(deletedAt = System.currentTimeMillis()) }
    }
    fun restore(id: String) = edit(id) { it.copy(deletedAt = null) }
    fun setCards(id: String, cards: List<Flashcard>) = edit(id) { it.copy(flashcards = cards) }

    fun setTags(id: String, tags: List<String>) = edit(id) { it.copy(tags = tags) }
    fun setCover(id: String, hex: String?) = edit(id) { it.copy(coverHex = hex) }
    fun setTemplate(id: String, on: Boolean) = edit(id) { it.copy(isTemplate = on) }
    fun setLocked(id: String, on: Boolean) = edit(id) { it.copy(locked = on) }
    fun allTags(): List<String> = _notes.value.filter { it.deletedAt == null }.flatMap { it.tags }.distinct().sorted()
    fun subfolders(parent: String?) = _subjects.value.filter { it.parentId == parent }.sortedBy { it.name.lowercase() }

    fun path(subject: Subject): String {
        val parent = _subjects.value.firstOrNull { it.id == subject.parentId } ?: return subject.name
        return path(parent) + " / " + subject.name
    }

    fun addTab(id: String) {
        if (id !in _tabs.value) _tabs.value = _tabs.value + id
        Prefs.set(appContext, "tabs", _tabs.value.joinToString(","))
    }

    fun closeTab(id: String) {
        _tabs.value = _tabs.value - id
        Prefs.set(appContext, "tabs", _tabs.value.joinToString(","))
    }

    fun deleteForever(id: String) {
        closeTab(id)
        _notes.update { list -> list.filter { it.id != id } }
        scope.launch { File(root, id).deleteRecursively() }
    }

    fun createNote(subject: String?, title: String? = null, page: Page = Prefs.newPage(appContext)): Note {
        val note = Note(title = title ?: "Untitled", subjectId = subject, pages = listOf(page))
        save(note)
        return note
    }

    fun duplicate(id: String): Note? {
        val source = note(id) ?: return null
        val copy = source.copy(id = newId(), title = if (source.isTemplate) source.title else "${source.title} Copy", isTemplate = false, flashcards = emptyList(), createdAt = System.currentTimeMillis(), updatedAt = System.currentTimeMillis())
        File(root, id).copyRecursively(File(root, copy.id), overwrite = true)
        save(copy)
        return copy
    }

    /** Copies the PDF in and gives each of its pages a page of the note, keeping its shape. */
    suspend fun importPdf(uri: Uri, subject: String?, name: String?): Note? = withContext(Dispatchers.IO) {
        val note = Note(title = name?.removeSuffix(".pdf")?.ifBlank { null } ?: "Imported PDF", subjectId = subject)
        val target = pdfFile(note.id)
        val ok = runCatching {
            appContext.contentResolver.openInputStream(uri)!!.use { input -> target.outputStream().use { input.copyTo(it) } }
        }.isSuccess
        if (!ok) {
            File(root, note.id).deleteRecursively()
            return@withContext null
        }
        val pages = PdfSource.pageShapes(target)?.mapIndexed { index, ratio ->
            Page(height = NoteLayout.WIDTH * ratio, style = PaperStyle.blank, pdfPage = index)
        }
        if (pages.isNullOrEmpty()) {
            File(root, note.id).deleteRecursively()
            return@withContext null
        }
        val text = readPdfText(target, pages)
        val imported = note.copy(pages = pages, printedText = text)
        save(imported)
        imported
    }

    private fun readPdfText(file: File, pages: List<Page>): Map<String, String> = runCatching {
        PDDocument.load(file).use { document ->
            val stripper = PDFTextStripper()
            pages.mapIndexedNotNull { index, page ->
                stripper.startPage = index + 1
                stripper.endPage = index + 1
                stripper.getText(document).trim().takeIf { it.isNotEmpty() }?.let { page.id to it }
            }.toMap()
        }
    }.getOrDefault(emptyMap())

    fun saveThumbnail(note: Note, ink: NoteInk, pdf: PdfSource?) {
        val page = note.pages.firstOrNull() ?: return
        scope.launch {
            runCatching {
                val scale = 360f / NoteLayout.WIDTH
                val bitmap = Bitmap.createBitmap(360, (minOf(page.height, NoteLayout.PAPER_HEIGHT * 1.3f) * scale).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
                PageRenderer.render(Canvas(bitmap), page, ink.strokes.filter { it.pageId == page.id }, note.elements.filter { it.pageId == page.id }, pdf, scale, dir(note.id))
                thumbFile(note.id).outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 82, it) }
                bitmap.recycle()
            }
            _thumbnails.update { it + 1 }
        }
    }

    private val folderColors = listOf("C8322F", "1F5FBF", "2E9E5B", "8E44AD", "E67E22", "2A9D9D", "6B7A90")

    fun addSubject(name: String, parent: String? = null) {
        _subjects.value = _subjects.value + Subject(name = name, parentId = parent, colorHex = folderColors[_subjects.value.size % folderColors.size])
        saveSubjects()
    }

    fun renameSubject(id: String, name: String) {
        _subjects.value = _subjects.value.map { if (it.id == id) it.copy(name = name) else it }
        saveSubjects()
    }

    /** Deleting a folder keeps its notes and subfolders, one level up. */
    fun deleteSubject(id: String) {
        val parent = _subjects.value.firstOrNull { it.id == id }?.parentId
        _subjects.value = _subjects.value.filter { it.id != id }.map { if (it.parentId == id) it.copy(parentId = parent) else it }
        saveSubjects()
        _notes.value.filter { it.subjectId == id }.forEach { save(it.copy(subjectId = parent)) }
    }

    private fun saveSubjects() {
        val json = MarginJson.encodeToString(_subjects.value)
        scope.launch { atomicWrite(subjectsFile, json) }
    }

    fun dueCards(): List<Pair<Note, Flashcard>> {
        val now = System.currentTimeMillis()
        return _notes.value.filter { it.deletedAt == null }.flatMap { note ->
            note.flashcards.filter { it.due <= now }.map { note to it }
        }
    }
}

object Prefs {
    private fun prefs(context: Context) = context.getSharedPreferences("margin", Context.MODE_PRIVATE)

    fun paperStyle(c: Context) = runCatching { PaperStyle.valueOf(prefs(c).getString("defaultPaper", "") ?: "") }.getOrDefault(PaperStyle.ruled)
    fun paperColor(c: Context) = runCatching { PaperColor.valueOf(prefs(c).getString("defaultColor", "") ?: "") }.getOrDefault(PaperColor.white)
    fun pageSize(c: Context) = runCatching { PageSize.valueOf(prefs(c).getString("defaultSize", "") ?: "") }.getOrDefault(PageSize.letter)
    fun tiltPressure(c: Context) = prefs(c).getBoolean("tiltPressure", false)
    fun tiltStrength(c: Context) = prefs(c).getFloat("tiltStrength", 0.6f)
    fun eraserReturns(c: Context) = prefs(c).getBoolean("eraserReturns", true)

    /** Finger drawing is on until a stylus first touches the screen, and after that a finger scrolls. */
    fun fingerDraws(c: Context) = prefs(c).getBoolean("fingerDraws", true)
    fun stylusSeen(c: Context) = prefs(c).getBoolean("stylusSeen", false)

    fun scribbleErase(c: Context) = prefs(c).getBoolean("scribbleErase", true)
    fun holdForShapes(c: Context) = prefs(c).getBoolean("holdForShapes", true)
    fun sort(c: Context) = prefs(c).getString("sort", "Date Edited") ?: "Date Edited"
    fun string(c: Context, key: String) = prefs(c).getString(key, "") ?: ""

    fun set(c: Context, key: String, value: Boolean) = prefs(c).edit().putBoolean(key, value).apply()
    fun set(c: Context, key: String, value: Float) = prefs(c).edit().putFloat(key, value).apply()
    fun set(c: Context, key: String, value: String) = prefs(c).edit().putString(key, value).apply()

    fun newPage(c: Context) = Page(height = pageSize(c).height, style = paperStyle(c), color = paperColor(c))
}
