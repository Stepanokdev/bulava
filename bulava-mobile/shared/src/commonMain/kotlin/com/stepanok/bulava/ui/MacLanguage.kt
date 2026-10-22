@file:Suppress("INVISIBLE_REFERENCE", "INVISIBLE_MEMBER")

package com.stepanok.bulava.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.text.intl.Locale
import org.jetbrains.compose.resources.ComposeEnvironment
import org.jetbrains.compose.resources.InternalResourceApi
import org.jetbrains.compose.resources.LanguageQualifier
import org.jetbrains.compose.resources.LocalComposeEnvironment
import org.jetbrains.compose.resources.RegionQualifier
import org.jetbrains.compose.resources.ResourceEnvironment
import org.jetbrains.compose.resources.ScriptQualifier

/**
 * The phone's own words in the paired Mac's language.
 *
 * Everything the Mac sends — a chat's status, the limits, a step, an error — is in the Mac's
 * language, and the phone's own labels followed the phone's: "Search chats" over "Ліміти · 4 %
 * ужито", "Opus 5.5 Середня" (22.10). Following the Mac makes one screen one language. Unpaired,
 * or with a language this app has no strings for, it is the phone's own as before.
 *
 * Compose Multiplatform 1.12 has no public way to choose the resources' language at run time
 * (`ResourceEnvironment`'s constructor and `LocalComposeEnvironment` are internal), so this is
 * the one place that reaches for them; an upgrade that breaks it breaks only here.
 */
@OptIn(InternalResourceApi::class)
@Composable
internal fun MacLanguageResources(languageTag: String?, content: @Composable () -> Unit) {
    val inherited = LocalComposeEnvironment.current.rememberEnvironment()
    val locale = remember(languageTag) {
        languageTag?.trim()?.lowercase()?.takeIf { it in SPOKEN }?.let { Locale(it) }
    }
    val environment = remember(inherited, locale) {
        if (locale == null) inherited
        else ResourceEnvironment(
            language = LanguageQualifier(locale.language),
            script = ScriptQualifier(locale.script),
            region = RegionQualifier(locale.region),
            theme = inherited.theme,
            density = inherited.density,
        )
    }
    val provider = remember(environment) {
        object : ComposeEnvironment {
            @Composable
            override fun rememberEnvironment(): ResourceEnvironment = environment
        }
    }
    CompositionLocalProvider(LocalComposeEnvironment provides provider) { content() }
}

/** The languages this app has strings for. */
private val SPOKEN = setOf("en", "uk", "ru")
