package com.stepanok.bulava.ui.onboarding

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.link.ErrorCodes
import com.stepanok.bulava.link.LinkProtocol
import com.stepanok.bulava.link.LinkState
import com.stepanok.bulava.link.PairingCode
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.action_cancel
import com.stepanok.bulava.resources.action_get_mac_app
import com.stepanok.bulava.resources.action_pair
import com.stepanok.bulava.resources.action_paste_link
import com.stepanok.bulava.resources.action_scan
import com.stepanok.bulava.resources.action_scan_again
import com.stepanok.bulava.resources.action_try_again
import com.stepanok.bulava.resources.demo_try
import com.stepanok.bulava.resources.onboarding_lede
import com.stepanok.bulava.resources.onboarding_title
import com.stepanok.bulava.resources.pairing_failed_title
import com.stepanok.bulava.resources.pairing_unreachable_body
import com.stepanok.bulava.resources.pairing_unreachable_title
import com.stepanok.bulava.resources.pairing_with
import com.stepanok.bulava.resources.paste_body
import com.stepanok.bulava.resources.paste_hint
import com.stepanok.bulava.resources.paste_invalid
import com.stepanok.bulava.resources.paste_title
import com.stepanok.bulava.resources.step_install_body
import com.stepanok.bulava.resources.step_install_title
import com.stepanok.bulava.resources.step_scan_body
import com.stepanok.bulava.resources.step_scan_title
import com.stepanok.bulava.resources.step_wifi_body
import com.stepanok.bulava.resources.step_wifi_title
import com.stepanok.bulava.resources.unpaired_notice_title
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.ui.components.BrandTile
import com.stepanok.bulava.ui.components.BulavaButton
import com.stepanok.bulava.ui.components.BulavaTextField
import com.stepanok.bulava.ui.components.ButtonKind
import com.stepanok.bulava.ui.components.Card
import com.stepanok.bulava.ui.components.Hairline
import com.stepanok.bulava.ui.components.dismissKeyboardOnTapOrDrag
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Icons
import com.stepanok.bulava.ui.theme.Metrics
import org.jetbrains.compose.resources.stringResource

/**
 * The first screen of an unpaired phone, and the pairing itself.
 *
 * It says the three things in the order they have to happen — Bulava on the Mac, the same Wi‑Fi,
 * the code — BEFORE the camera opens, so a failure afterwards is recognisable as one of them.
 */
@Composable
fun OnboardingScreen(controller: AppController, state: LinkState, onTryDemo: (() -> Unit)? = null) {
    var lastCode by remember { mutableStateOf<PairingCode?>(null) }
    var pasting by remember { mutableStateOf(false) }

    fun pair(code: PairingCode) {
        lastCode = code
        controller.link.pair(code)
    }

    fun scan() {
        controller.platform.scanCode { text ->
            if (text == null) return@scanCode
            val code = controller.link.parse(text)
            if (code != null) pair(code) else pasting = true
        }
    }

    AnimatedContent(
        targetState = when (state) {
            is LinkState.Pairing -> "pairing"
            is LinkState.PairingFailed -> "failed"
            else -> if (pasting) "paste" else "intro"
        },
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        modifier = Modifier.fillMaxSize(),
    ) { page ->
        when (page) {
            "pairing" -> Pairing((state as? LinkState.Pairing)?.macName ?: lastCode?.n ?: "") {
                controller.link.cancelPairing()
            }
            "failed" -> {
                val failed = state as? LinkState.PairingFailed
                Failed(
                    failed = failed,
                    onRetry = { lastCode?.let { pair(it) } },
                    canRetry = failed?.code == ErrorCodes.OFFLINE && lastCode != null,
                    onScan = { controller.link.cancelPairing(); scan() },
                    onBack = { controller.link.cancelPairing() },
                )
            }
            "paste" -> Paste(
                parse = { controller.link.parse(it) },
                onPair = { pasting = false; pair(it) },
                onCancel = { pasting = false },
            )
            else -> Intro(
                notice = (state as? LinkState.Unpaired)?.notice,
                onScan = { scan() },
                onPaste = { pasting = true },
                onGetMac = { controller.platform.openUrl("https://bulava.app") },
                onTryDemo = onTryDemo,
            )
        }
    }
}

@Composable
private fun Intro(notice: String?, onScan: () -> Unit, onPaste: () -> Unit, onGetMac: () -> Unit, onTryDemo: (() -> Unit)?) {
    val c = Bulava.colors
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 24.dp),
        ) {
            Spacer(Modifier.height(40.dp))
            BrandTile(48.dp)
            Spacer(Modifier.height(28.dp))
            Text(stringResource(Res.string.onboarding_title), style = Bulava.type.display, color = c.text,
                modifier = Modifier.semantics { heading() })
            Spacer(Modifier.height(12.dp))
            Text(stringResource(Res.string.onboarding_lede), style = Bulava.type.body, color = c.textSecondary)

            if (notice != null) {
                Spacer(Modifier.height(20.dp))
                Card(fill = c.orangeSoft, border = c.orangeSoft) {
                    Column(Modifier.padding(16.dp)) {
                        Text(stringResource(Res.string.unpaired_notice_title), style = Bulava.type.bodyStrong, color = c.text)
                        Spacer(Modifier.height(4.dp))
                        Text(notice, style = Bulava.type.caption, color = c.textSecondary)
                    }
                }
            }

            Spacer(Modifier.height(32.dp))
            Step(1, stringResource(Res.string.step_install_title), stringResource(Res.string.step_install_body))
            Hairline(Modifier.padding(start = 48.dp))
            Step(2, stringResource(Res.string.step_wifi_title), stringResource(Res.string.step_wifi_body))
            Hairline(Modifier.padding(start = 48.dp))
            Step(3, stringResource(Res.string.step_scan_title), stringResource(Res.string.step_scan_body))
            Spacer(Modifier.height(24.dp))
        }
        Column(Modifier.padding(horizontal = 24.dp, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            BulavaButton(stringResource(Res.string.action_scan), onScan, Modifier.fillMaxWidth(), icon = Icons.Scan)
            // Without a Mac at hand — someone deciding whether to get one, or reviewing the app —
            // the demo shows the real screens on sample projects.
            if (onTryDemo != null) BulavaButton(stringResource(Res.string.demo_try), onTryDemo, Modifier.fillMaxWidth(), kind = ButtonKind.Secondary)
            BulavaButton(stringResource(Res.string.action_paste_link), onPaste, Modifier.fillMaxWidth(), kind = ButtonKind.Quiet)
            BulavaButton(stringResource(Res.string.action_get_mac_app), onGetMac, Modifier.fillMaxWidth(),
                kind = ButtonKind.Quiet, icon = Icons.External)
        }
    }
}

@Composable
private fun Step(number: Int, title: String, body: String) {
    val c = Bulava.colors
    Row(Modifier.fillMaxWidth().padding(vertical = 16.dp)) {
        Box(
            Modifier.size(32.dp).clip(CircleShape).border(1.dp, c.lineStrong, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text("$number", style = Bulava.type.caption, color = c.textSecondary)
        }
        Spacer(Modifier.size(16.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = Bulava.type.bodyStrong, color = c.text)
            Spacer(Modifier.height(4.dp))
            Text(body, style = Bulava.type.caption, color = c.textSecondary)
        }
    }
}

@Composable
private fun Pairing(macName: String, onCancel: () -> Unit) {
    val c = Bulava.colors
    Column(
        Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        CircularProgressIndicator(color = c.accent, strokeWidth = 2.5.dp, modifier = Modifier.size(32.dp))
        Spacer(Modifier.height(24.dp))
        Text(stringResource(Res.string.pairing_with, macName), style = Bulava.type.headline, color = c.text,
            textAlign = TextAlign.Center)
        Spacer(Modifier.height(32.dp))
        BulavaButton(stringResource(Res.string.action_cancel), onCancel, kind = ButtonKind.Quiet)
    }
}

@Composable
private fun Failed(
    failed: LinkState.PairingFailed?,
    canRetry: Boolean,
    onRetry: () -> Unit,
    onScan: () -> Unit,
    onBack: () -> Unit,
) {
    val c = Bulava.colors
    val unreachable = failed?.code == ErrorCodes.OFFLINE
    Column(
        Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(horizontal = 24.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.Center) {
            Box(Modifier.size(48.dp).clip(CircleShape).background(c.orangeSoft), contentAlignment = Alignment.Center) {
                Icon(if (unreachable) Icons.Wifi else Icons.Warning, null, tint = c.orange, modifier = Modifier.size(24.dp))
            }
            Spacer(Modifier.height(24.dp))
            Text(
                if (unreachable) stringResource(Res.string.pairing_unreachable_title, failed.macName)
                else stringResource(Res.string.pairing_failed_title),
                style = Bulava.type.title, color = c.text, modifier = Modifier.semantics { heading() },
            )
            Spacer(Modifier.height(12.dp))
            Text(
                if (unreachable) stringResource(Res.string.pairing_unreachable_body) else failed?.message.orEmpty(),
                style = Bulava.type.body, color = c.textSecondary,
            )
        }
        Column(Modifier.padding(vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (canRetry) BulavaButton(stringResource(Res.string.action_try_again), onRetry, Modifier.fillMaxWidth(), icon = Icons.Refresh)
            BulavaButton(stringResource(Res.string.action_scan_again), onScan, Modifier.fillMaxWidth(),
                kind = if (canRetry) ButtonKind.Secondary else ButtonKind.Primary, icon = Icons.Scan)
            BulavaButton(stringResource(Res.string.action_cancel), onBack, Modifier.fillMaxWidth(), kind = ButtonKind.Quiet)
        }
    }
}

@Composable
private fun Paste(parse: (String) -> PairingCode?, onPair: (PairingCode) -> Unit, onCancel: () -> Unit) {
    val c = Bulava.colors
    var text by remember { mutableStateOf("") }
    var invalid by remember { mutableStateOf(false) }
    Column(
        Modifier.fillMaxSize().dismissKeyboardOnTapOrDrag().statusBarsPadding().navigationBarsPadding().imePadding()
            .verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).widthIn(max = 560.dp),
    ) {
        Spacer(Modifier.height(40.dp))
        Text(stringResource(Res.string.paste_title), style = Bulava.type.title, color = c.text,
            modifier = Modifier.semantics { heading() })
        Spacer(Modifier.height(12.dp))
        Text(stringResource(Res.string.paste_body), style = Bulava.type.callout, color = c.textSecondary)
        Spacer(Modifier.height(20.dp))
        BulavaTextField(text, { text = it; invalid = false }, stringResource(Res.string.paste_hint), minLines = 3)
        if (invalid) {
            Spacer(Modifier.height(8.dp))
            Text(stringResource(Res.string.paste_invalid), style = Bulava.type.caption, color = c.red)
        }
        Spacer(Modifier.height(20.dp))
        BulavaButton(stringResource(Res.string.action_pair), {
            val code = parse(text)
            if (code == null) invalid = true else onPair(code)
        }, Modifier.fillMaxWidth(), enabled = text.isNotBlank())
        Spacer(Modifier.height(6.dp))
        BulavaButton(stringResource(Res.string.action_cancel), onCancel, Modifier.fillMaxWidth(), kind = ButtonKind.Quiet)
        Spacer(Modifier.height(16.dp))
        Text(LinkProtocol.PAIRING_PAGE, style = Bulava.type.meta, color = c.textFaint)
    }
}
