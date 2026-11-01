package com.warriorbiswas.margin

import android.content.ComponentCallbacks2
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch

// The iPad's accent, on plain paper-like neutrals. Material would otherwise tint every surface with it.
private val LightColors = lightColorScheme(
    primary = Color(0xFFC8322F),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFF7E1E0),
    onPrimaryContainer = Color(0xFF5A1412),
    secondary = Color(0xFFC8322F),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFF7E1E0),
    onSecondaryContainer = Color(0xFF5A1412),
    tertiary = Color(0xFF6B7A90),
    background = Color(0xFFFAFAF8),
    onBackground = Color(0xFF1C1C1E),
    surface = Color(0xFFFAFAF8),
    onSurface = Color(0xFF1C1C1E),
    surfaceVariant = Color(0xFFEFEFEC),
    onSurfaceVariant = Color(0xFF55555A),
    surfaceTint = Color.Transparent,
    surfaceContainerLowest = Color.White,
    surfaceContainerLow = Color(0xFFF6F6F3),
    surfaceContainer = Color(0xFFF2F2EF),
    surfaceContainerHigh = Color(0xFFF2F2EF),
    surfaceContainerHighest = Color(0xFFEBEBE8),
    outline = Color(0xFF8E8E93),
    outlineVariant = Color(0xFFD8D8D4),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFFFF6B66),
    onPrimary = Color(0xFF3A0A08),
    primaryContainer = Color(0xFF5A1C1A),
    onPrimaryContainer = Color(0xFFFFDAD8),
    secondary = Color(0xFFFF6B66),
    onSecondary = Color(0xFF3A0A08),
    secondaryContainer = Color(0xFF5A1C1A),
    onSecondaryContainer = Color(0xFFFFDAD8),
    tertiary = Color(0xFF9FB0C8),
    background = Color(0xFF161618),
    onBackground = Color(0xFFF2F2F0),
    surface = Color(0xFF161618),
    onSurface = Color(0xFFF2F2F0),
    surfaceVariant = Color(0xFF2B2B2E),
    onSurfaceVariant = Color(0xFFB5B5BA),
    surfaceTint = Color.Transparent,
    surfaceContainerLowest = Color(0xFF111113),
    surfaceContainerLow = Color(0xFF1C1C1E),
    surfaceContainer = Color(0xFF222224),
    surfaceContainerHigh = Color(0xFF222224),
    surfaceContainerHighest = Color(0xFF2B2B2E),
    outline = Color(0xFF7C7C82),
    outlineVariant = Color(0xFF3A3A3D),
)

class MainActivity : ComponentActivity() {
    private var openNote = mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Library.init(this)
        CloudKey.init(this)
        LocalLLM.init(this)
        ModelDownloads.init(this)
        enableEdgeToEdge()
        setContent { MarginRoot(openNote) }
        if (savedInstanceState == null) handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** A PDF opened from another app becomes a new note. */
    private fun handle(intent: Intent?) {
        val uri = intent?.takeIf { it.action == Intent.ACTION_VIEW }?.data ?: return
        lifecycleScope.launch {
            val note = Library.importPdf(uri, null, displayName(uri))
            if (note != null) openNote.value = note.id
            else Toast.makeText(this@MainActivity, "Margin couldn't read that PDF.", Toast.LENGTH_LONG).show()
        }
    }

    private fun displayName(uri: Uri): String? = runCatching {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    }.getOrNull()

    @Suppress("DEPRECATION")
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        // The model is the largest thing in memory by far, and it can always be loaded again.
        if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL) lifecycleScope.launch { LocalLLM.unload() }
    }
}

@Composable
private fun MarginRoot(openNote: androidx.compose.runtime.MutableState<String?>) {
    val dark = isSystemInDarkTheme()
    MaterialTheme(colorScheme = if (dark) DarkColors else LightColors) {
        var settings by rememberSaveable { mutableStateOf(false) }
        var review by rememberSaveable { mutableStateOf(false) }
        val id = openNote.value
        when {
            id != null -> {
                BackHandler { openNote.value = null }
                key(id) { EditorScreen(id, onClose = { openNote.value = null }, onSwitch = { openNote.value = it }) }
            }
            settings -> {
                BackHandler { settings = false }
                SettingsScreen(onClose = { settings = false })
            }
            review -> {
                BackHandler { review = false }
                ReviewScreen(cards = null, onClose = { review = false })
            }
            else -> LibraryScreen(
                onOpen = { openNote.value = it },
                onSettings = { settings = true },
                onReview = { review = true },
            )
        }
    }
}
