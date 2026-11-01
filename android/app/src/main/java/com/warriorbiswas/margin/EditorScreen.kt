package com.warriorbiswas.margin

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Redo
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.CloseFullscreen
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.AddCircleOutline
import androidx.compose.material.icons.outlined.AutoFixNormal
import androidx.compose.material.icons.outlined.BorderColor
import androidx.compose.material.icons.outlined.Create
import androidx.compose.material.icons.outlined.Gesture
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Headphones
import androidx.compose.material.icons.outlined.School
import androidx.compose.material.icons.outlined.TextFields
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import java.io.File
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private val PenColors = listOf("1C1C1E", "C8322F", "1F5FBF", "2E9E5B", "8E44AD", "E67E22")
private val HighlighterColors = listOf("FFE14D", "7DE38B", "7CC8FF", "FF9ECF", "FFB86B")
private val PenSizes = listOf(1.5f, 2.5f, 4f, 7f)
private val HighlighterSizes = listOf(14f, 22f, 34f)
private val Stamps = listOf(
    "Approved" to "1E8E4E", "Reviewed" to "0A66D8", "Important" to "E5484D", "Draft" to "8E8E93",
    "Final" to "1E8E4E", "Confidential" to "E5484D", "Rejected" to "E5484D",
)

@Composable
fun EditorScreen(id: String, onClose: () -> Unit, onSwitch: (String) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val initial = remember(id) { Library.note(id) }
    if (initial == null) {
        LaunchedEffect(id) { onClose() }
        return
    }
    val pdf = remember(id) {
        Library.pdfFile(id).takeIf { it.exists() }?.let { runCatching { PdfSource(it) }.getOrNull() }
    }
    val canvas = remember(id) { InkCanvasView(context) }

    var tool by remember { mutableStateOf(InkTool.Pen) }
    var penColor by remember { mutableStateOf(PenColors[0]) }
    var highlightColor by remember { mutableStateOf(HighlighterColors[0]) }
    var penWidth by remember { mutableStateOf(2.5f) }
    var highlightWidth by remember { mutableStateOf(22f) }
    var canUndo by remember { mutableStateOf(false) }
    var canRedo by remember { mutableStateOf(false) }
    var hasSelection by remember { mutableStateOf(false) }
    var pageIndex by remember { mutableIntStateOf(0) }
    var pageCount by remember { mutableIntStateOf(initial.pages.size) }
    var zoomPercent by remember { mutableIntStateOf(100) }
    var inkRevision by remember { mutableIntStateOf(0) }
    var title by remember { mutableStateOf(initial.title) }
    var study by remember { mutableStateOf(false) }
    var focusMode by remember { mutableStateOf(false) }
    var pagesPanel by remember { mutableStateOf(false) }
    var pagePicker by remember { mutableStateOf(false) }
    var confirmPageDelete by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    var textEdit by remember { mutableStateOf<TextEdit?>(null) }
    var recordings by remember { mutableStateOf(initial.recordings) }
    var recordingPanel by remember { mutableStateOf(false) }
    var recorder by remember { mutableStateOf<ActiveRecording?>(null) }
    var recordingStart by remember { mutableLongStateOf(0L) }
    val player = remember { RecordingPlayer() }
    var saveJob by remember { mutableStateOf<Job?>(null) }
    var returnTool by remember { mutableStateOf<InkTool?>(null) }

    fun saveNow() {
        saveJob?.cancel()
        // The library screen and study tools can change these while the note is open, so they're never written back stale.
        val latest = Library.note(id)
        val note = canvas.note.copy(
            updatedAt = System.currentTimeMillis(),
            flashcards = latest?.flashcards ?: canvas.note.flashcards,
            favorite = latest?.favorite ?: canvas.note.favorite,
            subjectId = latest?.subjectId ?: canvas.note.subjectId,
            tags = latest?.tags ?: canvas.note.tags,
            coverHex = latest?.coverHex,
            locked = latest?.locked ?: canvas.note.locked,
            isTemplate = latest?.isTemplate ?: canvas.note.isTemplate,
        )
        canvas.updateNote { note }
        Library.save(note, canvas.currentInk())
    }

    fun saveSoon() {
        saveJob?.cancel()
        saveJob = scope.launch {
            delay(800)
            saveNow()
        }
    }

    fun select(next: InkTool) {
        // Erasing is usually a quick fix, so remember what to go back to.
        returnTool = if (next == InkTool.Eraser && tool != InkTool.Eraser) tool else null
        tool = next
        canvas.tool = next
        when (next) {
            InkTool.Pen -> canvas.inkColor = penColor
            InkTool.Highlighter -> canvas.inkColor = highlightColor
            else -> Unit
        }
    }

    fun stopRecording() {
        val active = recorder ?: return
        recorder = null
        val item = active.stop()
        if (item != null) {
            recordings = recordings + item
            canvas.replaceRecordings(recordings)
            saveSoon()
        } else {
            Toast.makeText(context, "That recording was too short to keep.", Toast.LENGTH_SHORT).show()
        }
    }

    fun startRecording() {
        recorder = ActiveRecording.start(Library.dir(id))
        recordingStart = System.currentTimeMillis()
        if (recorder == null) Toast.makeText(context, "The microphone couldn't start.", Toast.LENGTH_LONG).show()
    }

    fun leave() {
        stopRecording()
        player.stop()
        saveNow()
        Library.saveThumbnail(canvas.note, canvas.currentInk(), pdf)
    }

    /** Reads new handwriting first, so the study tools and exports see what was just written. */
    suspend fun readHandwriting() {
        val note = canvas.note
        val ink = canvas.currentInk()
        val read = withContext(Dispatchers.Default) { Handwriting.read(note, ink) }
        canvas.updateNote { it.copy(pageText = read.pageText, inkSignatures = read.inkSignatures) }
        saveNow()
    }

    fun openStudy() {
        saveNow()
        study = true
        scope.launch { readHandwriting() }
    }

    val micPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startRecording() else Toast.makeText(context, "Margin needs the microphone to record.", Toast.LENGTH_LONG).show()
    }

    val imagePicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri: Uri? ->
        if (uri != null) scope.launch {
            val added = withContext(Dispatchers.IO) { copyImage(context, uri, Library.dir(id)) }
            if (added == null) {
                Toast.makeText(context, "Margin couldn't open that picture.", Toast.LENGTH_LONG).show()
                return@launch
            }
            val (pageId, center) = canvas.viewCenterOnPage()
            val width = 360f
            val height = width * added.second
            val x = (center.first - width / 2).coerceIn(0f, NoteLayout.WIDTH - width)
            canvas.addElement(Element(pageId = pageId, x = x, y = (center.second - height / 2).coerceAtLeast(0f), w = width, h = height, imageFile = added.first))
        }
    }

    DisposableEffect(id) {
        canvas.listener = object : InkCanvasView.Listener {
            override fun onContentChanged() {
                pageCount = canvas.note.pages.size
                inkRevision++
                saveSoon()
            }
            override fun onHistoryChanged(canUndo2: Boolean, canRedo2: Boolean) {
                canUndo = canUndo2
                canRedo = canRedo2
            }
            override fun onPageVisible(index: Int) {
                pageIndex = index
            }
            override fun onTextTap(pageId: String, x: Float, y: Float, existing: Element?) {
                textEdit = TextEdit(pageId, x, y, existing)
            }
            override fun onStrokeTap(stroke: Stroke) {
                val found = recordings.firstOrNull { stroke.t >= it.startedAt && stroke.t <= it.startedAt + it.durationMs }
                if (found == null) {
                    Toast.makeText(context, "No recording was running when this was written.", Toast.LENGTH_SHORT).show()
                } else {
                    player.play(File(Library.dir(id), found.file), found.id, (stroke.t - found.startedAt).toInt())
                    recordingPanel = true
                }
            }
            override fun onSelectionChanged(hasSelection2: Boolean) {
                hasSelection = hasSelection2
            }
            override fun onToolFinished(tool: InkTool) {
                if (tool == InkTool.Eraser && Prefs.eraserReturns(context)) returnTool?.let { select(it) }
            }
            override fun onStylusFirstSeen() {
                if (!Prefs.stylusSeen(context)) {
                    Prefs.set(context, "stylusSeen", true)
                    Prefs.set(context, "fingerDraws", false)
                    canvas.fingerDraws = false
                    Toast.makeText(context, "Stylus found. Your finger now scrolls, and you can change that in Settings.", Toast.LENGTH_LONG).show()
                }
            }
            override fun onZoomChanged(percent: Int) {
                zoomPercent = percent
            }
        }
        canvas.fingerDraws = Prefs.fingerDraws(context)
        canvas.tiltEnabled = Prefs.tiltPressure(context)
        canvas.tiltStrength = Prefs.tiltStrength(context).toDouble()
        canvas.scratchToErase = Prefs.scribbleErase(context)
        canvas.holdForShapes = Prefs.holdForShapes(context)
        canvas.setContent(initial, Library.loadInk(id), pdf)
        canvas.inkColor = penColor
        canvas.penWidth = penWidth
        canvas.highlighterWidth = highlightWidth
        Library.addTab(id)
        onDispose {
            canvas.listener = null
            canvas.release()
            player.stop()
            pdfCloseLater(pdf)
        }
    }

    // Android stops the microphone for an app in the background, and a silent gap would be worse than a clean stop.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) {
                stopRecording()
                player.pause()
                saveNow()
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }

    BackHandler {
        when {
            study -> study = false
            focusMode -> focusMode = false
            else -> {
                leave()
                onClose()
            }
        }
    }

    if (study) {
        StudyScreen(id, onClose = { study = false })
        return
    }

    val stampItem: @Composable (String, String, () -> Unit) -> Unit = { label, hex, close ->
        DropdownMenuItem(text = { Text(label) }, leadingIcon = { Box(Modifier.size(12.dp).background(Color(colorOf(hex)), CircleShape)) }, onClick = {
            close()
            val (pageId, center) = canvas.viewCenterOnPage()
            canvas.addElement(Element(pageId = pageId, x = (center.first - 110f).coerceIn(0f, NoteLayout.WIDTH - 220f), y = center.second, w = 220f, h = 48f, text = label.uppercase(), fontSize = 20f, colorHex = hex, stamp = true))
        })
    }

    val tools: @Composable () -> Unit = {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            BarButton(Icons.Outlined.Create, "Pen", tool == InkTool.Pen) { select(InkTool.Pen) }
            BarButton(Icons.Outlined.BorderColor, "Highlighter", tool == InkTool.Highlighter) { select(InkTool.Highlighter) }
            BarButton(Icons.Outlined.AutoFixNormal, "Eraser", tool == InkTool.Eraser) { select(InkTool.Eraser) }
            BarButton(Icons.Outlined.Gesture, "Lasso", tool == InkTool.Lasso) { select(InkTool.Lasso) }
            BarDivider()
            BarButton(Icons.Outlined.TextFields, "Text", tool == InkTool.Text) { select(InkTool.Text) }
            if (recordings.isNotEmpty()) BarButton(Icons.Outlined.Headphones, "Tap ink to hear it", tool == InkTool.Listen) { select(InkTool.Listen) }
            BarDivider()
            var inserting by remember { mutableStateOf(false) }
            var stamps by remember { mutableStateOf(false) }
            Box {
                BarButton(Icons.Outlined.AddCircleOutline, "Insert") { inserting = true }
                DropdownMenu(expanded = inserting, onDismissRequest = {
                    inserting = false
                    stamps = false
                }) {
                    val close = {
                        inserting = false
                        stamps = false
                    }
                    if (stamps) {
                        Stamps.forEach { (label, hex) -> stampItem(label, hex, close) }
                        stampItem(DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date()), "0A66D8", close)
                    } else {
                        DropdownMenuItem(text = { Text("Photos") }, onClick = {
                            close()
                            imagePicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                        })
                        DropdownMenuItem(text = { Text("Sticky Note") }, onClick = {
                            close()
                            val (pageId, center) = canvas.viewCenterOnPage()
                            textEdit = TextEdit(pageId, (center.first - 120f).coerceIn(0f, NoteLayout.WIDTH - 240f), center.second, null, fillHex = "FFF2A8")
                        })
                        DropdownMenuItem(text = { Text("Stamp") }, onClick = { stamps = true })
                    }
                }
            }
        }
    }

    val titleControls: @Composable () -> Unit = {
        Row(verticalAlignment = Alignment.CenterVertically) {
            BarButton(Icons.Default.ChevronLeft, "Back to library") {
                leave()
                onClose()
            }
            Text(
                title,
                fontFamily = FontFamily.Serif,
                fontWeight = FontWeight.SemiBold,
                style = MaterialTheme.typography.titleMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.widthIn(min = 40.dp, max = 190.dp).clickable { renaming = true }.semantics { contentDescription = "Rename $title" },
            )
        }
    }

    val noteControls: @Composable () -> Unit = {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            var zooming by remember { mutableStateOf(false) }
            Box {
                Text(
                    "$zoomPercent%",
                    style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier.clip(RoundedCornerShape(10.dp)).clickable { zooming = true }.padding(horizontal = 10.dp, vertical = 12.dp).semantics { contentDescription = "Zoom $zoomPercent percent" },
                )
                DropdownMenu(expanded = zooming, onDismissRequest = { zooming = false }) {
                    DropdownMenuItem(text = { Text("Fit Page to Width") }, onClick = {
                        zooming = false
                        canvas.setZoomPercent(100)
                    })
                    listOf(125, 150, 200, 300).forEach { percent ->
                        DropdownMenuItem(text = { Text("$percent%") }, onClick = {
                            zooming = false
                            canvas.setZoomPercent(percent)
                        })
                    }
                }
            }
            BarButton(Icons.AutoMirrored.Filled.Undo, "Undo", enabled = canUndo) { canvas.undo() }
            BarButton(Icons.AutoMirrored.Filled.Redo, "Redo", enabled = canRedo) { canvas.redo() }
            if (recorder != null) {
                RecordingTimer(recordingStart) { stopRecording() }
            } else {
                BarButton(Icons.Default.Mic, "Record audio") {
                    if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) startRecording()
                    else micPermission.launch(Manifest.permission.RECORD_AUDIO)
                }
            }
            BarButton(Icons.Outlined.School, "Study") { openStudy() }
            BarButton(Icons.Outlined.GridView, "Pages", pagesPanel) { pagesPanel = !pagesPanel }
            var more by remember { mutableStateOf(false) }
            Box {
                BarButton(Icons.Default.MoreHoriz, "More") { more = true }
                DropdownMenu(expanded = more, onDismissRequest = { more = false }) {
                    DropdownMenuItem(text = { Text("Export PDF") }, onClick = {
                        more = false
                        saveNow()
                        val note = canvas.note
                        val ink = canvas.currentInk()
                        scope.launch { runCatching { Exports.sharePdf(context, note, ink, pdf) }.onFailure { Toast.makeText(context, "Margin couldn't make that PDF.", Toast.LENGTH_LONG).show() } }
                    })
                    DropdownMenuItem(text = { Text("Export Text") }, onClick = {
                        more = false
                        scope.launch {
                            readHandwriting()
                            runCatching { Exports.shareText(context, canvas.note) }
                        }
                    })
                    DropdownMenuItem(text = { Text("Add Page") }, onClick = {
                        more = false
                        pagePicker = true
                    })
                    DropdownMenuItem(text = { Text("Recordings") }, onClick = {
                        more = false
                        recordingPanel = !recordingPanel
                    })
                    DropdownMenuItem(text = { Text("Focus Mode") }, onClick = {
                        more = false
                        focusMode = true
                    })
                }
            }
        }
    }

    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface)) {
        if (!focusMode) {
            Surface(color = MaterialTheme.colorScheme.surfaceContainer) {
                Column(Modifier.statusBarsPadding()) {
                    TabStrip(id, onSwitch = {
                        leave()
                        onSwitch(it)
                    }, onCloseCurrent = {
                        leave()
                        onClose()
                    })
                    BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal = 6.dp, vertical = 4.dp)) {
                        // Upright, every tool can't share a row with the note's controls, and none of them should be hidden.
                        if (maxWidth >= 980.dp) {
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                titleControls()
                                Spacer(Modifier.weight(1f))
                                tools()
                                Spacer(Modifier.weight(1f))
                                noteControls()
                            }
                        } else {
                            Column {
                                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                    Box(Modifier.weight(1f)) { titleControls() }
                                    Box(Modifier.horizontalScroll(rememberScrollState())) { noteControls() }
                                }
                                Box(Modifier.horizontalScroll(rememberScrollState())) { tools() }
                            }
                        }
                    }
                    val showOptions = tool == InkTool.Pen || tool == InkTool.Highlighter || hasSelection || tool == InkTool.Text || tool == InkTool.Lasso || tool == InkTool.Listen
                    if (showOptions) {
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
                        Row(
                            Modifier.fillMaxWidth().height(48.dp).horizontalScroll(rememberScrollState()).padding(horizontal = 14.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            when {
                                hasSelection -> TextButton(onClick = { canvas.deleteSelection() }) { Text("Delete Selection", color = MaterialTheme.colorScheme.error) }
                                tool == InkTool.Pen -> {
                                    PenColors.forEach { hex ->
                                        ColorDot(hex, hex == penColor) {
                                            penColor = hex
                                            canvas.inkColor = hex
                                        }
                                    }
                                    BarDivider()
                                    PenSizes.forEach { size ->
                                        SizeDot(size * 1.6f, size == penWidth, penColor) {
                                            penWidth = size
                                            canvas.penWidth = size
                                        }
                                    }
                                }
                                tool == InkTool.Highlighter -> {
                                    HighlighterColors.forEach { hex ->
                                        ColorDot(hex, hex == highlightColor) {
                                            highlightColor = hex
                                            canvas.inkColor = hex
                                        }
                                    }
                                    BarDivider()
                                    HighlighterSizes.forEach { size ->
                                        SizeDot(size * 0.6f, size == highlightWidth, highlightColor) {
                                            highlightWidth = size
                                            canvas.highlighterWidth = size
                                        }
                                    }
                                }
                                tool == InkTool.Text -> Hint("Tap the page to add text, or tap a box to edit it.")
                                tool == InkTool.Lasso -> Hint("Circle ink or a box to select it, then drag to move.")
                                tool == InkTool.Listen -> Hint("Tap your notes to hear what was being said when you wrote them.")
                            }
                        }
                    }
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                }
            }
            if (recordingPanel) {
                RecordingsPanel(recordings, player, recorder != null, folder = Library.dir(id), onDelete = { item ->
                    player.stop()
                    recordings = recordings.filter { it.id != item.id }
                    canvas.replaceRecordings(recordings)
                    saveSoon()
                    File(Library.dir(id), item.file).delete()
                })
            }
        }
        Row(Modifier.weight(1f).fillMaxWidth()) {
            Box(Modifier.weight(1f).fillMaxHeight()) {
                AndroidView(factory = { canvas }, modifier = Modifier.fillMaxSize())
                if (focusMode) {
                    Surface(shape = CircleShape, shadowElevation = 4.dp, modifier = Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(12.dp)) {
                        BarButton(Icons.Default.CloseFullscreen, "Exit Focus Mode") { focusMode = false }
                    }
                }
                // Page position, out of the way of the writing.
                if (pageCount > 1 && !focusMode) {
                    Surface(shape = CircleShape, shadowElevation = 2.dp, color = MaterialTheme.colorScheme.surfaceContainer, modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 28.dp)) {
                        Text("${pageIndex + 1} of $pageCount", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(horizontal = 12.dp, vertical = 5.dp))
                    }
                }
            }
            if (pagesPanel && !focusMode) {
                VerticalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                PagesPanel(
                    canvas = canvas,
                    pageCount = pageCount,
                    revision = inkRevision,
                    current = pageIndex,
                    pdf = pdf,
                    folder = Library.dir(id),
                    onGo = { canvas.scrollToPage(it) },
                    onAdd = { pagePicker = true },
                    onDuplicate = { canvas.duplicatePage(pageIndex) },
                    onDelete = { confirmPageDelete = true },
                )
            }
        }
    }

    if (renaming) {
        NameDialog("Rename Note", title, "Rename", onDismiss = { renaming = false }) {
            title = it
            canvas.updateNote { note -> note.copy(title = it) }
            renaming = false
            saveSoon()
        }
    }
    if (pagePicker) {
        PagePickerDialog(onDismiss = { pagePicker = false }) { page ->
            pagePicker = false
            canvas.insertPage(page, pageIndex)
            canvas.scrollToPage(pageIndex + 1)
        }
    }
    if (confirmPageDelete) {
        AlertDialog(
            onDismissRequest = { confirmPageDelete = false },
            title = { Text("Delete Page ${pageIndex + 1}?") },
            text = { Text("Its ink and anything placed on it go too. This can't be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmPageDelete = false
                    if (canvas.note.pages.size <= 1) Toast.makeText(context, "A note needs at least one page.", Toast.LENGTH_SHORT).show()
                    else canvas.removePage(pageIndex)
                }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmPageDelete = false }) { Text("Cancel") } },
        )
    }
    textEdit?.let { edit ->
        var text by remember(edit) { mutableStateOf(edit.existing?.text.orEmpty()) }
        AlertDialog(
            onDismissRequest = { textEdit = null },
            title = {
                ResizeDialogForKeyboard()
                Text(if (edit.fillHex != null) "Sticky Note" else if (edit.existing == null) "Add Text" else "Edit Text")
            },
            text = { OutlinedTextField(text, { text = it }, minLines = 3, modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState())) },
            confirmButton = {
                TextButton(onClick = {
                    val existing = edit.existing
                    when {
                        existing != null && text.isBlank() -> canvas.removeElement(existing)
                        existing != null -> canvas.replaceElement(existing.copy(text = text, h = measuredHeight(existing.copy(text = text))))
                        text.isNotBlank() -> {
                            val w = if (edit.fillHex != null) 240f else (NoteLayout.WIDTH - edit.x - 16f).coerceIn(120f, 500f)
                            val made = Element(pageId = edit.pageId, x = edit.x.coerceIn(0f, NoteLayout.WIDTH - 120f), y = edit.y, w = w, h = 40f, text = text, colorHex = if (edit.fillHex != null) "1C1C1E" else penColor, fillHex = edit.fillHex)
                            canvas.addElement(made.copy(h = measuredHeight(made)))
                        }
                    }
                    textEdit = null
                }) { Text("Done") }
            },
            dismissButton = { TextButton(onClick = { textEdit = null }) { Text("Cancel") } },
        )
    }
}

private class TextEdit(val pageId: String, val x: Float, val y: Float, val existing: Element?, val fillHex: String? = null)

private fun measuredHeight(element: Element): Float = PageRenderer.layoutFor(element).height.toFloat() + 4f + 2 * element.inset

private fun pdfCloseLater(pdf: PdfSource?) {
    // The page render thread may still be finishing with it, and it holds only a file handle.
    if (pdf != null) Thread {
        Thread.sleep(1000)
        runCatching { pdf.close() }
    }.start()
}

private fun copyImage(context: android.content.Context, uri: Uri, folder: File): Pair<String, Float>? = runCatching {
    val name = "image-${newId()}.jpg"
    val file = File(folder, name)
    context.contentResolver.openInputStream(uri)!!.use { input -> file.outputStream().use { input.copyTo(it) } }
    val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.path, options)
    if (options.outWidth <= 0) {
        file.delete()
        return null
    }
    name to options.outHeight.toFloat() / options.outWidth
}.getOrNull()

@Composable
private fun BarButton(icon: ImageVector, label: String, active: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    val accent = MaterialTheme.colorScheme.primary
    Box(
        Modifier.size(44.dp).alpha(if (enabled) 1f else 0.3f).clip(RoundedCornerShape(10.dp))
            .background(if (active) accent.copy(alpha = 0.16f) else Color.Transparent)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, label, Modifier.size(22.dp), tint = if (active) accent else MaterialTheme.colorScheme.onSurface)
    }
}

@Composable
private fun BarDivider() {
    Box(Modifier.padding(horizontal = 4.dp).width(1.dp).height(22.dp).background(MaterialTheme.colorScheme.outlineVariant))
}

@Composable
private fun ColorDot(hex: String, selected: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(32.dp).clip(CircleShape).clickable(onClick = onClick)
            .border(if (selected) 2.dp else 0.dp, if (selected) MaterialTheme.colorScheme.primary else Color.Transparent, CircleShape)
            .semantics { contentDescription = "Color $hex" },
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.size(22.dp).background(Color(colorOf(hex)), CircleShape).border(0.5.dp, Color.Black.copy(alpha = 0.15f), CircleShape))
    }
}

@Composable
private fun SizeDot(diameter: Float, selected: Boolean, hex: String, onClick: () -> Unit) {
    Box(
        Modifier.size(34.dp).clip(RoundedCornerShape(8.dp))
            .background(if (selected) MaterialTheme.colorScheme.primary.copy(alpha = 0.16f) else Color.Transparent)
            .clickable(onClick = onClick).semantics { contentDescription = "Line width" },
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.size(diameter.dp).background(Color(colorOf(hex)), CircleShape).border(0.5.dp, Color.Black.copy(alpha = 0.15f), CircleShape))
    }
}

@Composable
private fun Hint(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun RecordingTimer(startedAt: Long, onStop: () -> Unit) {
    var seconds by remember { mutableLongStateOf(0L) }
    LaunchedEffect(startedAt) {
        while (true) {
            seconds = (System.currentTimeMillis() - startedAt) / 1000
            delay(500)
        }
    }
    Row(
        Modifier.padding(horizontal = 4.dp).clip(CircleShape).background(Color(0xFFE5484D)).clickable(onClick = onStop).padding(horizontal = 12.dp, vertical = 7.dp)
            .semantics { contentDescription = "Stop recording" },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.Stop, null, Modifier.size(14.dp), tint = Color.White)
        Spacer(Modifier.width(5.dp))
        Text("${seconds / 60}:${"%02d".format(seconds % 60)}", color = Color.White, style = MaterialTheme.typography.labelMedium)
    }
}

/** Notes open together, like the iPad's tabs. It only appears once there's more than one. */
@Composable
private fun TabStrip(current: String, onSwitch: (String) -> Unit, onCloseCurrent: () -> Unit) {
    val tabs by Library.tabs.collectAsState()
    val notes by Library.notes.collectAsState()
    // A locked note only opens through its lock, so it can't sit one tap away in a tab.
    val open = tabs.mapNotNull { id -> notes.firstOrNull { it.id == id && (!it.locked || it.id == current) } }
    if (open.size < 2) return
    Row(
        Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainerHighest).horizontalScroll(rememberScrollState()).padding(horizontal = 6.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        open.forEach { note ->
            val selected = note.id == current
            Row(
                Modifier.widthIn(max = 200.dp)
                    .then(if (selected) Modifier.shadow(1.dp, RoundedCornerShape(8.dp)) else Modifier)
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (selected) MaterialTheme.colorScheme.surface else Color.Transparent)
                    .clickable(enabled = !selected) { onSwitch(note.id) }
                    .padding(start = 12.dp, end = 4.dp, top = 2.dp, bottom = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(note.title, style = MaterialTheme.typography.labelLarge, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                IconButton(
                    onClick = {
                        if (selected) {
                            val next = open.firstOrNull { it.id != current }
                            Library.closeTab(current)
                            if (next != null) onSwitch(next.id) else onCloseCurrent()
                        } else {
                            Library.closeTab(note.id)
                        }
                    },
                    modifier = Modifier.size(28.dp),
                ) { Icon(Icons.Default.Close, "Close ${note.title}", Modifier.size(14.dp)) }
            }
        }
    }
}

@Composable
private fun PagesPanel(
    canvas: InkCanvasView,
    pageCount: Int,
    revision: Int,
    current: Int,
    pdf: PdfSource?,
    folder: File,
    onGo: (Int) -> Unit,
    onAdd: () -> Unit,
    onDuplicate: () -> Unit,
    onDelete: () -> Unit,
) {
    Column(Modifier.width(190.dp).fillMaxHeight().background(MaterialTheme.colorScheme.surfaceContainer)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
            TextButton(onClick = onAdd) { Text("Add") }
            TextButton(onClick = onDuplicate) { Text("Copy") }
            TextButton(onClick = onDelete, enabled = pageCount > 1) { Text("Delete") }
        }
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        val pages = canvas.note.pages
        LazyColumn(contentPadding = androidx.compose.foundation.layout.PaddingValues(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            itemsIndexed(pages, key = { _, page -> page.id }) { index, page ->
                var thumb by remember(page.id) { mutableStateOf<Bitmap?>(null) }
                LaunchedEffect(page.id, page.height, revision) {
                    val strokes = canvas.strokesOn(page.id)
                    val elements = canvas.note.elements.filter { it.pageId == page.id }
                    thumb = withContext(Dispatchers.Default) {
                        runCatching {
                            val scale = 200f / NoteLayout.WIDTH
                            Bitmap.createBitmap(200, (minOf(page.height, 1400f) * scale).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888).also {
                                PageRenderer.render(Canvas(it), page, strokes, elements, pdf, scale, folder)
                            }
                        }.getOrNull()
                    }
                }
                val shape = RoundedCornerShape(3.dp)
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth().clickable { onGo(index) }) {
                    Box(
                        Modifier.fillMaxWidth().aspectRatio(NoteLayout.WIDTH / minOf(page.height, 1400f)).shadow(2.dp, shape).clip(shape).background(Color(page.color.fill))
                            .border(if (index == current) 2.dp else 0.5.dp, if (index == current) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant, shape)
                    ) {
                        thumb?.let { Image(it.asImageBitmap(), "Page ${index + 1}", Modifier.fillMaxSize()) }
                    }
                    Spacer(Modifier.height(4.dp))
                    Text("${index + 1}", style = MaterialTheme.typography.labelSmall, color = if (index == current) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

@Composable
private fun PagePickerDialog(onDismiss: () -> Unit, onCreate: (Page) -> Unit) {
    val context = LocalContext.current
    var style by remember { mutableStateOf(Prefs.paperStyle(context)) }
    var color by remember { mutableStateOf(Prefs.paperColor(context)) }
    var size by remember { mutableStateOf(Prefs.pageSize(context)) }
    var endless by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add Page", fontFamily = FontFamily.Serif, fontWeight = FontWeight.SemiBold) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                ChoiceRow("Paper", PaperStyle.entries, style, { it.title }) { style = it }
                ChoiceRow("Color", PaperColor.entries, color, { it.title }) { color = it }
                ChoiceRow("Size", PageSize.entries, size, { it.title }) { size = it }
                Row(Modifier.fillMaxWidth().padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Endless Page", style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f))
                    Switch(endless, { endless = it })
                }
            }
        },
        confirmButton = { TextButton(onClick = { onCreate(Page(height = size.height, style = style, color = color, endless = endless)) }) { Text("Add") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** One running recording, always saved to its own file in the note's folder. */
private class ActiveRecording(private val recorder: MediaRecorder, private val file: File, private val startedAt: Long) {
    fun stop(): Recording? {
        val duration = System.currentTimeMillis() - startedAt
        val ok = runCatching { recorder.stop() }.isSuccess
        recorder.release()
        if (!ok || duration < 500) {
            file.delete()
            return null
        }
        return Recording(file = file.name, startedAt = startedAt, durationMs = duration)
    }

    companion object {
        @Suppress("DEPRECATION")
        fun start(folder: File): ActiveRecording? {
            val file = File(folder, "recording-${newId()}.m4a")
            val recorder = MediaRecorder()
            return runCatching {
                recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
                recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                recorder.setAudioEncodingBitRate(96_000)
                recorder.setAudioSamplingRate(44_100)
                recorder.setOutputFile(file.path)
                recorder.prepare()
                recorder.start()
                ActiveRecording(recorder, file, System.currentTimeMillis())
            }.getOrElse {
                recorder.release()
                file.delete()
                null
            }
        }
    }
}

private class RecordingPlayer {
    private var player: MediaPlayer? = null
    var playingId by mutableStateOf<String?>(null)
        private set

    fun play(file: File, id: String, atMs: Int = 0) {
        stop()
        val created = runCatching {
            MediaPlayer().apply {
                setDataSource(file.path)
                prepare()
                seekTo(atMs)
                setOnCompletionListener { stop() }
                start()
            }
        }.getOrNull() ?: return
        player = created
        playingId = id
    }

    fun pause() {
        runCatching { player?.pause() }
    }

    fun stop() {
        runCatching {
            player?.stop()
            player?.release()
        }
        player = null
        playingId = null
    }
}

@Composable
private fun RecordingsPanel(recordings: List<Recording>, player: RecordingPlayer, recording: Boolean, folder: File, onDelete: (Recording) -> Unit) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainerLow) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            if (recordings.isEmpty()) {
                Text(if (recording) "Recording. Stop to add it here." else "No recordings yet. Tap the microphone to start one.", style = MaterialTheme.typography.bodySmall)
            }
            recordings.forEach { item ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = {
                        if (player.playingId == item.id) player.stop() else player.play(File(folder, item.file), item.id)
                    }) {
                        Icon(if (player.playingId == item.id) Icons.Default.Stop else Icons.Default.PlayArrow, if (player.playingId == item.id) "Stop" else "Play")
                    }
                    Text(
                        DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(item.startedAt)) + " · ${item.durationMs / 60000}:${"%02d".format(item.durationMs / 1000 % 60)}",
                        Modifier.weight(1f),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    IconButton(onClick = { onDelete(item) }) { Icon(Icons.Default.Delete, "Delete recording") }
                }
            }
        }
    }
}
