package com.stepanok.bulava.ui.settings

import com.stepanok.bulava.ui.system.AlertButton
import com.stepanok.bulava.ui.system.SystemAlert
import com.stepanok.bulava.ui.system.SystemSwitch
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.link.LinkState
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.action_cancel
import com.stepanok.bulava.resources.action_turn_on
import com.stepanok.bulava.resources.action_unpair
import com.stepanok.bulava.resources.menu_skills
import com.stepanok.bulava.resources.settings_about
import com.stepanok.bulava.resources.settings_background
import com.stepanok.bulava.resources.settings_background_body
import com.stepanok.bulava.resources.settings_background_ios
import com.stepanok.bulava.resources.settings_mac
import com.stepanok.bulava.resources.settings_mac_version
import com.stepanok.bulava.resources.settings_notifications
import com.stepanok.bulava.resources.settings_notifications_off
import com.stepanok.bulava.resources.settings_notifications_demo
import com.stepanok.bulava.resources.settings_notifications_on
import com.stepanok.bulava.resources.settings_privacy
import com.stepanok.bulava.resources.settings_readiness
import com.stepanok.bulava.resources.settings_readiness_ok
import com.stepanok.bulava.resources.settings_title
import com.stepanok.bulava.resources.settings_unpair
import com.stepanok.bulava.resources.settings_exit_demo
import com.stepanok.bulava.resources.status_connected
import com.stepanok.bulava.resources.status_connecting
import com.stepanok.bulava.resources.status_incompatible
import com.stepanok.bulava.resources.status_offline
import com.stepanok.bulava.resources.unpair_body
import com.stepanok.bulava.resources.unpair_title
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.ui.components.BulavaButton
import com.stepanok.bulava.ui.components.ButtonKind
import com.stepanok.bulava.ui.components.Hairline
import com.stepanok.bulava.ui.components.MacActions
import com.stepanok.bulava.ui.components.SectionHeader
import com.stepanok.bulava.ui.components.StatusDot
import com.stepanok.bulava.ui.components.ScreenBar
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Icons
import com.stepanok.bulava.ui.theme.Metrics
import org.jetbrains.compose.resources.stringResource

@Composable
fun SettingsScreen(controller: AppController, onBack: () -> Unit, onOpenSkills: () -> Unit, onExitDemo: (() -> Unit)? = null) {
    val c = Bulava.colors
    val link by controller.link.state.collectAsState()
    val home by controller.home.collectAsState()
    var unpairing by remember { mutableStateOf(false) }
    var notificationsOn by remember { mutableStateOf(controller.platform.notificationsAllowed()) }
    var background by remember { mutableStateOf(controller.platform.prefs.get(AppController.KEEP_ALIVE) != "off") }
    val mac = controller.link.paired
    val android = controller.platform.platformName == "android"
    val demo = onExitDemo != null

    Column(Modifier.fillMaxSize().background(c.background).statusBarsPadding()) {
        ScreenBar(stringResource(Res.string.settings_title), onBack)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 24.dp)) {
            SectionHeader(stringResource(Res.string.settings_mac))
            Row(Modifier.padding(horizontal = Metrics.gutter), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Laptop, null, tint = c.textSecondary, modifier = Modifier.size(24.dp))
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(mac?.name ?: "", style = Bulava.type.bodyStrong, color = c.text)
                    val (tone, line) = when (val s = link) {
                        is LinkState.Connected -> "good" to (stringResource(Res.string.status_connected, s.desktop.name) +
                            " · " + stringResource(Res.string.settings_mac_version, s.desktop.version))
                        is LinkState.Connecting -> "neutral" to stringResource(Res.string.status_connecting, mac?.name ?: "")
                        is LinkState.Incompatible -> "problem" to (stringResource(Res.string.status_incompatible) + " · " + s.message)
                        else -> "attention" to stringResource(Res.string.status_offline, mac?.name ?: "")
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        StatusDot(tone, size = 6.dp)
                        Spacer(Modifier.width(6.dp))
                        Text(line, style = Bulava.type.meta, color = c.textSecondary)
                    }
                }
            }
            Spacer(Modifier.height(10.dp))
            Text(stringResource(Res.string.settings_privacy), style = Bulava.type.meta, color = c.textFaint,
                modifier = Modifier.padding(horizontal = Metrics.gutter))

            SectionHeader(stringResource(Res.string.settings_notifications))
            // The demo has no Mac to hear from, and asks the phone for nothing on its behalf: what
            // the system grants belongs to the real session.
            if (demo) Text(stringResource(Res.string.settings_notifications_demo), style = Bulava.type.callout, color = c.textSecondary,
                modifier = Modifier.padding(horizontal = Metrics.gutter).testTag(SettingsTags.NOTIFICATIONS_DEMO))
            else Row(Modifier.fillMaxWidth().padding(horizontal = Metrics.gutter), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    stringResource(if (notificationsOn) Res.string.settings_notifications_on else Res.string.settings_notifications_off),
                    style = Bulava.type.callout, color = c.textSecondary, modifier = Modifier.weight(1f),
                )
                if (!notificationsOn) {
                    Spacer(Modifier.width(12.dp))
                    BulavaButton(stringResource(Res.string.action_turn_on), {
                        controller.platform.requestNotifications()
                        notificationsOn = controller.platform.notificationsAllowed()
                    }, kind = ButtonKind.Secondary, modifier = Modifier.testTag(SettingsTags.NOTIFICATIONS_TURN_ON))
                }
            }
            Spacer(Modifier.height(16.dp))
            Hairline(Modifier.padding(horizontal = Metrics.gutter))
            Spacer(Modifier.height(12.dp))
            if (demo) {
                // Nothing to keep running in the background: the demo Mac lives in the app.
            } else if (android) {
                Row(Modifier.fillMaxWidth().padding(horizontal = Metrics.gutter), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(Res.string.settings_background), style = Bulava.type.callout, color = c.text)
                        Text(stringResource(Res.string.settings_background_body), style = Bulava.type.meta, color = c.textFaint)
                    }
                    Spacer(Modifier.width(12.dp))
                    SystemSwitch(
                        checked = background,
                        onCheckedChange = {
                            background = it
                            controller.platform.prefs.put(AppController.KEEP_ALIVE, if (it) "on" else "off")
                            controller.platform.keepLinkAlive(it && controller.link.isConnected, mac?.name ?: "")
                        },
                    )
                }
            } else {
                Text(stringResource(Res.string.settings_background_ios), style = Bulava.type.meta, color = c.textFaint,
                    modifier = Modifier.padding(horizontal = Metrics.gutter))
            }

            val readiness = home?.readiness.orEmpty()
            if (readiness.isNotEmpty()) {
                SectionHeader(stringResource(Res.string.settings_readiness))
                val waiting = readiness.filter { it.state != "ready" }
                if (waiting.isEmpty()) {
                    Text(stringResource(Res.string.settings_readiness_ok), style = Bulava.type.callout, color = c.textSecondary,
                        modifier = Modifier.padding(horizontal = Metrics.gutter))
                }
                for (item in waiting) {
                    Column(Modifier.fillMaxWidth().padding(horizontal = Metrics.gutter, vertical = 10.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            StatusDot(if (item.state == "problem") "problem" else "attention", size = 7.dp)
                            Spacer(Modifier.width(10.dp))
                            Text(item.title, style = Bulava.type.callout, color = c.text)
                        }
                        if (item.detail.isNotBlank()) {
                            Text(item.detail, style = Bulava.type.meta, color = c.textFaint, modifier = Modifier.padding(start = 17.dp, top = 2.dp))
                        }
                        if (item.actions.isNotEmpty()) {
                            Spacer(Modifier.height(8.dp))
                            MacActions(item.actions, onInvoke = { a, input -> controller.invokeNow(a, input) },
                                enabled = link is LinkState.Connected, modifier = Modifier.padding(start = 17.dp))
                        }
                    }
                }
            }

            if (controller.can("skills")) {
                SectionHeader(stringResource(Res.string.menu_skills))
                com.stepanok.bulava.ui.components.ListRow(
                    stringResource(Res.string.menu_skills), modifier = Modifier.padding(horizontal = 4.dp),
                    leading = { Icon(Icons.Tune, null, tint = c.textSecondary, modifier = Modifier.size(20.dp)) },
                    trailing = { Icon(Icons.ChevronRight, null, tint = c.textFaint, modifier = Modifier.size(16.dp)) },
                    onClick = onOpenSkills,
                )
            }

            Spacer(Modifier.height(28.dp))
            // In the demo there is no pairing to undo; the same place leaves the demo.
            if (onExitDemo != null) BulavaButton(stringResource(Res.string.settings_exit_demo), onExitDemo,
                Modifier.padding(horizontal = Metrics.gutter).fillMaxWidth(), kind = ButtonKind.Secondary)
            else BulavaButton(stringResource(Res.string.settings_unpair), { unpairing = true }, Modifier.padding(horizontal = Metrics.gutter).fillMaxWidth(),
                kind = ButtonKind.Destructive)
            Spacer(Modifier.height(16.dp))
            Text(
                stringResource(Res.string.settings_about, if (android) "Android" else "iPhone", controller.platform.appVersion()),
                style = Bulava.type.meta, color = c.textFaint, modifier = Modifier.padding(horizontal = Metrics.gutter),
            )
        }
    }

    if (unpairing) {
        SystemAlert(
            title = stringResource(Res.string.unpair_title, mac?.name ?: ""),
            message = stringResource(Res.string.unpair_body),
            buttons = listOf(
                AlertButton(stringResource(Res.string.action_cancel), AlertButton.Style.Cancel) { unpairing = false },
                AlertButton(stringResource(Res.string.action_unpair), AlertButton.Style.Destructive) {
                    unpairing = false; controller.forget(); onBack()
                },
            ),
            onDismiss = { unpairing = false },
        )
    }
}

/** What tests find the notification controls by. */
object SettingsTags {
    const val NOTIFICATIONS_TURN_ON = "settings.notifications.turnOn"
    const val NOTIFICATIONS_DEMO = "settings.notifications.demo"
}
