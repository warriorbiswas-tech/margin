package com.warriorbiswas.margin

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(onClose: () -> Unit) {
    val context = LocalContext.current
    var style by remember { mutableStateOf(Prefs.paperStyle(context)) }
    var color by remember { mutableStateOf(Prefs.paperColor(context)) }
    var size by remember { mutableStateOf(Prefs.pageSize(context)) }
    var fingerDraws by remember { mutableStateOf(Prefs.fingerDraws(context)) }
    var scratch by remember { mutableStateOf(Prefs.scribbleErase(context)) }
    var shapes by remember { mutableStateOf(Prefs.holdForShapes(context)) }
    var eraserReturns by remember { mutableStateOf(Prefs.eraserReturns(context)) }
    var tilt by remember { mutableStateOf(Prefs.tiltPressure(context)) }
    var strength by remember { mutableStateOf(Prefs.tiltStrength(context)) }
    val storedKey by CloudKey.stored.collectAsState()
    var key by remember { mutableStateOf(storedKey.orEmpty()) }
    val model by ModelDownloads.state.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            )
        },
    ) { padding ->
        Column(
            Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 8.dp).widthIn(max = 640.dp),
        ) {
            Heading("New Notes")
            ChoiceRow("Paper", PaperStyle.entries, style, { it.title }) {
                style = it
                Prefs.set(context, "defaultPaper", it.name)
            }
            ChoiceRow("Color", PaperColor.entries, color, { it.title }) {
                color = it
                Prefs.set(context, "defaultColor", it.name)
            }
            ChoiceRow("Size", PageSize.entries, size, { it.title }) {
                size = it
                Prefs.set(context, "defaultSize", it.name)
            }
            Divider()

            Heading("Writing")
            Toggle("Draw with Finger", fingerDraws) {
                fingerDraws = it
                Prefs.set(context, "fingerDraws", it)
            }
            Caption(if (fingerDraws) "One finger writes and two fingers scroll or zoom." else "A finger scrolls, and only a stylus writes.")
            Toggle("Scratch Out to Delete", scratch) {
                scratch = it
                Prefs.set(context, "scribbleErase", it)
            }
            Toggle("Hold to Draw Shapes", shapes) {
                shapes = it
                Prefs.set(context, "holdForShapes", it)
            }
            Toggle("Switch Back After Erasing", eraserReturns) {
                eraserReturns = it
                Prefs.set(context, "eraserReturns", it)
            }
            Toggle("Tilt for Pressure", tilt) {
                tilt = it
                Prefs.set(context, "tiltPressure", it)
            }
            if (tilt) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Strength", Modifier.padding(end = 12.dp))
                    Slider(strength, {
                        strength = it
                        Prefs.set(context, "tiltStrength", it)
                    }, valueRange = 0.2f..1f)
                }
                Caption("Lean the stylus over for a thicker line, or hold it upright for a thinner one. This only works with a stylus that reports its tilt.")
            }
            Divider()

            Heading("AI")
            OutlinedTextField(
                value = key,
                onValueChange = {
                    key = it
                    CloudKey.save(context, it)
                },
                label = { Text("NVIDIA API Key") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
                modifier = Modifier.fillMaxWidth(),
            )
            Caption("With a key, chat, summaries and study tools use NVIDIA's model first, and your question and the notes it needs are sent to NVIDIA. Without one, or whenever NVIDIA can't answer, the model on this device answers instead. The key is encrypted and stays on this device.")
            Spacer(Modifier.height(12.dp))
            Text("Writing Model", style = MaterialTheme.typography.titleSmall)
            when (val state = model) {
                ModelDownloads.State.Absent -> {
                    Caption("Qwen3 1.7B, 1.1 GB. Runs on this device with no key. Needs 4 GB of memory or more; a lot of it helps.")
                    OutlinedButton(onClick = { ModelDownloads.download() }) { Text("Download (1.1 GB)") }
                }
                is ModelDownloads.State.Downloading -> {
                    Caption("Downloading, ${(state.progress * 100).toInt()}%. You can leave this screen.")
                    LinearProgressIndicator({ state.progress }, Modifier.fillMaxWidth())
                }
                ModelDownloads.State.Verifying -> {
                    Caption("Checking the download.")
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                }
                ModelDownloads.State.Installed -> {
                    Caption("Installed. Questions are answered on this device whenever NVIDIA isn't used.")
                    OutlinedButton(onClick = { ModelDownloads.remove() }) { Text("Remove Model") }
                }
                is ModelDownloads.State.Failed -> {
                    Caption(state.message)
                    OutlinedButton(onClick = { ModelDownloads.download() }) { Text("Try Again") }
                }
            }
            Divider()

            Heading("About")
            Caption("Margin ${context.packageManager.getPackageInfo(context.packageName, 0).versionName}. Notes stay on this device, and in your own Google backup if you have that on. The on-device model is open source and runs with llama.cpp (MIT License).")
            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
private fun Heading(text: String) = Text(text, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 12.dp, bottom = 4.dp), fontFamily = androidx.compose.ui.text.font.FontFamily.Serif)

@Composable
private fun Caption(text: String) = Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 4.dp))

@Composable
private fun Divider() = HorizontalDivider(Modifier.padding(vertical = 12.dp))

@Composable
private fun Toggle(label: String, value: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        Switch(value, onChange)
    }
}
