package com.stepanok.bulava.ui.context

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.diff_empty
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.ui.components.ScreenBar
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.BulavaColors
import org.jetbrains.compose.resources.stringResource

/** One file's diff, as the Mac's inspector shows it: added lines green, removed lines red. */
@Composable
fun DiffScreen(controller: AppController, ref: String, title: String, onBack: () -> Unit) {
    val c = Bulava.colors
    val text by produceState<String?>(null, ref) { value = controller.diff(ref) ?: "" }
    Column(Modifier.fillMaxSize().background(c.background).statusBarsPadding()) {
        ScreenBar(title.substringAfterLast('/'), onBack)
        when (val t = text) {
            null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp, color = c.accent)
            }
            "" -> Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
                Text(stringResource(Res.string.diff_empty), style = Bulava.type.callout, color = c.textSecondary)
            }
            else -> Box(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).horizontalScroll(rememberScrollState())
                .navigationBarsPadding().padding(16.dp)) {
                Text(colour(t, c), style = Bulava.type.mono.copy(fontSize = Bulava.type.meta.fontSize), softWrap = false)
            }
        }
    }
}

private fun colour(diff: String, c: BulavaColors): AnnotatedString = buildAnnotatedString {
    for (line in diff.lineSequence()) {
        val color = when {
            line.startsWith("+++") || line.startsWith("---") -> c.textFaint
            line.startsWith("+") -> c.green
            line.startsWith("-") -> c.red
            line.startsWith("@@") -> c.blue
            else -> c.textSecondary
        }
        withStyle(SpanStyle(color = color)) { append(line) }
        append('\n')
    }
}
