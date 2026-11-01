package com.warriorbiswas.margin

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import android.view.WindowManager
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.EditNote
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.School
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.StarBorder
import androidx.compose.material.icons.outlined.SwapVert
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material.icons.outlined.UploadFile
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.DialogWindowProvider
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.launch

private val Covers = listOf("Navy" to "1F3A5F", "Forest" to "2F4F3E", "Oxblood" to "7A2E2E", "Graphite" to "3B3B3F", "Ochre" to "8A6D3B", "Plum" to "5B4A7A")
private val Sorts = listOf("Date Edited", "Date Created", "Title")

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun LibraryScreen(onOpen: (String) -> Unit, onSettings: () -> Unit, onReview: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val notes by Library.notes.collectAsState()
    val subjects by Library.subjects.collectAsState()
    // "all", "favorites", "unfiled", "study", "templates", "trash", "subject:<id>" or "tag:<name>"
    var shelf by rememberSaveable { mutableStateOf("all") }
    var search by rememberSaveable { mutableStateOf("") }
    var sort by rememberSaveable { mutableStateOf(Prefs.sort(context)) }
    var creating by remember { mutableStateOf(false) }
    var asking by remember { mutableStateOf<Prompt?>(null) }
    var deleting by remember { mutableStateOf<Note?>(null) }
    var moving by remember { mutableStateOf<Note?>(null) }
    var busy by remember { mutableStateOf<String?>(null) }
    var afterUnlock by remember { mutableStateOf<(() -> Unit)?>(null) }
    val folder = shelf.removePrefix("subject:").takeIf { shelf.startsWith("subject:") }

    val unlock = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK) afterUnlock?.invoke()
        afterUnlock = null
    }

    /** A privacy lock for the screen, using the device's own screen lock. With none set, there's nothing to check against. */
    fun confirmed(title: String, then: () -> Unit) {
        val keyguard = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        @Suppress("DEPRECATION")
        val intent = keyguard.createConfirmDeviceCredentialIntent(title, null)
        if (intent == null) {
            then()
        } else {
            afterUnlock = then
            unlock.launch(intent)
        }
    }

    fun open(note: Note) {
        if (note.locked) confirmed("Open “${note.title}”") { onOpen(note.id) } else onOpen(note.id)
    }

    val pdfPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri != null) {
            busy = "Importing…"
            scope.launch {
                val name = runCatching {
                    context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else null }
                }.getOrNull()
                val note = Library.importPdf(uri, folder, name)
                busy = null
                if (note != null) onOpen(note.id) else Toast.makeText(context, "Margin couldn't read that PDF.", Toast.LENGTH_LONG).show()
            }
        }
    }

    val query = search.trim()
    val visible = notes.filter { note ->
        val onShelf = when {
            shelf == "all" || shelf == "study" -> note.deletedAt == null && !note.isTemplate
            shelf == "favorites" -> note.deletedAt == null && note.favorite
            shelf == "unfiled" -> note.deletedAt == null && note.subjectId == null && !note.isTemplate
            shelf == "templates" -> note.deletedAt == null && note.isTemplate
            shelf == "trash" -> note.deletedAt != null
            shelf.startsWith("subject:") -> note.deletedAt == null && note.subjectId == folder
            shelf.startsWith("tag:") -> note.deletedAt == null && shelf.removePrefix("tag:") in note.tags
            else -> false
        }
        // A locked note's contents stay out of search results.
        onShelf && (query.isEmpty() || note.title.contains(query, true) || (!note.locked && (note.fullText().contains(query, true) || note.tags.any { it.contains(query, true) })))
    }.let { list ->
        when (sort) {
            "Date Created" -> list.sortedByDescending { it.createdAt }
            "Title" -> list.sortedBy { it.title.lowercase() }
            else -> list.sortedByDescending { it.updatedAt }
        }
    }
    val due = remember(notes) { Library.dueCards().size }
    val title = when {
        shelf == "favorites" -> "Favorites"
        shelf == "unfiled" -> "Unfiled"
        shelf == "study" -> "Study"
        shelf == "templates" -> "My Templates"
        shelf == "trash" -> "Recently Deleted"
        folder != null -> subjects.firstOrNull { it.id == folder }?.name ?: "Notes"
        shelf.startsWith("tag:") -> "#" + shelf.removePrefix("tag:")
        else -> "All Notes"
    }

    val sidebar: @Composable (close: () -> Unit) -> Unit = { close ->
        Sidebar(
            shelf = shelf,
            due = due,
            tags = remember(notes) { Library.allTags() },
            select = {
                shelf = it
                close()
            },
            onSettings = onSettings,
            onAsk = { asking = it },
            onDeletedFolder = { if (shelf == "subject:$it") shelf = "all" },
        )
    }

    val detail: @Composable (menu: (() -> Unit)?) -> Unit = { menu ->
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                if (menu != null) IconButton(onClick = menu) { Icon(Icons.Default.Menu, "Folders") }
                Spacer(Modifier.weight(1f))
                var sorting by remember { mutableStateOf(false) }
                Box {
                    IconButton(onClick = { sorting = true }) { Icon(Icons.Outlined.SwapVert, "Sort") }
                    DropdownMenu(expanded = sorting, onDismissRequest = { sorting = false }) {
                        Sorts.forEach { option ->
                            DropdownMenuItem(
                                text = { Text(option, fontWeight = if (option == sort) FontWeight.SemiBold else FontWeight.Normal) },
                                onClick = {
                                    sort = option
                                    Prefs.set(context, "sort", option)
                                    sorting = false
                                },
                            )
                        }
                    }
                }
                IconButton(onClick = { pdfPicker.launch(arrayOf("application/pdf")) }) { Icon(Icons.Outlined.UploadFile, "Import PDF") }
                // A tap asks how the note should be set up. Holding it skips that, for writing something down right away.
                Box(
                    Modifier.size(48.dp).clip(CircleShape)
                        .combinedClickable(onClick = { creating = true }, onLongClick = { onOpen(Library.createNote(folder).id) })
                        .semantics { contentDescription = "New Note" },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Outlined.EditNote, null, tint = MaterialTheme.colorScheme.primary) }
            }
            Text(
                title,
                fontFamily = FontFamily.Serif,
                fontWeight = FontWeight.Bold,
                fontSize = 34.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(start = 24.dp, end = 24.dp, bottom = 10.dp),
            )
            if (shelf == "study") {
                StudyHome(due, onReview)
            } else {
                SearchField(search, { search = it }, Modifier.padding(horizontal = 24.dp))
                if (visible.isEmpty()) {
                    EmptyLibrary(
                        when {
                            query.isNotEmpty() -> "No Results for “$query”"
                            shelf == "trash" -> "Nothing Deleted"
                            else -> "No Notes"
                        },
                        shelf != "trash" && query.isEmpty(),
                    ) { creating = true }
                } else {
                    LazyVerticalGrid(
                        columns = GridCells.Adaptive(170.dp),
                        contentPadding = PaddingValues(24.dp),
                        horizontalArrangement = Arrangement.spacedBy(22.dp),
                        verticalArrangement = Arrangement.spacedBy(26.dp),
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        items(visible, key = { it.id }) { note ->
                            NoteCard(
                                note = note,
                                onOpen = { if (note.deletedAt == null) open(note) },
                                onAsk = { asking = it },
                                onMove = { moving = note },
                                onDeleteForever = { deleting = note },
                                onLockChange = {
                                    if (note.locked) confirmed("Remove the lock from “${note.title}”") { Library.setLocked(note.id, false) }
                                    else Library.setLocked(note.id, true)
                                },
                                onFile = {
                                    busy = "Choosing a folder…"
                                    scope.launch {
                                        runCatching {
                                            val name = AI.folder("${note.title}\n${note.fullText()}", subjects.map { it.name })
                                            subjects.firstOrNull { it.name == name }?.let { Library.move(note.id, it.id) }
                                        }.onFailure { Toast.makeText(context, it.message ?: "Margin couldn't choose a folder.", Toast.LENGTH_LONG).show() }
                                        busy = null
                                    }
                                },
                            )
                        }
                    }
                }
            }
        }
    }

    Surface(color = MaterialTheme.colorScheme.background, modifier = Modifier.fillMaxSize()) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            if (maxWidth >= 700.dp) {
                Row(Modifier.fillMaxSize()) {
                    Box(Modifier.width(290.dp).fillMaxHeight().background(MaterialTheme.colorScheme.surfaceContainer)) { sidebar {} }
                    VerticalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    Box(Modifier.weight(1f)) { detail(null) }
                }
            } else {
                val drawer = rememberDrawerState(DrawerValue.Closed)
                ModalNavigationDrawer(
                    drawerState = drawer,
                    drawerContent = {
                        ModalDrawerSheet(drawerContainerColor = MaterialTheme.colorScheme.surfaceContainer, modifier = Modifier.width(300.dp)) {
                            sidebar { scope.launch { drawer.close() } }
                        }
                    },
                ) { detail { scope.launch { drawer.open() } } }
            }
            busy?.let { message ->
                Surface(shape = RoundedCornerShape(12.dp), shadowElevation = 8.dp, modifier = Modifier.align(Alignment.Center)) {
                    Text(message, Modifier.padding(horizontal = 24.dp, vertical = 18.dp))
                }
            }
        }
    }

    if (creating) {
        NewNoteDialog(folder, onDismiss = { creating = false }, onCreated = {
            creating = false
            onOpen(it.id)
        })
    }
    asking?.let { prompt ->
        NameDialog(prompt.title, prompt.initial, "OK", allowBlank = prompt.allowBlank, onDismiss = { asking = null }) {
            prompt.action(it)
            asking = null
        }
    }
    moving?.let { note ->
        AlertDialog(
            onDismissRequest = { moving = null },
            title = { Text("Move to") },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    TextButton(onClick = {
                        Library.move(note.id, null)
                        moving = null
                    }) { Text("Unfiled") }
                    subjects.forEach { subject ->
                        TextButton(onClick = {
                            Library.move(note.id, subject.id)
                            moving = null
                        }) { Text(Library.path(subject)) }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { moving = null }) { Text("Cancel") } },
        )
    }
    deleting?.let { note ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("Delete “${note.title}” Forever?") },
            text = { Text("This can't be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    Library.deleteForever(note.id)
                    deleting = null
                }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } },
        )
    }
}

private class Prompt(val title: String, val initial: String = "", val allowBlank: Boolean = false, val action: (String) -> Unit)

@Composable
private fun Sidebar(shelf: String, due: Int, tags: List<String>, select: (String) -> Unit, onSettings: () -> Unit, onAsk: (Prompt) -> Unit, onDeletedFolder: (String) -> Unit) {
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().verticalScroll(rememberScrollState()).padding(horizontal = 12.dp)) {
        Row(Modifier.fillMaxWidth().padding(top = 8.dp, start = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Margin", fontFamily = FontFamily.Serif, fontWeight = FontWeight.Bold, fontSize = 30.sp, modifier = Modifier.weight(1f))
            IconButton(onClick = onSettings) { Icon(Icons.Outlined.Settings, "Settings") }
        }
        Spacer(Modifier.height(8.dp))
        SidebarRow("All Notes", Icons.Outlined.Description, shelf == "all") { select("all") }
        SidebarRow("Favorites", Icons.Outlined.StarBorder, shelf == "favorites") { select("favorites") }
        SidebarRow("Unfiled", Icons.Outlined.Inbox, shelf == "unfiled") { select("unfiled") }
        SidebarRow("Study", Icons.Outlined.School, shelf == "study", trailing = if (due > 0) "$due" else null) { select("study") }
        SidebarHeading("Folders")
        FolderRows(null, 0, shelf, select, onAsk, onDeletedFolder)
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                .clickable { onAsk(Prompt("New Folder") { Library.addSubject(it) }) }
                .padding(horizontal = 12.dp, vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Default.Add, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(12.dp))
            Text("New Folder", color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.bodyLarge)
        }
        if (tags.isNotEmpty()) {
            SidebarHeading("Tags")
            tags.forEach { tag -> SidebarRow(tag, Icons.Outlined.Tag, shelf == "tag:$tag") { select("tag:$tag") } }
        }
        Spacer(Modifier.height(16.dp))
        SidebarRow("My Templates", Icons.Outlined.ContentCopy, shelf == "templates") { select("templates") }
        SidebarRow("Recently Deleted", Icons.Outlined.DeleteOutline, shelf == "trash") { select("trash") }
        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun SidebarHeading(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 12.dp, top = 20.dp, bottom = 6.dp))
}

@Composable
private fun SidebarRow(label: String, icon: ImageVector, selected: Boolean, trailing: String? = null, onClick: () -> Unit) {
    val accent = MaterialTheme.colorScheme.primary
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
            .background(if (selected) accent.copy(alpha = 0.14f) else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, Modifier.size(20.dp), tint = if (selected) accent else MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(12.dp))
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, color = if (selected) accent else MaterialTheme.colorScheme.onSurface, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (trailing != null) Text(trailing, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FolderRows(parent: String?, depth: Int, shelf: String, select: (String) -> Unit, onAsk: (Prompt) -> Unit, onDeleted: (String) -> Unit) {
    val all by Library.subjects.collectAsState()
    val accent = MaterialTheme.colorScheme.primary
    all.filter { it.parentId == parent }.sortedBy { it.name.lowercase() }.forEach { subject ->
        val selected = shelf == "subject:${subject.id}"
        var menu by remember { mutableStateOf(false) }
        Box {
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                    .background(if (selected) accent.copy(alpha = 0.14f) else Color.Transparent)
                    .combinedClickable(onClick = { select("subject:${subject.id}") }, onLongClick = { menu = true })
                    .padding(start = 16.dp + 18.dp * depth, end = 12.dp, top = 11.dp, bottom = 11.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.size(12.dp).background(Color(colorOf(subject.colorHex)), CircleShape))
                Spacer(Modifier.width(16.dp))
                Text(subject.name, style = MaterialTheme.typography.bodyLarge, color = if (selected) accent else MaterialTheme.colorScheme.onSurface, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("New Subfolder") }, onClick = {
                    menu = false
                    onAsk(Prompt("New Subfolder") { Library.addSubject(it, subject.id) })
                })
                DropdownMenuItem(text = { Text("Rename") }, onClick = {
                    menu = false
                    onAsk(Prompt("Rename Folder", subject.name) { Library.renameSubject(subject.id, it) })
                })
                DropdownMenuItem(text = { Text("Delete Folder", color = MaterialTheme.colorScheme.error) }, onClick = {
                    menu = false
                    onDeleted(subject.id)
                    Library.deleteSubject(subject.id)
                })
            }
        }
        FolderRows(subject.id, depth + 1, shelf, select, onAsk, onDeleted)
    }
}

@Composable
private fun SearchField(value: String, onChange: (String) -> Unit, modifier: Modifier = Modifier) {
    val focus = LocalFocusManager.current
    Row(
        modifier.fillMaxWidth().height(40.dp).clip(RoundedCornerShape(10.dp)).background(MaterialTheme.colorScheme.surfaceVariant).padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.Search, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(8.dp))
        Box(Modifier.weight(1f)) {
            if (value.isEmpty()) Text("Search notes and handwriting", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
            BasicTextField(
                value, onChange, singleLine = true,
                textStyle = MaterialTheme.typography.bodyMedium.copy(color = MaterialTheme.colorScheme.onSurface),
                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { focus.clearFocus() }),
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Search" },
            )
        }
        if (value.isNotEmpty()) Icon(Icons.Default.Close, "Clear search", Modifier.size(18.dp).clickable { onChange("") }, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun EmptyLibrary(title: String, canCreate: Boolean, onCreate: () -> Unit) {
    Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Outlined.Description, null, Modifier.size(52.dp), tint = MaterialTheme.colorScheme.outline)
            Spacer(Modifier.height(14.dp))
            Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            if (canCreate) {
                Spacer(Modifier.height(16.dp))
                Button(onClick = onCreate) { Text("New Note") }
            }
        }
    }
}

@Composable
private fun StudyHome(due: Int, onReview: () -> Unit) {
    val notes by Library.notes.collectAsState()
    val withCards = notes.filter { it.deletedAt == null && it.flashcards.isNotEmpty() }
    Column(Modifier.fillMaxSize().padding(horizontal = 24.dp).verticalScroll(rememberScrollState())) {
        Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surfaceContainer, modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(20.dp)) {
                Text(if (due > 0) "$due card${if (due == 1) "" else "s"} due" else "Nothing due right now", style = MaterialTheme.typography.titleLarge, fontFamily = FontFamily.Serif, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(4.dp))
                Text("Open a note and tap Study to chat with it, or make flashcards, quizzes and mind maps.", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
                if (due > 0) {
                    Spacer(Modifier.height(14.dp))
                    Button(onClick = onReview) { Text("Review") }
                }
            }
        }
        if (withCards.isNotEmpty()) {
            SidebarHeading("Flashcards")
            withCards.forEach { note ->
                Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp)) {
                    Text(note.title, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${note.flashcards.size}", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun NoteCard(note: Note, onOpen: () -> Unit, onAsk: (Prompt) -> Unit, onMove: () -> Unit, onDeleteForever: () -> Unit, onLockChange: () -> Unit, onFile: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val thumbnails by Library.thumbnails.collectAsState()
    val thumb = remember(note.id, thumbnails) {
        Library.thumbFile(note.id).takeIf { it.exists() }?.let { BitmapFactory.decodeFile(it.path) }?.asImageBitmap()
    }
    val date = remember(note.updatedAt) { DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(note.updatedAt)) }
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    // The card gives way slightly under a finger, like pressing on paper.
    val pressScale by animateFloatAsState(if (pressed) 0.97f else 1f, tween(120), label = "press")
    val shape = RoundedCornerShape(4.dp)
    val subjects by Library.subjects.collectAsState()
    val cloudKey by CloudKey.stored.collectAsState()
    val model by ModelDownloads.state.collectAsState()

    Column(
        Modifier.scale(pressScale)
            .combinedClickable(interactionSource = interaction, indication = null, onClick = onOpen, onLongClick = { menu = true })
            .semantics { contentDescription = "Note ${note.title}" }
    ) {
        // Every card is the same shape, whatever the page's, so a row of notes lines up.
        Box(
            Modifier.fillMaxWidth().aspectRatio(8.5f / 11f)
                .shadow(5.dp, shape, ambientColor = Color.Black.copy(alpha = 0.2f), spotColor = Color.Black.copy(alpha = 0.25f))
                .clip(shape).background(Color.White)
                .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, shape)
        ) {
            when {
                note.locked -> Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surfaceVariant), contentAlignment = Alignment.Center) {
                    Icon(Icons.Default.Lock, "Locked", Modifier.size(36.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                note.coverHex != null -> Box(Modifier.fillMaxSize().background(Color(colorOf(note.coverHex)))) {
                    // A notebook's stitched spine.
                    Box(Modifier.width(12.dp).fillMaxHeight().background(Color.Black.copy(alpha = 0.18f)))
                    Text(note.title, color = Color.White, fontFamily = FontFamily.Serif, fontWeight = FontWeight.SemiBold, fontSize = 20.sp, maxLines = 4, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(start = 26.dp, top = 16.dp, end = 16.dp))
                }
                thumb != null -> Image(thumb, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop, alignment = Alignment.TopCenter)
                else -> note.pages.firstOrNull()?.let { Box(Modifier.fillMaxSize().background(Color(it.color.fill))) }
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                fun item(label: String, action: () -> Unit): @Composable () -> Unit = {
                    DropdownMenuItem(text = { Text(label) }, onClick = {
                        menu = false
                        action()
                    })
                }
                if (note.deletedAt != null) {
                    item("Restore") { Library.restore(note.id) }()
                    DropdownMenuItem(text = { Text("Delete Forever", color = MaterialTheme.colorScheme.error) }, onClick = {
                        menu = false
                        onDeleteForever()
                    })
                } else {
                    item("Rename") { onAsk(Prompt("Rename Note", note.title) { Library.rename(note.id, it) }) }()
                    item(if (note.favorite) "Unfavorite" else "Favorite") { Library.toggleFavorite(note.id) }()
                    item("Tags") {
                        onAsk(Prompt("Tags, separated by commas", note.tags.joinToString(", "), allowBlank = true) { text ->
                            Library.setTags(note.id, text.split(",").map { it.trim() }.filter { it.isNotEmpty() })
                        })
                    }()
                    item("Move to") { onMove() }()
                    if (subjects.isNotEmpty() && !note.locked && (cloudKey != null || model == ModelDownloads.State.Installed)) item("File Automatically") { onFile() }()
                    var covers by remember { mutableStateOf(false) }
                    DropdownMenuItem(text = { Text("Cover") }, onClick = { covers = !covers })
                    if (covers) {
                        DropdownMenuItem(text = { Text("    First Page") }, onClick = {
                            menu = false
                            Library.setCover(note.id, null)
                        })
                        Covers.forEach { (name, hex) ->
                            DropdownMenuItem(
                                text = { Text(name) },
                                leadingIcon = { Box(Modifier.size(14.dp).background(Color(colorOf(hex)), CircleShape)) },
                                onClick = {
                                    menu = false
                                    Library.setCover(note.id, hex)
                                },
                            )
                        }
                    }
                    item(if (note.locked) "Remove Lock" else "Lock") { onLockChange() }()
                    item("Duplicate") { Library.duplicate(note.id) }()
                    item(if (note.isTemplate) "Stop Using as Template" else "Save as Template") { Library.setTemplate(note.id, !note.isTemplate) }()
                    DropdownMenuItem(text = { Text("Delete", color = MaterialTheme.colorScheme.error) }, onClick = {
                        menu = false
                        Library.trash(note.id)
                    })
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        // The rule down a ruled page's left side, which is what the app is named for.
        Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
            Box(Modifier.width(1.5.dp).fillMaxHeight().background(MaterialTheme.colorScheme.primary))
            Spacer(Modifier.width(8.dp))
            Column {
                Text(note.title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(date + if (note.pages.size > 1) " · ${note.pages.size} pages" else "", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                    if (note.favorite) Icon(Icons.Default.Star, "Favorite", Modifier.size(13.dp), tint = Color(0xFFE0A400))
                    if (note.recordings.isNotEmpty()) Icon(Icons.Default.GraphicEq, "Has audio", Modifier.size(13.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (note.locked) Icon(Icons.Default.Lock, "Locked", Modifier.size(13.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

/** On a tablet held sideways the keyboard would cover a dialog's buttons, so the dialog shrinks and its contents scroll instead. */
@Composable
fun ResizeDialogForKeyboard() {
    val view = LocalView.current
    SideEffect { (view.parent as? DialogWindowProvider)?.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE) }
}

@Composable
fun NameDialog(title: String, initial: String, action: String, allowBlank: Boolean = false, onDismiss: () -> Unit, onDone: (String) -> Unit) {
    var name by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            ResizeDialogForKeyboard()
            Text(title)
        },
        text = {
            OutlinedTextField(
                name, { name = it }, singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
            )
        },
        confirmButton = { TextButton(enabled = allowBlank || name.isNotBlank(), onClick = { onDone(name.trim()) }) { Text(action) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
fun <T> ChoiceRow(label: String, options: List<T>, selected: T?, title: (T) -> String, onSelect: (T) -> Unit) {
    Text(label, style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 10.dp))
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        options.forEach { option ->
            FilterChip(option == selected, { onSelect(option) }, { Text(title(option)) })
        }
    }
}

@Composable
private fun NewNoteDialog(folder: String?, onDismiss: () -> Unit, onCreated: (Note) -> Unit) {
    val context = LocalContext.current
    var title by remember { mutableStateOf("") }
    var setup by remember { mutableStateOf<NoteSetup?>(null) }
    var style by remember { mutableStateOf(Prefs.paperStyle(context)) }
    var color by remember { mutableStateOf(Prefs.paperColor(context)) }
    var size by remember { mutableStateOf(Prefs.pageSize(context)) }
    var endless by remember { mutableStateOf(false) }
    val notes by Library.notes.collectAsState()
    val templates = notes.filter { it.isTemplate && it.deletedAt == null }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            ResizeDialogForKeyboard()
            Text("New Note", fontFamily = FontFamily.Serif, fontWeight = FontWeight.SemiBold)
        },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                OutlinedTextField(
                    title, { title = it }, label = { Text("Title") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                    modifier = Modifier.fillMaxWidth(),
                )
                ChoiceRow("Set Up For", NoteSetup.entries, setup, { it.title }) {
                    setup = it
                    style = it.paper
                }
                ChoiceRow("Paper", PaperStyle.entries, style, { it.title }) {
                    style = it
                    setup = null
                }
                ChoiceRow("Color", PaperColor.entries, color, { it.title }) { color = it }
                ChoiceRow("Size", PageSize.entries, size, { it.title }) { size = it }
                Row(Modifier.fillMaxWidth().padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Endless Page", style = MaterialTheme.typography.labelLarge)
                        Text("Grows as you write", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Switch(endless, { endless = it })
                }
                if (templates.isNotEmpty()) {
                    ChoiceRow("From a Template", templates, null, { it.title }) { template ->
                        Library.duplicate(template.id)?.let { copy ->
                            val named = if (title.isBlank()) copy else copy.copy(title = title.trim(), subjectId = folder).also { Library.save(it) }
                            onCreated(named)
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                onCreated(Library.createNote(folder, title.trim().ifBlank { null }, Page(height = size.height, style = style, color = color, endless = endless)))
            }) { Text("Create") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
