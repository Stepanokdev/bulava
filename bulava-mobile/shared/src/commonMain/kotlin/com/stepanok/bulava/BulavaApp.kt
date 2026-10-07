package com.stepanok.bulava

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.intl.Locale
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.demo.DemoSession
import com.stepanok.bulava.link.LinkState
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.demo_badge
import com.stepanok.bulava.resources.demo_bar
import com.stepanok.bulava.resources.demo_exit
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.ui.components.Hairline
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.BulavaTheme
import org.jetbrains.compose.resources.stringResource
import kotlin.time.Clock

/**
 * The app as each platform starts it: the real session, and — when someone tries Bulava without
 * a Mac — the demo in its place, under a bar that says so and leads back out.
 *
 * The real controller keeps running under the demo. A pairing link or a tapped notification is
 * about the real Mac, so either one ends the demo and is handled there.
 */
@Composable
fun BulavaApp(real: AppController) {
    var demo by remember { mutableStateOf<DemoSession?>(null) }
    val language = Locale.current.language

    fun exitDemo() {
        demo?.close()
        demo = null
    }

    LaunchedEffect(real) { real.link.state.collect { if (it is LinkState.Pairing) exitDemo() } }
    LaunchedEffect(real) { real.openRequests.collect { exitDemo() } }
    DisposableEffect(Unit) { onDispose { demo?.close() } }

    val session = demo
    if (session == null) {
        App(real, onTryDemo = { demo = DemoSession.start(real.platform, language) { Clock.System.now().toEpochMilliseconds() } })
        return
    }
    key(session) {
        // The demo's own link can only come undone by being left; its onboarding is never shown.
        LaunchedEffect(session) { session.controller.link.state.collect { if (it is LinkState.Unpaired) exitDemo() } }
        BulavaTheme {
            Column(Modifier.fillMaxSize().background(Bulava.colors.background)) {
                DemoBar(onExit = ::exitDemo)
                Box(Modifier.weight(1f).consumeWindowInsets(WindowInsets.statusBars)) {
                    App(session.controller, onExitDemo = ::exitDemo)
                }
            }
        }
    }
}

/** Above every screen of the demo, so it is never mistaken for a real Mac's work. */
@Composable
private fun DemoBar(onExit: () -> Unit) {
    val c = Bulava.colors
    Column(Modifier.fillMaxWidth().background(c.surfaceMuted)) {
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().heightIn(min = 44.dp).padding(start = 16.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                stringResource(Res.string.demo_badge),
                style = Bulava.type.eyebrow, color = c.accentEmphasis,
                modifier = Modifier.clip(RoundedCornerShape(6.dp)).background(c.accentSoft)
                    .padding(horizontal = 8.dp, vertical = 3.dp).semantics { heading() },
            )
            Spacer(Modifier.width(10.dp))
            Text(stringResource(Res.string.demo_bar), style = Bulava.type.meta, color = c.textSecondary,
                modifier = Modifier.weight(1f), maxLines = 2)
            TextButton(onClick = onExit, modifier = Modifier.heightIn(min = 44.dp)) {
                Text(stringResource(Res.string.demo_exit), style = Bulava.type.caption, color = c.accentEmphasis)
            }
        }
        Hairline()
    }
}
