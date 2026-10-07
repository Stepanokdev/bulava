package com.stepanok.bulava

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.backhandler.BackHandler
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.stepanok.bulava.link.LinkState
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.decisions_sent
import com.stepanok.bulava.resources.notice_failed
import com.stepanok.bulava.resources.notice_failed_plain
import com.stepanok.bulava.resources.notice_not_on_phone
import com.stepanok.bulava.resources.notice_offline
import com.stepanok.bulava.resources.notice_stale
import com.stepanok.bulava.resources.notice_too_large
import com.stepanok.bulava.resources.copied
import com.stepanok.bulava.resources.report_pdf_failed
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.ui.main.MainScreen
import com.stepanok.bulava.ui.main.Selection
import com.stepanok.bulava.ui.media.ImageScreen
import com.stepanok.bulava.ui.onboarding.OnboardingScreen
import com.stepanok.bulava.ui.report.ReportScreen
import com.stepanok.bulava.ui.settings.SettingsScreen
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.BulavaTheme
import org.jetbrains.compose.resources.getString
import kotlinx.coroutines.flow.collectLatest

/** Where the app is, above the conversation itself. */
sealed interface Screen {
    data object Settings : Screen
    data class ReportView(val target: String, val title: String) : Screen
    data class ImageView(val ref: String, val name: String) : Screen
    data class ContextView(val productID: String, val chatID: String?, val title: String) : Screen
    data class DiffView(val ref: String, val title: String) : Screen
    data class SkillsView(val productID: String?) : Screen
}

/**
 * One session's screens: the real Mac's, or the demo's. [onTryDemo] is offered on the first screen
 * of an unpaired phone; [onExitDemo] is set when this is the demo, and replaces unpairing.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun App(controller: AppController, onTryDemo: (() -> Unit)? = null, onExitDemo: (() -> Unit)? = null) {
    BulavaTheme {
        val state by controller.link.state.collectAsState()
        val stack = remember { mutableStateListOf<Screen>() }
        val selection = remember { Selection(controller) }
        val snackbar = remember { SnackbarHostState() }

        ForegroundTracker(controller)

        LaunchedEffect(Unit) {
            controller.notices.collect { notice ->
                val text = when (notice.kind) {
                    AppController.Notice.Kind.Stale -> getString(Res.string.notice_stale)
                    AppController.Notice.Kind.Offline -> getString(Res.string.notice_offline)
                    AppController.Notice.Kind.NotOnPhone -> getString(Res.string.notice_not_on_phone)
                    AppController.Notice.Kind.TooLarge -> getString(Res.string.notice_too_large)
                    AppController.Notice.Kind.Copied -> getString(Res.string.copied)
                    AppController.Notice.Kind.PdfFailed -> getString(Res.string.report_pdf_failed)
                    AppController.Notice.Kind.DecisionsSent -> getString(Res.string.decisions_sent)
                    AppController.Notice.Kind.Failed -> notice.message?.takeIf { it.isNotBlank() }
                        ?.let { getString(Res.string.notice_failed, it) } ?: getString(Res.string.notice_failed_plain)
                }
                snackbar.showSnackbar(text)
            }
        }
        val focus = LocalFocusManager.current
        // A screen opened over the chat takes the keyboard down with it.
        LaunchedEffect(stack.size) { if (stack.isNotEmpty()) focus.clearFocus(force = true) }
        LaunchedEffect(Unit) {
            // The newest tap wins: one still waiting for the Mac to say where is given up for it.
            controller.openRequests.collectLatest { request ->
                // Whatever was being typed stays in its draft; the keyboard does not follow along.
                focus.clearFocus(force = true)
                // A chat is opened where it is; a report with no chat of its own, in its product's
                // details; the Mac's setup, in the settings. A push from the relay says only what
                // happened, and leads to the newest of it (`AppController.destination`). A task
                // that did not start asks in the dialog that comes up by itself.
                val to = controller.destination(request) ?: return@collectLatest
                stack.clear()
                when (to) {
                    is AppController.Destination.Chat -> selection.open(to.productID, to.chatID)
                    is AppController.Destination.Details -> stack.add(Screen.ContextView(to.productID, null, to.name))
                    AppController.Destination.Settings -> stack.add(Screen.Settings)
                }
            }
        }

        val unpaired = controller.link.paired == null &&
            (state is LinkState.Unpaired || state is LinkState.Pairing || state is LinkState.PairingFailed)

        Box(Modifier.fillMaxSize().background(Bulava.colors.background)) {
            if (unpaired) {
                OnboardingScreen(controller, state, onTryDemo)
            } else {
                MainScreen(
                    controller = controller, selection = selection,
                    onOpenSettings = { stack.add(Screen.Settings) },
                    onOpenReport = { target, title -> stack.add(Screen.ReportView(target, title)) },
                    onOpenImage = { ref, name -> stack.add(Screen.ImageView(ref, name)) },
                    onOpenContext = { productID, chatID, title -> stack.add(Screen.ContextView(productID, chatID, title)) },
                )
                when (val top = stack.lastOrNull()) {
                    Screen.Settings -> SettingsScreen(controller, onBack = { stack.removeLastOrNull() },
                        onOpenSkills = { stack.add(Screen.SkillsView(null)) }, onExitDemo = onExitDemo)
                    is Screen.ContextView -> com.stepanok.bulava.ui.context.ContextScreen(
                        controller, top.productID, top.chatID, top.title, onBack = { stack.removeLastOrNull() },
                        onOpenDiff = { ref, title -> stack.add(Screen.DiffView(ref, title)) },
                        onOpenReport = { target, title -> stack.add(Screen.ReportView(target, title)) },
                        onOpenSkills = { stack.add(Screen.SkillsView(top.productID)) },
                        onCompose = { hint -> stack.clear(); selection.compose(hint) },
                    )
                    is Screen.DiffView -> com.stepanok.bulava.ui.context.DiffScreen(controller, top.ref, top.title, onBack = { stack.removeLastOrNull() })
                    is Screen.SkillsView -> com.stepanok.bulava.ui.skills.SkillsScreen(controller, top.productID, onBack = { stack.removeLastOrNull() })
                    is Screen.ReportView -> ReportScreen(
                        controller, top.target, top.title, onBack = { stack.removeLastOrNull() },
                        onCompose = { hint -> stack.clear(); selection.compose(hint) },
                    )
                    is Screen.ImageView -> ImageScreen(controller, top.ref, top.name, onBack = { stack.removeLastOrNull() })
                    null -> Unit
                }
                // A task that stopped on a question before it started has no chat to ask in; the Mac
                // puts it in a dialog, and so does this.
                com.stepanok.bulava.ui.main.TaskAskDialog(controller)
                // BackHandler is deprecated in favour of NavigationEventHandler, whose common API
                // still needs its own state holder; this one-line use is the stable path in 1.12.
                @Suppress("DEPRECATION")
                BackHandler(enabled = stack.isNotEmpty()) { stack.removeLastOrNull() }
            }
            SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 88.dp)) { data ->
                Snackbar(
                    shape = RoundedCornerShape(10.dp),
                    containerColor = Bulava.colors.text,
                    contentColor = Bulava.colors.background,
                    modifier = Modifier.padding(horizontal = 16.dp),
                ) { Text(data.visuals.message, style = Bulava.type.caption) }
            }
        }
    }
}

/** Tells the controller when the app is on screen, and reconnects at once when it comes back. */
@Composable
private fun ForegroundTracker(controller: AppController) {
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> {
                    controller.inForeground = true
                    controller.link.connect()
                    controller.link.nudge()
                }
                Lifecycle.Event.ON_PAUSE -> controller.inForeground = false
                else -> Unit
            }
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
}
