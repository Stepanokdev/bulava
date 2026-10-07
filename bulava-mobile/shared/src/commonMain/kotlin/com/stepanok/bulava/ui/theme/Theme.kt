package com.stepanok.bulava.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp

/**
 * The desktop's palette (`Night Shift/Design/Theme.swift`), carried over value for value so the
 * phone and the Mac read as one product: neutral surfaces, hairlines instead of shadows, and the
 * Bulava lime used sparingly for what is primary.
 */
@Immutable
data class BulavaColors(
    val background: Color,
    val surface: Color,
    val surfaceMuted: Color,
    val surfaceRaised: Color,
    val field: Color,
    val text: Color,
    val textSecondary: Color,
    val textTertiary: Color,
    val textFaint: Color,
    val line: Color,
    val lineStrong: Color,
    val accent: Color,
    val accentEmphasis: Color,
    val accentSoft: Color,
    val onAccent: Color,
    val green: Color,
    val greenSoft: Color,
    val orange: Color,
    val orangeSoft: Color,
    val red: Color,
    val redSoft: Color,
    val blue: Color,
    val blueSoft: Color,
    val code: Color,
    val scrim: Color,
    val isDark: Boolean,
)

val LightColors = BulavaColors(
    background = Color(0xFFF6F6F7),
    surface = Color(0xFFFFFFFF),
    surfaceMuted = Color(0xFFEFEFF1),
    surfaceRaised = Color(0xFFE6E6E8),
    field = Color(0xFFFFFFFF),
    text = Color(0xFF202023),
    textSecondary = Color(0xFF626268),
    textTertiary = Color(0xFF64646B),
    textFaint = Color(0xFF7C7C84),
    line = Color(0x13000000),
    lineStrong = Color(0x24000000),
    accent = Color(0xFF4B7510),
    accentEmphasis = Color(0xFF3C5F0D),
    accentSoft = Color(0x1A4B7510),
    onAccent = Color(0xFFFFFFFF),
    green = Color(0xFF1F6B41),
    greenSoft = Color(0x171F6B41),
    orange = Color(0xFF8A4E12),
    orangeSoft = Color(0x178A4E12),
    red = Color(0xFFA83B36),
    redSoft = Color(0x17A83B36),
    blue = Color(0xFF3475BB),
    blueSoft = Color(0x173475BB),
    code = Color(0xFFEFEFF1),
    scrim = Color(0x66000000),
    isDark = false,
)

val DarkColors = BulavaColors(
    background = Color(0xFF19191A),
    surface = Color(0xFF242426),
    surfaceMuted = Color(0xFF2B2B2E),
    surfaceRaised = Color(0xFF323235),
    field = Color(0xFF29292C),
    text = Color(0xFFF2F2F3),
    textSecondary = Color(0xFFB5B5BB),
    textTertiary = Color(0xFF92929A),
    textFaint = Color(0xFF7C7C83),
    line = Color(0x13FFFFFF),
    lineStrong = Color(0x21FFFFFF),
    accent = Color(0xFFB4E76D),
    accentEmphasis = Color(0xFFC7F183),
    accentSoft = Color(0x21C7F183),
    onAccent = Color(0xFF16291C),
    green = Color(0xFF69C58C),
    greenSoft = Color(0x1F69C58C),
    orange = Color(0xFFE8A45D),
    orangeSoft = Color(0x21E8A45D),
    red = Color(0xFFEF7770),
    redSoft = Color(0x1FEF7770),
    blue = Color(0xFF70A9F4),
    blueSoft = Color(0x1F70A9F4),
    code = Color(0xFF2B2B2E),
    scrim = Color(0x99000000),
    isDark = true,
)

/** The Bulava mark's own colours — the lime on the deep green of the app icon. */
object Brand {
    val lime = Color(0xFFC7F183)
    val field = Color(0xFF16291C)
}

@Immutable
data class BulavaType(
    val display: TextStyle,
    val title: TextStyle,
    val headline: TextStyle,
    val body: TextStyle,
    val bodyStrong: TextStyle,
    val callout: TextStyle,
    val caption: TextStyle,
    val meta: TextStyle,
    val eyebrow: TextStyle,
    val mono: TextStyle,
)

private val Type = BulavaType(
    display = TextStyle(fontSize = 30.sp, lineHeight = 34.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.02).em),
    title = TextStyle(fontSize = 21.sp, lineHeight = 26.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.01).em),
    headline = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold),
    body = TextStyle(fontSize = 16.sp, lineHeight = 24.sp),
    bodyStrong = TextStyle(fontSize = 16.sp, lineHeight = 22.sp, fontWeight = FontWeight.Medium),
    callout = TextStyle(fontSize = 15.sp, lineHeight = 21.sp),
    caption = TextStyle(fontSize = 13.sp, lineHeight = 18.sp),
    meta = TextStyle(fontSize = 12.sp, lineHeight = 16.sp),
    eyebrow = TextStyle(fontSize = 11.sp, lineHeight = 14.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.06.em),
    mono = TextStyle(fontSize = 13.sp, lineHeight = 19.sp, fontFamily = FontFamily.Monospace),
)

object Metrics {
    val gutter = 16.dp
    val radiusCard = 12.dp
    val radiusControl = 10.dp
    val radiusChip = 8.dp
    val touch = 48.dp
    val hairline = 1.dp
}

val LocalColors = staticCompositionLocalOf { LightColors }
val LocalType = staticCompositionLocalOf { Type }

object Bulava {
    val colors: BulavaColors @Composable get() = LocalColors.current
    val type: BulavaType @Composable get() = LocalType.current
}

@Composable
fun BulavaTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val colors = if (dark) DarkColors else LightColors
    val scheme = if (dark) {
        darkColorScheme(
            primary = colors.accent, onPrimary = colors.onAccent, background = colors.background,
            onBackground = colors.text, surface = colors.surface, onSurface = colors.text,
            surfaceVariant = colors.surfaceMuted, onSurfaceVariant = colors.textSecondary,
            surfaceContainer = colors.surface, surfaceContainerHigh = colors.surfaceMuted,
            surfaceContainerHighest = colors.surfaceRaised, surfaceContainerLow = colors.background,
            outline = colors.lineStrong, outlineVariant = colors.line, error = colors.red,
            secondaryContainer = colors.accentSoft, onSecondaryContainer = colors.accentEmphasis,
        )
    } else {
        lightColorScheme(
            primary = colors.accent, onPrimary = colors.onAccent, background = colors.background,
            onBackground = colors.text, surface = colors.surface, onSurface = colors.text,
            surfaceVariant = colors.surfaceMuted, onSurfaceVariant = colors.textSecondary,
            surfaceContainer = colors.surface, surfaceContainerHigh = colors.surfaceMuted,
            surfaceContainerHighest = colors.surfaceRaised, surfaceContainerLow = colors.background,
            outline = colors.lineStrong, outlineVariant = colors.line, error = colors.red,
            secondaryContainer = colors.accentSoft, onSecondaryContainer = colors.accentEmphasis,
        )
    }
    val typography = Typography(
        headlineMedium = Type.title, titleLarge = Type.title, titleMedium = Type.headline,
        bodyLarge = Type.body, bodyMedium = Type.callout, bodySmall = Type.caption,
        labelLarge = Type.bodyStrong.copy(fontSize = 15.sp), labelMedium = Type.meta, labelSmall = Type.eyebrow,
    )
    CompositionLocalProvider(LocalColors provides colors, LocalType provides Type) {
        MaterialTheme(colorScheme = scheme, typography = typography, content = content)
    }
}

/** Colour for a status tone the Mac sent. Unknown tones read as neutral. */
@Composable
fun toneColor(tone: String): Color = when (tone) {
    "active" -> Bulava.colors.accent
    "attention" -> Bulava.colors.orange
    "problem" -> Bulava.colors.red
    "good" -> Bulava.colors.green
    else -> Bulava.colors.textFaint
}

@Composable
fun toneWash(tone: String): Color = when (tone) {
    "active" -> Bulava.colors.accentSoft
    "attention" -> Bulava.colors.orangeSoft
    "problem" -> Bulava.colors.redSoft
    "good" -> Bulava.colors.greenSoft
    else -> Bulava.colors.surfaceMuted
}
