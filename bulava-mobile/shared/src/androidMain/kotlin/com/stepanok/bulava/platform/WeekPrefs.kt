package com.stepanok.bulava.platform

import android.content.Context
import com.stepanok.bulava.link.LinkJson
import com.stepanok.bulava.link.Week

/**
 * The week the Home Screen widgets draw, kept in the app's own preferences so a widget can read it
 * while the connection to the Mac is down and the app is not on screen. The newest week wins: one
 * that arrives late never replaces a newer one.
 */
object WeekPrefs {
    private const val FILE = "bulava.week"
    private const val KEY = "week"

    fun read(context: Context): Week? =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).getString(KEY, null)
            ?.let { runCatching { LinkJson.decodeFromString(Week.serializer(), it) }.getOrNull() }

    /** Keeps [week], or removes what is kept for null. Returns whether anything changed. */
    fun write(context: Context, week: Week?): Boolean {
        val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        if (week == null) {
            if (!prefs.contains(KEY)) return false
            prefs.edit().remove(KEY).apply()
            return true
        }
        val kept = read(context)
        if (kept != null && (kept.generatedMs > week.generatedMs || kept == week)) return false
        prefs.edit().putString(KEY, LinkJson.encodeToString(Week.serializer(), week)).apply()
        return true
    }
}
