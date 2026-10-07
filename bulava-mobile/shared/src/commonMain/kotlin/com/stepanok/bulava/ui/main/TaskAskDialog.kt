package com.stepanok.bulava.ui.main

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.stepanok.bulava.link.LinkState
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.ui.components.Eyebrow
import com.stepanok.bulava.ui.components.MacActions
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Metrics

/**
 * A task that stopped on a question before it started — uncommitted work in its folder, MCP servers
 * Claude has to ask about, a folder with no git. It has no chat to ask in, so the Mac asks in a
 * dialog of its own (`DirtyTreePrompts`, `McpPrompts`, the git one in `ContentView`), and this is
 * that dialog on the phone: the Mac's sentence, what it is about, and its buttons, one of which is
 * "Not now". It comes up by itself, like the Mac's, and goes the moment either side answers.
 */
@Composable
fun TaskAskDialog(controller: AppController) {
    val home by controller.home.collectAsState()
    val link by controller.link.state.collectAsState()
    // Only with the Mac here: what the phone kept from before may already be answered, and a dialog
    // whose buttons cannot reach anyone would be one that cannot be closed.
    if (link !is LinkState.Connected) return
    val ask = home?.attention?.firstOrNull { it.chatID == null && it.kind == "ask" && it.actions.isNotEmpty() } ?: return
    val product = home?.products?.firstOrNull { it.id == ask.productID }?.name
    val c = Bulava.colors
    Dialog(
        onDismissRequest = {},
        properties = DialogProperties(dismissOnBackPress = false, dismissOnClickOutside = false),
    ) {
        // Drawn as the question card in a chat is (`QuestionCard`): the same corners, the same
        // orange hairline for "this waits for you", no shadow of its own over the scrim.
        val shape = RoundedCornerShape(Metrics.radiusCard)
        Column(
            Modifier.widthIn(max = 520.dp).fillMaxWidth().clip(shape)
                .border(Metrics.hairline, c.orange.copy(alpha = 0.35f), shape)
                .background(c.surface).verticalScroll(rememberScrollState()).padding(20.dp),
        ) {
            product?.let { Eyebrow(it, color = c.orange) }
            Spacer(Modifier.height(6.dp))
            Text(ask.body, style = Bulava.type.bodyStrong, color = c.text)
            ask.code?.takeIf { it.isNotBlank() }?.let { code ->
                Spacer(Modifier.height(12.dp))
                Box(
                    Modifier.fillMaxWidth().heightIn(max = 200.dp).clip(RoundedCornerShape(Metrics.radiusControl))
                        .background(c.surfaceMuted).verticalScroll(rememberScrollState()).padding(horizontal = 10.dp, vertical = 8.dp),
                ) {
                    // One file to a line, as a code block in the chat: a path broken at its slashes
                    // reads as two files.
                    Text(code, style = Bulava.type.mono.copy(fontSize = Bulava.type.meta.fontSize), color = c.textSecondary,
                        softWrap = false, modifier = Modifier.horizontalScroll(rememberScrollState()))
                }
            }
            Spacer(Modifier.height(16.dp))
            MacActions(ask.actions, onInvoke = { a, input -> controller.invokeNow(a, input) })
        }
    }
}
