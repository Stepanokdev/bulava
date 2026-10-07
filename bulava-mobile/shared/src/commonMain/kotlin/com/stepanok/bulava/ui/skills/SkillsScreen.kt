package com.stepanok.bulava.ui.skills

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.link.Skills
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.health_connected
import com.stepanok.bulava.resources.health_failed
import com.stepanok.bulava.resources.health_needs_auth
import com.stepanok.bulava.resources.health_unknown
import com.stepanok.bulava.resources.scope_global
import com.stepanok.bulava.resources.scope_plugin
import com.stepanok.bulava.resources.scope_project
import com.stepanok.bulava.resources.servers_none
import com.stepanok.bulava.resources.servers_section
import com.stepanok.bulava.resources.skills_count
import com.stepanok.bulava.resources.skills_counting
import com.stepanok.bulava.resources.skills_none
import com.stepanok.bulava.resources.skills_section
import com.stepanok.bulava.resources.skills_title
import com.stepanok.bulava.resources.skills_uses
import com.stepanok.bulava.resources.skills_uses_here
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.ui.components.BulavaButton
import com.stepanok.bulava.ui.components.ButtonKind
import com.stepanok.bulava.ui.components.MacActions
import com.stepanok.bulava.ui.components.SectionHeader
import com.stepanok.bulava.ui.components.StatusDot
import com.stepanok.bulava.ui.components.ScreenBar
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Metrics
import kotlinx.coroutines.launch
import org.jetbrains.compose.resources.stringResource

/**
 * The skills installed on the Mac (for one product, or all of them) and the MCP servers Claude
 * can reach — the Mac's Skills screen. Counting uses reads every transcript and takes a while, so
 * it is asked for, not done on opening.
 */
@Composable
fun SkillsScreen(controller: AppController, productID: String?, onBack: () -> Unit) {
    val c = Bulava.colors
    var data by remember { mutableStateOf<Skills?>(null) }
    var full by remember { mutableStateOf(false) }
    var counting by remember { mutableStateOf(false) }
    var reload by remember { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(productID, full, reload) {
        counting = full
        controller.skills(productID, full)?.let { data = it }
        counting = false
    }
    Column(Modifier.fillMaxSize().background(c.background).statusBarsPadding()) {
        ScreenBar(stringResource(Res.string.skills_title), onBack)
        val d = data
        if (d == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp, color = c.accent)
            }
            return@Column
        }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 24.dp)) {
            SectionHeader(stringResource(Res.string.skills_section))
            if (d.skills.isEmpty()) {
                Text(stringResource(Res.string.skills_none), style = Bulava.type.caption, color = c.textFaint,
                    modifier = Modifier.padding(horizontal = Metrics.gutter))
            }
            for (skill in d.skills) {
                Column(Modifier.fillMaxWidth().padding(horizontal = Metrics.gutter, vertical = 8.dp)) {
                    Text(skill.name, style = Bulava.type.bodyStrong, color = c.text)
                    val scopeLabel = when (skill.scope) {
                        "project" -> stringResource(Res.string.scope_project)
                        "plugin" -> stringResource(Res.string.scope_plugin)
                        else -> stringResource(Res.string.scope_global)
                    }
                    Text(listOfNotNull(
                        scopeLabel,
                        if (d.counted) stringResource(Res.string.skills_uses, skill.uses) else null,
                        skill.usesHere?.let { stringResource(Res.string.skills_uses_here, it) },
                        skill.lastUsed,
                    ).joinToString(" · "), style = Bulava.type.meta, color = c.textFaint)
                    if (skill.description.isNotBlank()) {
                        Text(skill.description, style = Bulava.type.caption, color = c.textSecondary, maxLines = 3)
                    }
                    if (skill.actions.isNotEmpty()) {
                        MacActions(skill.actions, onInvoke = { a, input ->
                            controller.invokeNow(a, input).also { if (it) reload++ }
                        }, enabled = controller.link.isConnected, modifier = Modifier.padding(top = 6.dp))
                    }
                }
            }
            if (!d.counted) {
                Row(Modifier.padding(horizontal = Metrics.gutter, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (counting) {
                        CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 1.5.dp, color = c.textFaint)
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(Res.string.skills_counting), style = Bulava.type.meta, color = c.textFaint)
                    } else {
                        BulavaButton(stringResource(Res.string.skills_count), { full = true }, kind = ButtonKind.Secondary)
                    }
                }
            }

            SectionHeader(stringResource(Res.string.servers_section))
            if (d.servers.isEmpty()) {
                Text(stringResource(Res.string.servers_none), style = Bulava.type.caption, color = c.textFaint,
                    modifier = Modifier.padding(horizontal = Metrics.gutter))
            }
            for (server in d.servers) {
                Row(Modifier.fillMaxWidth().padding(horizontal = Metrics.gutter, vertical = 8.dp), verticalAlignment = Alignment.Top) {
                    StatusDot(when (server.health) { "connected" -> "good"; "failed" -> "problem"; "needs_auth" -> "attention"; else -> "neutral" },
                        Modifier.padding(top = 7.dp), size = 7.dp)
                    Spacer(Modifier.width(10.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(server.name, style = Bulava.type.bodyStrong, color = c.text)
                        Text(listOfNotNull(
                            when (server.health) {
                                "connected" -> stringResource(Res.string.health_connected)
                                "failed" -> stringResource(Res.string.health_failed)
                                "needs_auth" -> stringResource(Res.string.health_needs_auth)
                                else -> stringResource(Res.string.health_unknown)
                            },
                            server.transport.ifBlank { null }, server.scope.ifBlank { null },
                            if (d.counted) stringResource(Res.string.skills_uses, server.uses) else null,
                        ).joinToString(" · "), style = Bulava.type.meta, color = c.textFaint)
                        if (server.description.isNotBlank()) Text(server.description, style = Bulava.type.caption, color = c.textSecondary, maxLines = 3)
                        if (server.target.isNotBlank()) Text(server.target, style = Bulava.type.mono.copy(fontSize = Bulava.type.meta.fontSize), color = c.textFaint, maxLines = 1)
                    }
                }
            }
        }
    }
}
