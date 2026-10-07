package com.stepanok.bulava.widgets

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.net.Uri
import android.os.Build
import android.text.format.DateUtils
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.color.ColorProvider
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ColumnScope
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider as GlanceColor
import com.stepanok.bulava.MainActivity
import com.stepanok.bulava.R
import com.stepanok.bulava.link.Week
import com.stepanok.bulava.link.WeekMeter
import com.stepanok.bulava.platform.WeekPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Bulava's week on the Android Home Screen: the faces the Mac's and the iPhone's widgets show,
 * drawn with Glance from the week the Mac sent. Every word comes from the Mac; the widget lays it
 * out and draws the charts from the numbers beside it.
 */
enum class WeekFace(val path: String) { Autonomy("autonomy"), Outcomes("outcomes"), Receipt("receipt"), Rhythm("rhythm"),
    Volume("volume"), Limits("limits"), Now("now"), Glance("week") }

/** Redraws every week widget on the Home Screen: the week changed. */
suspend fun redrawWeekWidgets(context: Context) {
    AutonomyWidget().updateAll(context)
    OutcomesWidget().updateAll(context)
    ReceiptWidget().updateAll(context)
    RhythmWidget().updateAll(context)
    VolumeWidget().updateAll(context)
    LimitsWidget().updateAll(context)
    NowWidget().updateAll(context)
    WeekGlanceWidget().updateAll(context)
    refreshWeekPreviews(context)
}

private val weekReceivers = listOf(AutonomyWidgetReceiver::class, OutcomesWidgetReceiver::class, ReceiptWidgetReceiver::class,
    RhythmWidgetReceiver::class, VolumeWidgetReceiver::class, LimitsWidgetReceiver::class, NowWidgetReceiver::class,
    WeekGlanceWidgetReceiver::class)

/**
 * The widget picker's pictures of the eight widgets (Android 15 and later), drawn from the week the
 * phone holds: without them every Bulava widget there looks like the app's icon. Android allows only
 * a few such updates an hour, so a week redraws them at most every six hours; a new version of the
 * app redraws them at once, and so does a forgotten Mac, so the picker stops showing its week.
 */
suspend fun refreshWeekPreviews(context: Context): Unit = withContext(Dispatchers.IO) {
    if (Build.VERSION.SDK_INT < 35) return@withContext
    val prefs = context.getSharedPreferences("bulava.week.previews", Context.MODE_PRIVATE)
    val now = System.currentTimeMillis()
    val version = context.packageManager.getPackageInfo(context.packageName, 0).longVersionCode
    val hasWeek = WeekPrefs.read(context) != null
    val due = when {
        prefs.getLong("version", -1) != version -> true
        prefs.getBoolean("week", false) && !hasWeek -> true
        hasWeek -> now - prefs.getLong("at", 0) >= 6 * 3600 * 1000L
        else -> false
    }
    if (!due) return@withContext
    val manager = GlanceAppWidgetManager(context)
    val limited = weekReceivers.map { manager.setWidgetPreviews(it) }
        .any { it == GlanceAppWidgetManager.SET_WIDGET_PREVIEWS_RESULT_RATE_LIMITED }
    if (!limited) prefs.edit().putLong("at", now).putLong("version", version).putBoolean("week", hasWeek).apply()
}

open class WeekWidget(private val face: WeekFace, preview: DpSize) : GlanceAppWidget() {
    // Exact: the faces lay out for the size the widget really has on this Home Screen, so a chart
    // grows into a taller widget instead of leaving its lower half empty.
    override val sizeMode = SizeMode.Exact

    // The picker's picture, at about the size the widget is first placed at.
    override val previewSizeMode = SizeMode.Responsive(setOf(preview))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val week = WeekPrefs.read(context)
        provideContent { WeekWidgetContent(face, week) }
    }

    override suspend fun providePreview(context: Context, widgetCategory: Int) {
        val week = WeekPrefs.read(context)
        provideContent { WeekWidgetContent(face, week) }
    }

    companion object {
        val THREE_BY_TWO = DpSize(270.dp, 190.dp)
        val FOUR_BY_TWO = DpSize(360.dp, 190.dp)
        val FOUR_BY_FOUR = DpSize(360.dp, 380.dp)
    }
}

class AutonomyWidget : WeekWidget(WeekFace.Autonomy, THREE_BY_TWO)
class OutcomesWidget : WeekWidget(WeekFace.Outcomes, THREE_BY_TWO)
class ReceiptWidget : WeekWidget(WeekFace.Receipt, THREE_BY_TWO)
class RhythmWidget : WeekWidget(WeekFace.Rhythm, FOUR_BY_TWO)
class VolumeWidget : WeekWidget(WeekFace.Volume, THREE_BY_TWO)
class LimitsWidget : WeekWidget(WeekFace.Limits, THREE_BY_TWO)
class NowWidget : WeekWidget(WeekFace.Now, THREE_BY_TWO)
class WeekGlanceWidget : WeekWidget(WeekFace.Glance, FOUR_BY_FOUR)

class AutonomyWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = AutonomyWidget() }
class OutcomesWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = OutcomesWidget() }
class ReceiptWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = ReceiptWidget() }
class RhythmWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = RhythmWidget() }
class VolumeWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = VolumeWidget() }
class LimitsWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = LimitsWidget() }
class NowWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = NowWidget() }
class WeekGlanceWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = WeekGlanceWidget() }

// MARK: - Palette: the desktop's, on the app icon's deep green

private object P {
    val field = ColorProvider(day = Color(0xFFF3F6EE), night = Color(0xFF16291C))
    val text = ColorProvider(day = Color(0xFF15241A), night = Color(0xFFF2F2F3))
    val secondary = ColorProvider(day = Color(0xFF4D5A50), night = Color(0xFFB5B5BB))
    val faint = ColorProvider(day = Color(0xFF6F7A71), night = Color(0xFF8B8B92))
    val accent = ColorProvider(day = Color(0xFF4C7A18), night = Color(0xFFC7F183))
    val accentMuted = ColorProvider(day = Color(0x6B4C7A18), night = Color(0x6BC7F183))
    val track = ColorProvider(day = Color(0x12000000), night = Color(0x14FFFFFF))
    val passed = ColorProvider(day = Color(0xFF2F8A55), night = Color(0xFF43A96D))
    val debt = ColorProvider(day = Color(0xFF4A74C9), night = Color(0xFF6F92E3))
    val waiting = ColorProvider(day = Color(0xFFB8691F), night = Color(0xFFC67A35))
    val warn = ColorProvider(day = Color(0xFFA85F12), night = Color(0xFFE8A45D))
    val bad = ColorProvider(day = Color(0xFFC2453E), night = Color(0xFFEF7770))

    fun severity(key: String) = when (key) { "bad" -> bad; "warn" -> warn; else -> accent }
    fun outcome(i: Int) = when (i) { 0 -> passed; 1 -> debt; else -> waiting }
}

private fun style(size: TextUnit, color: GlanceColor = P.text, weight: FontWeight = FontWeight.Normal) =
    TextStyle(color = color, fontSize = size, fontWeight = weight)

private enum class Size { Small, Medium, Large }

// MARK: - The widget

@Composable
private fun WeekWidgetContent(face: WeekFace, week: Week?) {
    val context = LocalContext.current
    val size = LocalSize.current
    val shape = when {
        size.width < 200.dp -> Size.Small
        size.height >= 300.dp -> Size.Large
        else -> Size.Medium
    }
    val open = Intent(context, MainActivity::class.java)
        .setAction(Intent.ACTION_VIEW)
        .setData(Uri.parse("bulava://week/${face.path}"))
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    Column(
        modifier = GlanceModifier.fillMaxSize().appWidgetBackground().background(P.field).cornerRadius(24.dp)
            .padding(14.dp).clickable(actionStartActivity(open)),
    ) {
        when {
            week == null -> Empty(context.getString(R.string.week_empty))
            week.off && face != WeekFace.Limits -> Off(week, shape)
            // A little short of the padding: a launcher's size can be a few dp more than it draws.
            else -> Face(face, week, shape, size.width - 32.dp, size.height - 28.dp)
        }
    }
}

@Composable
private fun Header(week: Week, title: String, shape: Size, trailing: String? = null) {
    val now = System.currentTimeMillis()
    val stale = now - week.generatedMs > 3 * 3600 * 1000L
    Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Image(ImageProvider(R.drawable.ic_stat_bulava), contentDescription = null,
            modifier = GlanceModifier.width(10.dp).height(13.dp), colorFilter = ColorFilter.tint(P.accent))
        Spacer(GlanceModifier.width(5.dp))
        Text(title, style = style(12.sp, P.secondary, FontWeight.Medium), maxLines = 1, modifier = GlanceModifier.defaultWeight())
        if (stale) {
            val age = DateUtils.getRelativeTimeSpanString(week.generatedMs, now, DateUtils.MINUTE_IN_MILLIS).toString()
            val text = if (shape == Size.Small) age else "${week.words.macAway} · $age"
            Text(text, style = style(10.5.sp, P.warn, FontWeight.Medium), maxLines = 1)
        } else if (shape != Size.Small) {
            Text(trailing ?: week.period, style = style(11.sp, P.faint), maxLines = 1)
        }
    }
}

@Composable
private fun Hero(value: String, unit: String, size: TextUnit = 32.sp) {
    Row(verticalAlignment = Alignment.Bottom) {
        Text(value, style = style(size, P.text, FontWeight.Bold), maxLines = 1)
        if (unit.isNotEmpty()) {
            Spacer(GlanceModifier.width(3.dp))
            Text(unit, style = style(size * 0.46f, P.secondary, FontWeight.Medium), maxLines = 1,
                modifier = GlanceModifier.padding(bottom = 3.dp))
        }
    }
}

@Composable
private fun Line(text: String, lines: Int = 2, color: GlanceColor = P.secondary, size: TextUnit = 12.sp) {
    Text(text, style = style(size, color), maxLines = lines)
}

@Composable
private fun Facts(facts: List<com.stepanok.bulava.link.WeekKV>) {
    for (f in facts) {
        Row(modifier = GlanceModifier.fillMaxWidth().padding(vertical = 1.5.dp)) {
            Text(f.label, style = style(11.5.sp, P.secondary), maxLines = 1, modifier = GlanceModifier.defaultWeight())
            Text(f.value, style = style(11.5.sp, P.text, FontWeight.Medium), maxLines = 1)
        }
    }
}

// MARK: - Charts

/** Seven columns, Monday first: today in the accent, earlier days muted, days ahead left empty. */
@Composable
private fun Columns(values: List<Double?>, days: List<String>, today: Int, height: Dp, labels: Boolean = true) {
    val top = (values.filterNotNull().maxOrNull() ?: 0.0).coerceAtLeast(1.0)
    val bars = if (labels) height - 14.dp else height
    Row(modifier = GlanceModifier.fillMaxWidth().height(height), verticalAlignment = Alignment.Bottom) {
        for (i in 0 until 7) {
            Column(modifier = GlanceModifier.defaultWeight().fillMaxHeight().padding(horizontal = 2.dp),
                horizontalAlignment = Alignment.CenterHorizontally, verticalAlignment = Alignment.Bottom) {
                val v = values.getOrNull(i)
                if (v != null && v > 0) {
                    Box(GlanceModifier.fillMaxWidth().height((bars.value * v / top).coerceAtLeast(3.0).dp)
                        .background(if (i == today) P.accent else P.accentMuted).cornerRadius(3.dp)) {}
                } else {
                    Box(GlanceModifier.fillMaxWidth().height(2.dp).background(P.track)) {}
                }
                if (labels) Text(days.getOrNull(i) ?: "", style = style(9.sp, if (i == today) P.text else P.faint), maxLines = 1)
            }
        }
    }
}

/** Per day: passed, with remarks, waited for you. */
@Composable
private fun Stacks(perDay: List<List<Int>?>, days: List<String>, today: Int, height: Dp) {
    val top = (perDay.filterNotNull().maxOfOrNull { it.sum() } ?: 0).coerceAtLeast(1)
    // Less the day's name and the hairline under each of the three parts.
    val bars = height - 17.dp
    Row(modifier = GlanceModifier.fillMaxWidth().height(height), verticalAlignment = Alignment.Bottom) {
        for (i in 0 until 7) {
            Column(modifier = GlanceModifier.defaultWeight().fillMaxHeight().padding(horizontal = 2.dp),
                horizontalAlignment = Alignment.CenterHorizontally, verticalAlignment = Alignment.Bottom) {
                val parts = perDay.getOrNull(i)
                if (parts != null && parts.sum() > 0) {
                    for (k in listOf(2, 1, 0)) {
                        val n = parts.getOrElse(k) { 0 }
                        if (n > 0) {
                            Box(GlanceModifier.fillMaxWidth().height((bars.value * n / top).coerceAtLeast(2f).dp).background(P.outcome(k))) {}
                            Spacer(GlanceModifier.height(1.dp))
                        }
                    }
                } else {
                    Box(GlanceModifier.fillMaxWidth().height(2.dp).background(P.track)) {}
                }
                Text(days.getOrNull(i) ?: "", style = style(9.sp, if (i == today) P.text else P.faint), maxLines = 1)
            }
        }
    }
}

/** Added above the line, removed below it. */
@Composable
private fun Diverging(perDay: List<List<Int>?>, days: List<String>, today: Int, height: Dp) {
    val top = (perDay.filterNotNull().maxOfOrNull { it.maxOrNull() ?: 0 } ?: 0).coerceAtLeast(1)
    val up = (height.value - 14) * 0.68f
    val down = (height.value - 14) * 0.32f
    Row(modifier = GlanceModifier.fillMaxWidth().height(height), verticalAlignment = Alignment.Bottom) {
        for (i in 0 until 7) {
            Column(modifier = GlanceModifier.defaultWeight().fillMaxHeight().padding(horizontal = 2.dp),
                horizontalAlignment = Alignment.CenterHorizontally) {
                val v = perDay.getOrNull(i)
                val added = v?.getOrNull(0) ?: 0
                val removed = v?.getOrNull(1) ?: 0
                Column(modifier = GlanceModifier.fillMaxWidth().height(up.dp), verticalAlignment = Alignment.Bottom) {
                    if (added > 0) Box(GlanceModifier.fillMaxWidth().height((up * added / top).coerceAtLeast(2f).dp)
                        .background(if (i == today) P.accent else P.accentMuted).cornerRadius(3.dp)) {}
                }
                Box(GlanceModifier.fillMaxWidth().height(1.dp).background(P.faint)) {}
                Column(modifier = GlanceModifier.fillMaxWidth().height(down.dp)) {
                    if (removed > 0) Box(GlanceModifier.fillMaxWidth().height((down * minOf(1f, 2f * removed / top)).coerceAtLeast(2f).dp)
                        .background(P.bad)) {}
                }
                Text(days.getOrNull(i) ?: "", style = style(9.sp, if (i == today) P.text else P.faint), maxLines = 1)
            }
        }
    }
}

@Composable
private fun Meter(m: WeekMeter, width: Dp, short: Boolean) {
    Column(modifier = GlanceModifier.width(width)) {
        Row(modifier = GlanceModifier.fillMaxWidth()) {
            Text(if (short) m.engine else m.label, style = style(11.sp, P.secondary), maxLines = 1, modifier = GlanceModifier.defaultWeight())
            Text(m.usedText, style = style(11.sp, P.text, FontWeight.Medium), maxLines = 1)
        }
        Spacer(GlanceModifier.height(4.dp))
        Box(modifier = GlanceModifier.width(width).height(9.dp), contentAlignment = Alignment.CenterStart) {
            Box(GlanceModifier.width(width).height(5.dp).background(P.track).cornerRadius(3.dp)) {}
            Box(GlanceModifier.width((width.value * m.used / 100f).coerceAtLeast(2f).dp).height(5.dp)
                .background(P.severity(m.severity)).cornerRadius(3.dp)) {}
            m.elapsed?.let { e ->
                Row {
                    Spacer(GlanceModifier.width((width.value * e / 100f - 1f).coerceIn(0f, width.value - 2f).dp))
                    Box(GlanceModifier.width(2.dp).height(9.dp).background(P.text)) {}
                }
            }
        }
        if (!short) m.pace?.let {
            Text(it, style = style(10.sp, if (m.paceKey == "ahead") P.warn else P.faint), maxLines = 1)
        }
    }
}

/**
 * Seven rows by twenty-four hours, drawn once as a mask and tinted in the accent. Given a `height`,
 * the rows grow into it (up to a little over twice as tall as wide), and the day names shrink
 * with rows too short for them rather than being cut.
 */
@Composable
private fun Heat(heat: List<List<Int>?>, days: List<String>, width: Dp, labels: Boolean, height: Dp? = null) {
    val context = LocalContext.current
    val density = context.resources.displayMetrics.density
    val gap = 1.5f
    val labelWidth = if (labels) 22f else 0f
    val axis = if (labels) 14f else 0f
    val gridWidth = width.value - labelWidth
    val cell = (gridWidth - 23 * gap) / 24f
    val natural = cell + if (labels) 2f else 3f
    val rowHeight = height?.let { ((it.value - axis - 6 * gap) / 7f).coerceIn(2f, maxOf(natural, cell * 2.4f)) } ?: natural
    val gridHeight = 7 * rowHeight + 6 * gap
    val dayText = ((rowHeight + gap) * 0.72f).coerceAtMost(9f)
    val bitmap = heatBitmap(heat, (gridWidth * density).toInt(), (gridHeight * density).toInt(), cell * density, rowHeight * density, gap * density)
    Column {
        Row {
            if (labels) {
                Column(modifier = GlanceModifier.width(labelWidth.dp)) {
                    for (d in 0 until 7) Text(if (dayText >= 6f) days.getOrNull(d) ?: "" else "", style = style(dayText.sp, P.faint),
                        maxLines = 1, modifier = GlanceModifier.height((rowHeight + gap).dp))
                }
            }
            Image(ImageProvider(bitmap), contentDescription = null, colorFilter = ColorFilter.tint(P.accent),
                modifier = GlanceModifier.width(gridWidth.dp).height(gridHeight.dp))
        }
        if (labels) {
            Row(modifier = GlanceModifier.width(width).height(axis.dp).padding(start = labelWidth.dp, top = 2.dp)) {
                listOf("00", "06", "12", "18", "24").forEachIndexed { i, t ->
                    if (i > 0) Spacer(GlanceModifier.defaultWeight())
                    Text(t, style = style(8.sp, P.faint), maxLines = 1)
                }
            }
        }
    }
}

private fun heatBitmap(heat: List<List<Int>?>, w: Int, h: Int, cell: Float, row: Float, gap: Float): Bitmap {
    // White on clear, tinted where it is drawn. Not ALPHA_8, although a mask is all it is: the widget
    // picker keeps its pictures as PNG, and an ALPHA_8 bitmap arrives there empty.
    val bitmap = Bitmap.createBitmap(w.coerceAtLeast(1), h.coerceAtLeast(1), Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.WHITE }
    val top = (heat.filterNotNull().maxOfOrNull { it.maxOrNull() ?: 0 } ?: 0).coerceAtLeast(1).toFloat()
    for (d in 0 until 7) {
        val values = heat.getOrNull(d)
        for (hour in 0 until 24) {
            val v = values?.getOrNull(hour) ?: 0
            val share = v / top
            paint.alpha = when {
                values == null -> 12
                v == 0 -> 26
                share > 0.75f -> 255
                share > 0.5f -> 180
                share > 0.22f -> 115
                else -> 60
            }
            val x = hour * (cell + gap)
            val y = d * (row + gap)
            canvas.drawRoundRect(RectF(x, y, x + cell, y + row), cell / 4, cell / 4, paint)
        }
    }
    return bitmap
}

// MARK: - The faces

/** A medium face's chart, beside its number: as tall as the widget lets it be, within reason. */
private fun chart(height: Dp): Dp = (height - 24.dp).coerceIn(72.dp, 150.dp)

@Composable
private fun Face(face: WeekFace, w: Week, shape: Size, width: Dp, height: Dp) {
    when (face) {
        WeekFace.Autonomy -> {
            val f = w.autonomy
            Header(w, f.title, shape)
            val lead = f.empty ?: f.lines.firstOrNull()?.let { listOfNotNull(it.strong, it.text).joinToString(" ") } ?: ""
            when (shape) {
                Size.Small -> {
                    Spacer(GlanceModifier.height(6.dp)); Hero(f.hero, f.unit, 30.sp); Line(lead, 3)
                }
                Size.Medium -> Row(modifier = GlanceModifier.fillMaxWidth().padding(top = 6.dp)) {
                    Column(modifier = GlanceModifier.width(width * 0.5f)) {
                        val roomy = height >= 150.dp
                        Hero(f.hero, f.unit); Line(lead, if (roomy) 3 else 2)
                        if (f.empty == null) f.lines.getOrNull(1)?.let { Line(it.text, if (roomy) 2 else 1) }
                    }
                    Spacer(GlanceModifier.width(10.dp))
                    Columns(f.perDay.map { it?.toDouble() }, w.days, w.today, chart(height))
                }
                Size.Large -> {
                    Spacer(GlanceModifier.height(6.dp)); Hero(f.hero, f.unit, 36.sp)
                    if (f.empty == null) f.lines.getOrNull(2)?.let { Line(it.text, 1) }
                    Line(lead, 2)
                    Spacer(GlanceModifier.height(8.dp))
                    Columns(f.perDay.map { it?.toDouble() }, w.days, w.today, 100.dp)
                    Spacer(GlanceModifier.height(8.dp)); Facts(f.facts)
                }
            }
        }
        WeekFace.Outcomes -> {
            val f = w.outcomes
            Header(w, f.title, shape)
            Spacer(GlanceModifier.height(6.dp))
            when (shape) {
                Size.Small -> {
                    Hero(f.hero, f.unit, 30.sp)
                    if (f.empty != null) Line(f.empty!!, 3) else {
                        f.lines.getOrNull(0)?.let { Line(it.text, 2) }
                        f.lines.getOrNull(1)?.let { Line("● " + it.text, 1, P.waiting) }
                    }
                }
                Size.Medium -> Row(modifier = GlanceModifier.fillMaxWidth()) {
                    Column(modifier = GlanceModifier.width(width * 0.5f)) { Hero(f.hero, f.unit); Legend(f.legend) }
                    Spacer(GlanceModifier.width(10.dp))
                    Stacks(f.perDay, w.days, w.today, chart(height))
                }
                Size.Large -> {
                    Hero(f.hero, f.unit, 36.sp); Legend(f.legend)
                    Spacer(GlanceModifier.height(8.dp)); Stacks(f.perDay, w.days, w.today, 100.dp)
                    Spacer(GlanceModifier.height(8.dp)); Facts(f.facts)
                }
            }
        }
        WeekFace.Receipt -> {
            val f = w.receipt
            Header(w, if (shape == Size.Small) f.title else f.longTitle, shape)
            Spacer(GlanceModifier.height(6.dp))
            if (shape == Size.Small) {
                Line(f.caption, 1); Hero(f.hero, "", 26.sp); Line(f.tokens, 1); Line(f.note, 2, P.faint, 10.5.sp)
            } else {
                for (r in f.rows) ReceiptRow(r.label, r.value, false)
                Box(GlanceModifier.fillMaxWidth().height(1.dp).padding(vertical = 2.dp).background(P.faint)) {}
                ReceiptRow(f.total.label, f.total.value, true)
                if (shape == Size.Large) {
                    Spacer(GlanceModifier.height(8.dp))
                    Columns(f.perDay, w.days, w.today, 90.dp)
                    Line(f.footer, 1, P.faint, 10.sp)
                } else {
                    Line(f.note, 1, P.faint, 10.sp)
                }
            }
        }
        WeekFace.Rhythm -> {
            val f = w.rhythm
            Header(w, if (shape == Size.Small) f.title else f.longTitle, shape)
            Spacer(GlanceModifier.height(8.dp))
            if (shape == Size.Small) {
                Heat(f.heat, w.days, width, false); Spacer(GlanceModifier.height(6.dp)); Line(f.line, 2)
            } else {
                Row {
                    Heat(f.heat, w.days, width - 104.dp, true, height = height - 26.dp)
                    Spacer(GlanceModifier.width(10.dp))
                    Column {
                        Line(f.peakLabel, 2, size = 11.sp); Text(f.peak, style = style(18.sp, P.text, FontWeight.Bold), maxLines = 1)
                        Spacer(GlanceModifier.height(6.dp))
                        Line(f.activeLabel, 2, size = 11.sp); Text(f.active + f.activeOf, style = style(18.sp, P.text, FontWeight.Bold), maxLines = 1)
                    }
                }
            }
        }
        WeekFace.Volume -> {
            val f = w.volume
            Header(w, if (shape == Size.Small) f.title else f.longTitle, shape)
            Spacer(GlanceModifier.height(6.dp))
            if (shape == Size.Small) {
                Text(f.added, style = style(if (f.added.length > 7) 20.sp else 24.sp, P.text, FontWeight.Bold), maxLines = 1)
                Text(f.removed, style = style(18.sp, P.bad, FontWeight.Bold), maxLines = 1)
                Line(f.line, 2)
            } else Row(modifier = GlanceModifier.fillMaxWidth()) {
                Column(modifier = GlanceModifier.width(width * 0.5f)) {
                    Text(f.added, style = style(if (f.added.length > 7) 21.sp else 24.sp, P.text, FontWeight.Bold), maxLines = 1)
                    Text(f.removed, style = style(18.sp, P.bad, FontWeight.Bold), maxLines = 1)
                    Line(f.detail, 2)
                }
                Spacer(GlanceModifier.width(10.dp))
                Diverging(f.perDay, w.days, w.today, chart(height))
            }
        }
        WeekFace.Limits -> {
            val f = w.limits
            Header(w, f.title, shape, trailing = w.words.now)
            Spacer(GlanceModifier.height(8.dp))
            if (f.empty != null) Line(f.empty!!, 3)
            else if (shape == Size.Small) {
                val weekly = f.meters.filter { it.weekly }.ifEmpty { f.meters }.take(2)
                for (m in weekly) { Meter(m, width, true); Spacer(GlanceModifier.height(6.dp)) }
                Line(f.line, 2, size = 11.sp)
            } else {
                val engines = f.meters.map { it.engine }.distinct()
                val col = (width - 12.dp) / engines.size.coerceAtLeast(1)
                Row {
                    engines.forEachIndexed { i, e ->
                        if (i > 0) Spacer(GlanceModifier.width(12.dp))
                        Column {
                            for (m in f.meters.filter { it.engine == e }) { Meter(m, col, false); Spacer(GlanceModifier.height(6.dp)) }
                        }
                    }
                }
            }
        }
        WeekFace.Now -> {
            val f = w.now
            Header(w, if (shape == Size.Small) f.title else f.longTitle, shape, trailing = "")
            Spacer(GlanceModifier.height(8.dp))
            if (f.runs.isEmpty()) {
                Text(f.empty, style = style(13.sp, P.secondary, FontWeight.Medium), maxLines = 3)
            } else {
                if (shape == Size.Small && f.count != "0") Hero(f.count, f.unit, 28.sp)
                val shown = when (shape) { Size.Small -> 2; Size.Medium -> 4; Size.Large -> 9 }
                for (r in f.runs.take(shown)) {
                    Row(modifier = GlanceModifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("● ", style = style(10.sp, if (r.waiting) P.waiting else P.accent))
                        Text(r.name, style = style(12.sp), maxLines = 1, modifier = GlanceModifier.defaultWeight())
                        Text(r.time, style = style(11.sp, P.faint), maxLines = 1)
                    }
                }
                if (shape != Size.Small) f.waiting?.let { Line(it, 1, P.waiting, 11.5.sp) }
            }
        }
        WeekFace.Glance -> {
            Header(w, w.period, shape, trailing = "")
            Spacer(GlanceModifier.height(6.dp))
            Row(verticalAlignment = Alignment.Bottom) {
                Hero(w.autonomy.hero, w.autonomy.unit, 40.sp)
                Spacer(GlanceModifier.width(8.dp))
                Column {
                    Line(w.autonomy.title.lowercase(), 1)
                    if (w.autonomy.empty == null) w.autonomy.lines.firstOrNull()?.let { Line(listOfNotNull(it.strong, it.text).joinToString(" "), 2) }
                }
            }
            Spacer(GlanceModifier.height(10.dp))
            Row(modifier = GlanceModifier.fillMaxWidth()) {
                Tile(w.outcomes.hero, w.outcomes.unit, w.outcomes.legend.lastOrNull()?.text, GlanceModifier.defaultWeight())
                Spacer(GlanceModifier.width(6.dp))
                Tile(w.receipt.hero, w.receipt.caption, w.receipt.note, GlanceModifier.defaultWeight())
                Spacer(GlanceModifier.width(6.dp))
                Tile(w.volume.added, w.volume.title.lowercase(), w.volume.removed, GlanceModifier.defaultWeight())
            }
            Spacer(GlanceModifier.height(10.dp))
            Heat(w.rhythm.heat, w.days, width, true)
        }
    }
}

@Composable
private fun Legend(legend: List<com.stepanok.bulava.link.WeekLegend>) {
    legend.forEachIndexed { i, l ->
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(GlanceModifier.width(7.dp).height(7.dp).background(P.outcome(i)).cornerRadius(2.dp)) {}
            Spacer(GlanceModifier.width(5.dp))
            Text(l.text, style = style(11.sp, P.secondary), maxLines = 1)
        }
    }
}

@Composable
private fun ReceiptRow(label: String, value: String, bold: Boolean) {
    Row(modifier = GlanceModifier.fillMaxWidth()) {
        Text(label, style = style(11.sp, if (bold) P.text else P.secondary, if (bold) FontWeight.Bold else FontWeight.Normal),
            maxLines = 1, modifier = GlanceModifier.defaultWeight())
        Text(value, style = style(11.sp, P.text, if (bold) FontWeight.Bold else FontWeight.Normal), maxLines = 1)
    }
}

@Composable
private fun Tile(value: String, label: String, note: String?, modifier: GlanceModifier) {
    Column(modifier = modifier.background(P.track).cornerRadius(11.dp).padding(horizontal = 8.dp, vertical = 6.dp)) {
        Text(value, style = style(16.sp, P.text, FontWeight.Bold), maxLines = 1)
        Text(label, style = style(10.5.sp, P.secondary), maxLines = 1)
        note?.let { Text(it, style = style(9.5.sp, P.faint), maxLines = 1) }
    }
}

@Composable
private fun ColumnScope.Off(w: Week, shape: Size) {
    Image(ImageProvider(R.drawable.ic_stat_bulava), contentDescription = null,
        modifier = GlanceModifier.width(10.dp).height(13.dp), colorFilter = ColorFilter.tint(P.accent))
    Spacer(GlanceModifier.defaultWeight())
    Text(w.words.off, style = style(15.sp, P.text, FontWeight.Bold), maxLines = 2)
    if (shape != Size.Small) Line(w.words.offHint, 2)
    Text(w.words.turnOn + " →", style = style(12.sp, P.accent, FontWeight.Medium), maxLines = 1)
    Spacer(GlanceModifier.defaultWeight())
}

@Composable
private fun ColumnScope.Empty(text: String) {
    Image(ImageProvider(R.drawable.ic_stat_bulava), contentDescription = null,
        modifier = GlanceModifier.width(10.dp).height(13.dp), colorFilter = ColorFilter.tint(P.accent))
    Spacer(GlanceModifier.defaultWeight())
    Text(text, style = style(13.sp, P.secondary, FontWeight.Medium), maxLines = 4)
    Spacer(GlanceModifier.defaultWeight())
}
