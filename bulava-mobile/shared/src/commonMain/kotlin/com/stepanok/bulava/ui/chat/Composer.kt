package com.stepanok.bulava.ui.chat

import com.stepanok.bulava.ui.system.systemClickable
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.link.OptionGroup
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.action_attach
import com.stepanok.bulava.resources.action_send
import com.stepanok.bulava.resources.action_stop
import com.stepanok.bulava.resources.attach_file
import com.stepanok.bulava.resources.attach_photo
import com.stepanok.bulava.resources.composer_archived
import com.stepanok.bulava.resources.composer_offline
import com.stepanok.bulava.resources.composer_placeholder
import com.stepanok.bulava.resources.options_note
import com.stepanok.bulava.resources.options_note_chat
import com.stepanok.bulava.resources.options_title
import com.stepanok.bulava.resources.remove_attachment
import com.stepanok.bulava.resources.uploading
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.ui.components.Eyebrow
import com.stepanok.bulava.ui.main.Selection
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Icons
import com.stepanok.bulava.ui.theme.Metrics
import org.jetbrains.compose.resources.stringResource

/**
 * The field at the bottom, as in any chat app: attach, write, send — or stop what is running.
 * What is typed is kept as a draft for this chat, on the phone, until it is sent.
 */
@Composable
fun Composer(
    controller: AppController,
    productID: String,
    chatID: String,
    archived: Boolean,
    selection: Selection,
    modifier: Modifier = Modifier,
) {
    val c = Bulava.colors
    val drafts by controller.drafts.collectAsState()
    val chats by controller.chats.collectAsState()
    val home by controller.home.collectAsState()
    val uploading by controller.uploading.collectAsState()
    val recording by controller.dictation.recording.collectAsState()
    val notes by controller.dictation.notes.collectAsState()
    val link by controller.link.state.collectAsState()
    val connected = link is com.stepanok.bulava.link.LinkState.Connected
    val draft = drafts[chatID] ?: com.stepanok.bulava.state.Draft()
    val busy = chats[chatID]?.state?.busy == true
    // The chat's own run control from a Mac that keeps one per chat; the Mac's default from an older one.
    val chatComposer = chats[chatID]?.state?.composer
    val composer = chatComposer ?: home?.composer
    val recordingHere = recording?.chatID == chatID
    val transcribing = notes.any { it.chatID == chatID && it.stage != com.stepanok.bulava.state.VoiceNote.Stage.Failed }
    val focus = remember { FocusRequester() }
    val fieldLabel = stringResource(Res.string.composer_placeholder)
    var attachMenu by remember { mutableStateOf(false) }
    var options by remember { mutableStateOf(false) }

    LaunchedEffect(selection.focusPulse) { if (selection.focusPulse > 0) runCatching { focus.requestFocus() } }

    // "/" at the start offers the commands the Mac's composer offers for this product.
    val typing = draft.text.takeIf { it.startsWith("/") && !it.contains(' ') && !it.contains('\n') }
    val commands by androidx.compose.runtime.produceState(emptyList<com.stepanok.bulava.link.Option>(), productID, typing != null, connected) {
        value = if (typing != null && connected && controller.can("commands")) controller.commands(productID) else emptyList()
    }
    val matching = typing?.let { t -> commands.filter { it.id.startsWith(t, ignoreCase = true) }.take(6) }.orEmpty()

    Column(modifier.fillMaxWidth().background(c.background).padding(horizontal = 12.dp, vertical = 8.dp)) {
        AnimatedVisibility(!connected || archived) {
            Text(
                stringResource(if (archived) Res.string.composer_archived else Res.string.composer_offline),
                style = Bulava.type.meta, color = c.textFaint, modifier = Modifier.padding(start = 8.dp, bottom = 6.dp),
            )
        }
        if (matching.isNotEmpty()) {
            Column(
                Modifier.fillMaxWidth().padding(bottom = 8.dp).clip(RoundedCornerShape(Metrics.radiusCard))
                    .background(c.surface).border(1.dp, c.line, RoundedCornerShape(Metrics.radiusCard)),
            ) {
                for (command in matching) {
                    Column(
                        Modifier.fillMaxWidth().systemClickable(role = Role.Button) {
                            controller.setDraft(chatID, draft.copy(text = command.id + " "))
                        }.padding(horizontal = 14.dp, vertical = 10.dp),
                    ) {
                        Text(command.label, style = Bulava.type.callout.copy(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace), color = c.text)
                        command.detail?.takeIf { it.isNotBlank() }?.let {
                            Text(it, style = Bulava.type.meta, color = c.textFaint, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
        }
        Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(c.surface)
                .border(1.dp, c.lineStrong, RoundedCornerShape(22.dp)),
        ) {
            VoiceNotes(controller, chatID)
            if (recordingHere) {
                RecordingBar(controller)
                return@Column
            }
            if (draft.attachments.isNotEmpty() || uploading.isNotEmpty()) {
                Row(
                    Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(start = 12.dp, end = 12.dp, top = 10.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    for (file in draft.attachments) {
                        Row(
                            Modifier.clip(RoundedCornerShape(Metrics.radiusChip)).background(c.surfaceMuted)
                                .padding(start = 10.dp, end = 2.dp, top = 2.dp, bottom = 2.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(if (file.kind == "image") Icons.Image else Icons.Document, null, tint = c.textSecondary, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(file.name, style = Bulava.type.meta, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.widthIn(max = 160.dp))
                            Box(
                                Modifier.size(36.dp).clip(CircleShape).systemClickable(role = Role.Button) { controller.removeAttachment(chatID, file) },
                                contentAlignment = Alignment.Center,
                            ) { Icon(Icons.Close, stringResource(Res.string.remove_attachment), tint = c.textFaint, modifier = Modifier.size(14.dp)) }
                        }
                    }
                    if (uploading.isNotEmpty()) {
                        Row(
                            Modifier.clip(RoundedCornerShape(Metrics.radiusChip)).background(c.surfaceMuted).padding(horizontal = 10.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp, color = c.textFaint)
                            Spacer(Modifier.width(6.dp))
                            Text(stringResource(Res.string.uploading), style = Bulava.type.meta, color = c.textSecondary)
                        }
                    }
                }
            }
            Box(Modifier.fillMaxWidth().heightIn(min = 44.dp, max = 180.dp).padding(start = 16.dp, end = 16.dp, top = 12.dp)) {
                if (draft.text.isEmpty()) {
                    Text(selection.hint ?: stringResource(Res.string.composer_placeholder), style = Bulava.type.body, color = c.textFaint)
                }
                BasicTextField(
                    value = draft.text,
                    onValueChange = { controller.setDraft(chatID, draft.copy(text = it)) },
                    enabled = !archived,
                    textStyle = Bulava.type.body.copy(color = c.text),
                    cursorBrush = SolidColor(c.accent),
                    modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).focusRequester(focus)
                        .semantics { contentDescription = fieldLabel },
                )
            }
            Row(Modifier.fillMaxWidth().padding(horizontal = 6.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                if (controller.can("attachments.upload")) Box {
                    RoundIcon(Icons.Plus, stringResource(Res.string.action_attach), enabled = connected && !archived, filled = false) { attachMenu = true }
                    DropdownMenu(attachMenu, { attachMenu = false }, containerColor = c.surface) {
                        DropdownMenuItem(
                            text = { Text(stringResource(Res.string.attach_photo)) },
                            leadingIcon = { Icon(Icons.Image, null, modifier = Modifier.size(18.dp)) },
                            onClick = {
                                attachMenu = false
                                controller.platform.pickImage { file -> file?.let { controller.attach(chatID, it) } }
                            })
                        DropdownMenuItem(
                            text = { Text(stringResource(Res.string.attach_file)) },
                            leadingIcon = { Icon(Icons.Paperclip, null, modifier = Modifier.size(18.dp)) },
                            onClick = {
                                attachMenu = false
                                controller.platform.pickFile { file -> file?.let { controller.attach(chatID, it) } }
                            })
                    }
                }
                val groups = composer?.groups.orEmpty()
                val pill = composer?.summary
                if (groups.isNotEmpty() && controller.can("settings.models")) {
                    // A Mac that words its pill is shown as the Mac shows it; an older one by its menus.
                    if (!pill.isNullOrEmpty()) RunChip(pill, Modifier.weight(1f)) { options = true }
                    else OptionsChip(groups, Modifier.weight(1f)) { options = true }
                } else {
                    Spacer(Modifier.weight(1f))
                }
                // Recording works without the Mac: the note waits on the phone until it is back.
                if (controller.dictation.recorder != null) {
                    MicButton(controller, productID, chatID, enabled = !archived && recording == null)
                }
                val canSend = connected && !archived && !draft.isEmpty && uploading.isEmpty() && !transcribing
                if (busy && draft.isEmpty) {
                    RoundIcon(Icons.Stop, stringResource(Res.string.action_stop), enabled = connected, filled = true, stop = true) {
                        controller.stop(chatID)
                    }
                } else {
                    RoundIcon(Icons.Send, stringResource(Res.string.action_send), enabled = canSend, filled = true) {
                        controller.send(productID, chatID)
                    }
                }
            }
        }
    }

    if (options) OptionsSheet(controller, composer?.groups.orEmpty(), chatID.takeIf { chatComposer != null }) { options = false }
}

@Composable
private fun RoundIcon(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    description: String,
    enabled: Boolean,
    filled: Boolean,
    stop: Boolean = false,
    onClick: () -> Unit,
) {
    val c = Bulava.colors
    Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
        Box(
            Modifier.size(36.dp).clip(CircleShape)
                .background(
                    when {
                        !filled -> androidx.compose.ui.graphics.Color.Transparent
                        !enabled -> c.surfaceRaised
                        stop -> c.text
                        else -> c.accent
                    },
                )
                .then(if (!filled) Modifier.border(1.dp, c.lineStrong, CircleShape) else Modifier)
                .systemClickable(enabled = enabled, role = Role.Button, onClick = onClick)
                .semantics { contentDescription = description },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                icon, null, modifier = Modifier.size(if (stop) 14.dp else 18.dp),
                tint = when {
                    !filled -> if (enabled) c.text else c.textFaint
                    !enabled -> c.textFaint
                    stop -> c.background
                    else -> c.onAccent
                },
            )
        }
    }
}

/** What the next message runs on, from a Mac older than the pill's own words: each menu's choice in a row. */
@Composable
private fun OptionsChip(groups: List<OptionGroup>, modifier: Modifier, onClick: () -> Unit) {
    val c = Bulava.colors
    val summary = groups.mapNotNull { g -> g.options.firstOrNull { it.id == g.selected }?.label }.joinToString(" · ")
    Row(
        modifier.padding(horizontal = 4.dp).heightIn(min = 40.dp).clip(RoundedCornerShape(Metrics.radiusChip))
            .systemClickable(role = Role.Button, onClick = onClick).padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Tune, null, tint = c.textFaint, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(summary, style = Bulava.type.meta, color = c.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun OptionsSheet(controller: AppController, groups: List<OptionGroup>, chatID: String?, onDismiss: () -> Unit) {
    val c = Bulava.colors
    @Suppress("DEPRECATION") // the replacement is not in material3 1.12 alpha for common code yet
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet, containerColor = c.background) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 16.dp)) {
            Text(stringResource(Res.string.options_title), style = Bulava.type.headline, color = c.text,
                modifier = Modifier.padding(horizontal = Metrics.gutter))
            Text(stringResource(if (chatID != null) Res.string.options_note_chat else Res.string.options_note),
                style = Bulava.type.meta, color = c.textFaint,
                modifier = Modifier.padding(horizontal = Metrics.gutter, vertical = 4.dp))
            if (groups.any { it.engine != null }) {
                Spacer(Modifier.height(8.dp))
                RunPanel(controller, groups, chatID)
                return@Column
            }
            for (group in groups) {
                Eyebrow(group.title, Modifier.padding(start = Metrics.gutter, end = Metrics.gutter, top = 20.dp, bottom = 6.dp))
                for (option in group.options) {
                    val selected = option.id == group.selected
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = Metrics.touch)
                            .systemClickable(role = Role.RadioButton) { if (!selected) controller.setOption(group.id, option.id, chatID) }
                            .padding(horizontal = Metrics.gutter, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(option.label, style = Bulava.type.callout.copy(fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal),
                                color = if (selected) c.accentEmphasis else c.text)
                            option.detail?.takeIf { it.isNotBlank() }?.let { Text(it, style = Bulava.type.meta, color = c.textFaint) }
                        }
                        if (selected) Icon(Icons.Check, null, tint = c.accent, modifier = Modifier.size(18.dp))
                    }
                }
            }
        }
    }
}
