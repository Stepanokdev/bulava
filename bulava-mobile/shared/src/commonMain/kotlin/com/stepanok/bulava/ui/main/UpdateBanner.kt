package com.stepanok.bulava.ui.main

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.action_not_now
import com.stepanok.bulava.resources.action_retry_now
import com.stepanok.bulava.resources.action_update_android
import com.stepanok.bulava.resources.action_update_ios
import com.stepanok.bulava.resources.update_available_body
import com.stepanok.bulava.resources.update_available_title
import com.stepanok.bulava.resources.update_keep_reading
import com.stepanok.bulava.resources.update_mac_body
import com.stepanok.bulava.resources.update_mac_title
import com.stepanok.bulava.resources.update_phone_body
import com.stepanok.bulava.resources.update_phone_title
import com.stepanok.bulava.resources.update_version_phone
import com.stepanok.bulava.resources.update_versions_mac
import com.stepanok.bulava.resources.update_versions_phone
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.state.UpdateNotice
import com.stepanok.bulava.state.Updates
import com.stepanok.bulava.ui.components.BulavaButton
import com.stepanok.bulava.ui.components.ButtonKind
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Icons
import org.jetbrains.compose.resources.stringResource

/**
 * The banner about versions, at the top of the main screen, under the bar. It names the device to
 * update — this phone or the Mac, by its name — says what each has and what is needed, and gives
 * the way to do it. The screen under it keeps working: the chats already here stay readable, and
 * drafts stay where they were.
 *
 * "One side is too old" stays until it is fixed; "a newer app is out" can be put off, and is put
 * off for that build only — the next release asks again.
 */
@Composable
internal fun UpdateBanner(controller: AppController) {
    val link by controller.link.state.collectAsState()
    val home by controller.home.collectAsState()
    val platform = controller.platform
    var dismissed by remember { mutableStateOf(platform.prefs.get(Updates.DISMISSED)?.toIntOrNull()) }
    // Read once: what is installed does not change while the app runs.
    val installed = remember { platform.appVersion() }
    val build = remember { platform.appBuild() }
    val notice = Updates.decide(link, home, platform.platformName, installed, build, dismissed)
    val ios = platform.platformName == "ios"
    val updateLabel = stringResource(if (ios) Res.string.action_update_ios else Res.string.action_update_android)

    AnimatedVisibility(visible = notice != null) {
        when (notice) {
            is UpdateNotice.PhoneTooOld -> Banner(
                title = stringResource(Res.string.update_phone_title),
                lines = listOfNotNull(
                    stringResource(Res.string.update_phone_body, notice.macName),
                    notice.newest?.let { stringResource(Res.string.update_versions_phone, notice.installed, it) }
                        ?: stringResource(Res.string.update_version_phone, notice.installed),
                    stringResource(Res.string.update_keep_reading),
                ),
                urgent = true,
                primary = updateLabel to { platform.openUrl(notice.url) },
            )
            is UpdateNotice.MacTooOld -> Banner(
                title = stringResource(Res.string.update_mac_title, notice.macName),
                lines = listOfNotNull(
                    stringResource(Res.string.update_mac_body),
                    notice.macVersion?.takeIf { it.isNotBlank() }?.let { stringResource(Res.string.update_versions_mac, it, notice.installed) },
                    stringResource(Res.string.update_keep_reading),
                ),
                urgent = true,
                // Once it is updated there, the phone need not wait out its minute to find out.
                primary = stringResource(Res.string.action_retry_now) to { controller.link.nudge() },
                icon = Icons.Laptop,
            )
            is UpdateNotice.Available -> Banner(
                title = stringResource(Res.string.update_available_title, notice.newest.version),
                lines = listOf(stringResource(Res.string.update_available_body, notice.installed)),
                urgent = false,
                primary = updateLabel to { platform.openUrl(notice.newest.url) },
                dismiss = stringResource(Res.string.action_not_now) to {
                    platform.prefs.put(Updates.DISMISSED, notice.newest.build.toString())
                    dismissed = notice.newest.build
                },
            )
            null -> Unit
        }
    }
}

@Composable
private fun Banner(
    title: String,
    lines: List<String>,
    urgent: Boolean,
    primary: Pair<String, () -> Unit>?,
    dismiss: Pair<String, () -> Unit>? = null,
    icon: androidx.compose.ui.graphics.vector.ImageVector = Icons.Download,
) {
    val c = Bulava.colors
    Column(
        Modifier.fillMaxWidth().testTag(UpdateTags.BANNER).background(if (urgent) c.orangeSoft else c.accentSoft)
            .padding(start = 16.dp, end = 12.dp, top = 10.dp, bottom = if (primary != null || dismiss != null) 4.dp else 10.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Icon(icon, null, tint = if (urgent) c.orange else c.accentEmphasis, modifier = Modifier.padding(top = 1.dp).size(18.dp))
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(title, style = Bulava.type.caption.copy(fontWeight = FontWeight.Medium), color = c.text,
                    modifier = Modifier.semantics { heading() })
                for (line in lines) Text(line, style = Bulava.type.meta, color = c.textSecondary)
            }
        }
        if (primary != null || dismiss != null) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                dismiss?.let { (label, action) ->
                    BulavaButton(label, action, kind = ButtonKind.Quiet, modifier = Modifier.testTag(UpdateTags.NOT_NOW))
                }
                primary?.let { (label, action) ->
                    BulavaButton(label, action, kind = ButtonKind.Quiet, modifier = Modifier.testTag(UpdateTags.UPDATE))
                }
            }
        }
    }
}

object UpdateTags {
    const val BANNER = "update.banner"
    const val UPDATE = "update.open"
    const val NOT_NOW = "update.notNow"
}
