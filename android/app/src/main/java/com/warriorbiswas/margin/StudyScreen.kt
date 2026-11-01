package com.warriorbiswas.margin

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

private enum class StudyTab(val title: String) { Chat("Chat"), Summary("Summary"), KeyPoints("Key Points"), Cards("Flashcards"), Quiz("Quiz"), MindMap("Mind Map"), Explain("Explain"), TeachBack("Teach Back") }

private fun Throwable.friendly() = message?.takeIf { this is AIError } ?: "Something went wrong. Try again."

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StudyScreen(noteId: String, onClose: () -> Unit) {
    val notes by Library.notes.collectAsState()
    val note = notes.firstOrNull { it.id == noteId }
    var tab by remember { mutableStateOf(StudyTab.Chat) }
    val key by CloudKey.stored.collectAsState()
    val model by ModelDownloads.state.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Study") },
                navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            )
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().imePadding()) {
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StudyTab.entries.forEach { FilterChip(tab == it, { tab = it }, { Text(it.title) }) }
            }
            Text(
                when {
                    key != null -> "Using NVIDIA's model, with the on-device model as backup."
                    model == ModelDownloads.State.Installed -> "Using the on-device model."
                    else -> "Add an NVIDIA key or download the writing model in Settings to use this."
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
            if (note == null) return@Column
            if (note.fullText().isBlank()) {
                Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
                    Text("Nothing to study yet. Write or type something in this note, then come back. Handwriting is read once the recognition model has downloaded.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                return@Column
            }
            when (tab) {
                StudyTab.Chat -> ChatTab(note)
                StudyTab.Summary -> TextTab(note, "Summarize") { text, partial -> AI.summary(text, partial) }
                StudyTab.KeyPoints -> TextTab(note, "Find Key Points") { text, partial -> AI.keyPoints(text, partial) }
                StudyTab.Cards -> CardsTab(note)
                StudyTab.Quiz -> QuizTab(note)
                StudyTab.MindMap -> MindMapTab(note)
                StudyTab.Explain -> ExplainTab(note)
                StudyTab.TeachBack -> TeachBackTab(note)
            }
        }
    }
}

@Composable
private fun ChatTab(note: Note) {
    val scope = rememberCoroutineScope()
    val turns = remember { mutableStateListOf<ChatTurn>() }
    var partial by remember { mutableStateOf<String?>(null) }
    var input by remember { mutableStateOf("") }
    var job by remember { mutableStateOf<Job?>(null) }
    var failure by remember { mutableStateOf<String?>(null) }
    val list = rememberLazyListState()

    LaunchedEffect(turns.size, partial) {
        val count = turns.size + (if (partial != null) 1 else 0)
        if (count > 0) list.animateScrollToItem(count - 1)
    }

    fun send() {
        val question = input.trim()
        if (question.isEmpty() || job != null) return
        input = ""
        failure = null
        turns += ChatTurn("user", question)
        partial = ""
        val thisJob = scope.launch {
            try {
                val answer = AI.chat(note, turns.toList()) { partial = it }
                turns += ChatTurn("assistant", answer)
            } catch (e: CancellationException) {
                partial?.takeIf { it.isNotBlank() }?.let { turns += ChatTurn("assistant", it) }
                throw e
            } catch (e: Exception) {
                failure = e.friendly()
            } finally {
                partial = null
                job = null
            }
        }
        job = thisJob
    }

    Column(Modifier.fillMaxSize()) {
        LazyColumn(state = list, modifier = Modifier.weight(1f).fillMaxWidth(), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            items(turns) { Bubble(it.text, it.role == "user") }
            partial?.let { text -> item { Bubble(text.ifEmpty { "…" }, false) } }
        }
        failure?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) }
        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(input, { input = it }, placeholder = { Text("Ask about this note") }, modifier = Modifier.weight(1f), maxLines = 4)
            if (job != null) {
                IconButton(onClick = { job?.cancel() }) { Icon(Icons.Default.Stop, "Stop") }
            } else {
                IconButton(onClick = { send() }, enabled = input.isNotBlank()) { Icon(Icons.AutoMirrored.Filled.Send, "Send") }
            }
        }
    }
}

@Composable
private fun Bubble(text: String, mine: Boolean) {
    Box(Modifier.fillMaxWidth(), contentAlignment = if (mine) Alignment.CenterEnd else Alignment.CenterStart) {
        SelectionContainer {
            Text(
                text,
                color = if (mine) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.clip(RoundedCornerShape(14.dp))
                    .background(if (mine) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant)
                    .padding(12.dp),
            )
        }
    }
}

@Composable
private fun TextTab(note: Note, action: String, make: suspend (String, (String) -> Unit) -> String) {
    val scope = rememberCoroutineScope()
    var text by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    var job by remember { mutableStateOf<Job?>(null) }
    Column(Modifier.fillMaxSize().padding(16.dp).verticalScroll(rememberScrollState())) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(enabled = !working, onClick = {
                working = true
                failure = null
                text = ""
                job = scope.launch {
                    try {
                        text = make(note.fullText()) { text = it }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        failure = e.friendly()
                    } finally {
                        working = false
                    }
                }
            }) { Text(action) }
            if (working) OutlinedButton(onClick = { job?.cancel() }) { Text("Stop") }
        }
        Spacer(Modifier.height(12.dp))
        failure?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        if (working && text.isEmpty()) CircularProgressIndicator(Modifier.size(28.dp))
        SelectionContainer { Text(text) }
    }
}

@Composable
private fun CardsTab(note: Note) {
    val scope = rememberCoroutineScope()
    var working by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    var reviewing by remember { mutableStateOf(false) }
    if (reviewing) {
        BackHandler { reviewing = false }
        ReviewScreen(cards = note.id, onClose = { reviewing = false })
        return
    }
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(enabled = !working, onClick = {
                working = true
                failure = null
                scope.launch {
                    try {
                        val made = AI.flashcards(note.fullText())
                        val current = Library.note(note.id)?.flashcards.orEmpty()
                        Library.setCards(note.id, current + made)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        failure = e.friendly()
                    } finally {
                        working = false
                    }
                }
            }) { Text("Make Flashcards") }
            if (note.flashcards.isNotEmpty()) OutlinedButton(onClick = { reviewing = true }) { Text("Review All") }
        }
        Spacer(Modifier.height(12.dp))
        failure?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        if (working) CircularProgressIndicator(Modifier.size(28.dp))
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(note.flashcards, key = { it.id }) { card ->
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp)) {
                        Text(card.front, fontWeight = FontWeight.Medium)
                        Text(card.back, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

@Composable
private fun QuizTab(note: Note) {
    val scope = rememberCoroutineScope()
    var questions by remember { mutableStateOf<List<QuizQuestion>>(emptyList()) }
    val picks = remember { mutableStateListOf<Int?>() }
    var working by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize().padding(16.dp).verticalScroll(rememberScrollState())) {
        Button(enabled = !working, onClick = {
            working = true
            failure = null
            scope.launch {
                try {
                    val made = AI.quiz(note.fullText())
                    picks.clear()
                    made.forEach { _ -> picks.add(null) }
                    questions = made
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    failure = e.friendly()
                } finally {
                    working = false
                }
            }
        }) { Text(if (questions.isEmpty()) "Write a Quiz" else "New Quiz") }
        Spacer(Modifier.height(12.dp))
        failure?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        if (working) CircularProgressIndicator(Modifier.size(28.dp))
        questions.forEachIndexed { index, question ->
            Text("${index + 1}. ${question.question}", fontWeight = FontWeight.Medium, modifier = Modifier.padding(top = 14.dp, bottom = 6.dp))
            question.options.forEachIndexed { option, label ->
                val pick = picks.getOrNull(index)
                val shade = when {
                    pick == null -> MaterialTheme.colorScheme.surfaceVariant
                    option == question.answer -> Color(0xFF2E9E5B).copy(alpha = 0.3f)
                    option == pick -> MaterialTheme.colorScheme.error.copy(alpha = 0.25f)
                    else -> MaterialTheme.colorScheme.surfaceVariant
                }
                Text(
                    label,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp).clip(RoundedCornerShape(8.dp)).background(shade)
                        .clickable(enabled = pick == null) { picks[index] = option }.padding(12.dp),
                )
            }
        }
        if (questions.isNotEmpty() && picks.none { it == null }) {
            val right = questions.indices.count { picks[it] == questions[it].answer }
            Text("$right of ${questions.size} right", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 16.dp))
        }
    }
}

@Composable
private fun MindMapTab(note: Note) {
    val scope = rememberCoroutineScope()
    var root by remember { mutableStateOf<MindNode?>(null) }
    var working by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize().padding(16.dp).verticalScroll(rememberScrollState())) {
        Button(enabled = !working, onClick = {
            working = true
            failure = null
            scope.launch {
                try {
                    root = AI.mindMap(note.fullText())
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    failure = e.friendly()
                } finally {
                    working = false
                }
            }
        }) { Text(if (root == null) "Make a Mind Map" else "Make Another") }
        Spacer(Modifier.height(16.dp))
        failure?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        if (working) CircularProgressIndicator(Modifier.size(28.dp))
        root?.let { map ->
            Text(map.title, fontFamily = FontFamily.Serif, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(12.dp))
            map.children.orEmpty().forEach { branch ->
                Card(Modifier.fillMaxWidth().padding(vertical = 5.dp)) {
                    Column(Modifier.padding(14.dp)) {
                        Text(branch.title, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.primary)
                        branch.children.orEmpty().forEach { leaf -> Text("\u2022 " + leaf.title, Modifier.padding(start = 8.dp, top = 4.dp)) }
                    }
                }
            }
        }
    }
}

@Composable
private fun ExplainTab(note: Note) {
    val scope = rememberCoroutineScope()
    var answer by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize().padding(16.dp).verticalScroll(rememberScrollState())) {
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            AskMode.entries.forEach { mode ->
                OutlinedButton(enabled = !working, onClick = {
                    working = true
                    failure = null
                    answer = ""
                    scope.launch {
                        try {
                            answer = AI.ask(mode, note.fullText()) { answer = it }
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            failure = e.friendly()
                        } finally {
                            working = false
                        }
                    }
                }) { Text(mode.title) }
            }
        }
        Spacer(Modifier.height(12.dp))
        failure?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        if (working && answer.isEmpty()) CircularProgressIndicator(Modifier.size(28.dp))
        SelectionContainer { Text(answer) }
    }
}

@Composable
private fun TeachBackTab(note: Note) {
    val scope = rememberCoroutineScope()
    var explanation by remember { mutableStateOf("") }
    var answer by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize().padding(16.dp).verticalScroll(rememberScrollState())) {
        Text("Explain the topic in your own words. Margin checks it against your notes.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(explanation, { explanation = it }, minLines = 4, modifier = Modifier.fillMaxWidth(), placeholder = { Text("My explanation") })
        Spacer(Modifier.height(8.dp))
        Button(enabled = !working && explanation.isNotBlank(), onClick = {
            working = true
            failure = null
            answer = ""
            scope.launch {
                try {
                    answer = AI.reviewExplanation(explanation, note.fullText()) { answer = it }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    failure = e.friendly()
                } finally {
                    working = false
                }
            }
        }) { Text("Check My Explanation") }
        Spacer(Modifier.height(12.dp))
        failure?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        if (working && answer.isEmpty()) CircularProgressIndicator(Modifier.size(28.dp))
        SelectionContainer { Text(answer) }
    }
}

/** Spaced review. `cards` names one note to go through in full; null means everything due across the library. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReviewScreen(cards: String?, onClose: () -> Unit) {
    val queue = remember {
        mutableStateListOf<Pair<String, String>>().apply {
            if (cards != null) addAll(Library.note(cards)?.flashcards.orEmpty().map { cards to it.id })
            else addAll(Library.dueCards().map { it.first.id to it.second.id })
        }
    }
    var showBack by remember { mutableStateOf(false) }
    val notes by Library.notes.collectAsState()
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Review") },
                navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            )
        },
    ) { padding ->
        val current = queue.firstOrNull()
        val card = current?.let { (noteId, cardId) -> notes.firstOrNull { it.id == noteId }?.flashcards?.firstOrNull { it.id == cardId } }
        Column(Modifier.padding(padding).fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            if (card == null || current == null) {
                Text("All done for now.", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(16.dp))
                OutlinedButton(onClick = onClose) { Text("Close") }
                return@Column
            }
            Text("${queue.size} left", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(12.dp))
            Card(onClick = { showBack = true }, modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(24.dp)) {
                    Text(card.front, style = MaterialTheme.typography.titleLarge)
                    if (showBack) {
                        Spacer(Modifier.height(16.dp))
                        Text(card.back, style = MaterialTheme.typography.bodyLarge)
                    } else {
                        Spacer(Modifier.height(16.dp))
                        Text("Tap to show the answer", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
            if (showBack) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SM2.Grade.entries.forEach { grade ->
                        OutlinedButton(onClick = {
                            val (noteId, cardId) = current
                            val existing = Library.note(noteId)?.flashcards.orEmpty()
                            Library.setCards(noteId, existing.map { if (it.id == cardId) it.applying(grade) else it })
                            queue.removeAt(0)
                            showBack = false
                        }) { Text(grade.title) }
                    }
                }
            }
        }
    }
}
