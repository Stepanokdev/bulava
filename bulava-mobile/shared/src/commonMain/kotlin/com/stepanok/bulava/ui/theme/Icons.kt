package com.stepanok.bulava.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.dp

/**
 * The app's icons, drawn here rather than taken from an icon font: one stroke weight, rounded ends,
 * a 24-unit grid. Anything that has to read as solid (stop, the dots) is filled instead.
 */
object Icons {
    private fun stroked(name: String, vararg paths: String, width: Float = 1.8f): ImageVector {
        val b = ImageVector.Builder(name = name, defaultWidth = 24.dp, defaultHeight = 24.dp,
            viewportWidth = 24f, viewportHeight = 24f)
        for (p in paths) {
            b.addPath(pathData = addPathNodes(p), stroke = SolidColor(Color.Black), strokeLineWidth = width,
                strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round, fill = null)
        }
        return b.build()
    }

    private fun filled(name: String, vararg paths: String): ImageVector {
        val b = ImageVector.Builder(name = name, defaultWidth = 24.dp, defaultHeight = 24.dp,
            viewportWidth = 24f, viewportHeight = 24f)
        for (p in paths) b.addPath(pathData = addPathNodes(p), fill = SolidColor(Color.Black))
        return b.build()
    }

    private fun circle(cx: Float, cy: Float, r: Float) =
        "M${cx - r} $cy a$r $r 0 1 0 ${2 * r} 0 a$r $r 0 1 0 ${-2 * r} 0"

    val Menu = stroked("menu", "M4 8.5h16", "M4 15.5h10")
    val NewChat = stroked("new-chat", "M11 4H6.5A2.5 2.5 0 0 0 4 6.5v11A2.5 2.5 0 0 0 6.5 20h11a2.5 2.5 0 0 0 2.5-2.5V13",
        "M17.6 3.6a2 2 0 0 1 2.8 2.8L12.5 14.3 9 15l.7-3.5z")
    val Send = stroked("send", "M12 19V5", "M6 11l6-6 6 6", width = 2.1f)
    val Stop = filled("stop", "M7.5 6h9A1.5 1.5 0 0 1 18 7.5v9a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 6 16.5v-9A1.5 1.5 0 0 1 7.5 6z")
    val Plus = stroked("plus", "M12 5v14", "M5 12h14")
    val Close = stroked("close", "M6.5 6.5l11 11", "M17.5 6.5l-11 11")
    val Check = stroked("check", "M5 12.5l4.5 4.5L19 7.5")
    val ChevronRight = stroked("chevron-right", "M9.5 6l6 6-6 6")
    val ChevronDown = stroked("chevron-down", "M6 9.5l6 6 6-6")
    val Back = stroked("back", "M14.5 6l-6 6 6 6")
    val Search = stroked("search", circle(10.5f, 10.5f, 6.5f), "M15.5 15.5l4.5 4.5")
    val Settings = stroked("settings", "M4 7h9", "M17 7h3", "M4 17h3", "M11 17h9", circle(15f, 7f, 2f), circle(9f, 17f, 2f))
    val Image = stroked("image", "M6 4h12a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z",
        circle(9f, 9.5f, 1.6f), "M20 15.5l-4.5-4.5L6 20")
    val Paperclip = stroked("paperclip", "M19.5 11.2l-7.9 7.9a4.7 4.7 0 0 1-6.7-6.7l8.2-8.2a3.1 3.1 0 0 1 4.5 4.5l-8.2 8.2a1.6 1.6 0 0 1-2.2-2.2l7.5-7.5")
    val Document = stroked("document", "M13.5 3.5H7.5a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2h9a2 2 0 0 0 2-2V8.5z", "M13.5 3.5v5h5", "M9 13h6", "M9 16.5h4")
    val Scan = stroked("scan", "M4 8.5V6.5a2.5 2.5 0 0 1 2.5-2.5h2", "M15.5 4h2A2.5 2.5 0 0 1 20 6.5v2",
        "M20 15.5v2a2.5 2.5 0 0 1-2.5 2.5h-2", "M8.5 20h-2A2.5 2.5 0 0 1 4 17.5v-2", "M4 12h16")
    val Laptop = stroked("laptop", "M6.5 5h11A1.5 1.5 0 0 1 19 6.5V16H5V6.5A1.5 1.5 0 0 1 6.5 5z", "M3 19h18")
    val Unplugged = stroked("unplugged", circle(12f, 12f, 8f), "M6.5 6.5l11 11")
    val Bell = stroked("bell", "M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 2h-15z", "M10 21a2.2 2.2 0 0 0 4 0")
    val Archive = stroked("archive", "M4 6.5h16v3.5H4z", "M5.5 10v8A1.5 1.5 0 0 0 7 19.5h10a1.5 1.5 0 0 0 1.5-1.5v-8", "M10 13.5h4")
    val Pin = stroked("pin", "M9 4h6", "M10 4v5l-3.2 4h10.4L14 9V4", "M12 13v7")
    val Pencil = stroked("pencil", "M15.2 5.3a2.1 2.1 0 0 1 3 3L8.5 18 4.5 19.5 6 15.5z")
    val Refresh = stroked("refresh", "M19.5 12a7.5 7.5 0 1 1-2.2-5.3", "M19.5 4.5v4.5H15")
    val External = stroked("external", "M13.5 4.5h6v6", "M19.5 4.5l-8.5 8.5", "M18 14v3.5a2 2 0 0 1-2 2H6.5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2H10")
    val Copy = stroked("copy", "M9 9h9a1.5 1.5 0 0 1 1.5 1.5v9A1.5 1.5 0 0 1 18 21H9a1.5 1.5 0 0 1-1.5-1.5v-9A1.5 1.5 0 0 1 9 9z",
        "M15.5 6V4.5A1.5 1.5 0 0 0 14 3H5A1.5 1.5 0 0 0 3.5 4.5v9A1.5 1.5 0 0 0 5 15h1.5")
    /** The Mac's `sidebar.trailing`: a window with its right-hand pane — the chat's details. */
    val Panel = stroked("panel", "M5.5 5h13A1.5 1.5 0 0 1 20 6.5v11a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 17.5v-11A1.5 1.5 0 0 1 5.5 5z",
        "M14.5 5v14")
    val Bolt = stroked("bolt", "M13.2 3.5L5.8 13.2h5.6l-.8 7.3 7.6-9.9h-5.7z")
    val Share = stroked("share", "M12 3.8v11", "M8 7.6l4-3.8 4 3.8",
        "M8.2 10.5H7A1.5 1.5 0 0 0 5.5 12v6.5A1.5 1.5 0 0 0 7 20h10a1.5 1.5 0 0 0 1.5-1.5V12a1.5 1.5 0 0 0-1.5-1.5h-1.2")
    val Tune = stroked("tune", "M5 20v-6", "M5 10V4", "M12 20v-8", "M12 8V4", "M19 20v-4", "M19 12V4", "M3 14h4", "M10 8h4", "M17 16h4")
    val Info = stroked("info", circle(12f, 12f, 8.5f), "M12 11v5.5", "M12 7.8v.2")
    val Warning = stroked("warning", "M12 4.5l8.5 15h-17z", "M12 10v4", "M12 17v.2")
    val Wifi = stroked("wifi", "M3.5 9.5a12 12 0 0 1 17 0", "M6.5 12.8a7.7 7.7 0 0 1 11 0", "M9.5 16a3.4 3.4 0 0 1 5 0", "M12 19.3v.2")
    val Lock = stroked("lock", "M7 11h10a1.5 1.5 0 0 1 1.5 1.5v6A1.5 1.5 0 0 1 17 20H7a1.5 1.5 0 0 1-1.5-1.5v-6A1.5 1.5 0 0 1 7 11z", "M8.5 11V8a3.5 3.5 0 0 1 7 0v3")
    val Mic = stroked("mic", "M12 3.5a3 3 0 0 1 3 3v5a3 3 0 0 1-6 0v-5a3 3 0 0 1 3-3z",
        "M6 11.5a6 6 0 0 0 12 0", "M12 17.5v3")
    val Download = stroked("download", "M12 4v11", "M7.5 10.5L12 15l4.5-4.5", "M5 19.5h14")
    val Dots = filled("dots", circle(6f, 12f, 1.6f), circle(12f, 12f, 1.6f), circle(18f, 12f, 1.6f))
    val Keyboard = stroked("keyboard", "M5 6.5h14A1.5 1.5 0 0 1 20.5 8v8a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 16V8A1.5 1.5 0 0 1 5 6.5z",
        "M7 10h.2", "M10.5 10h.2", "M14 10h.2", "M17 10h.2", "M8 14h8")

    /** The Bulava mark, in its own coordinates. */
    val Mark: ImageVector = ImageVector.Builder(name = "bulava", defaultWidth = 16.dp, defaultHeight = 24.dp,
        viewportWidth = 401.5f, viewportHeight = 591f).apply {
        addGroup(translationX = -324f, translationY = -216f)
        addPath(pathData = addPathNodes("M550.1 216 L567.9 216 L576.9 217.6 L586.7 220.9 L596.3 225.7 L603.7 230.6 L613.4 239.5 L622.2 251.6 L627.1 261.3 L632 279.2 L632 300.3 L628.7 313.4 L621.5 328.7 L619.2 330.6 L615 337.6 L602.8 349 L588.6 357.2 L580.4 366.2 L577.2 375.2 L577.2 407.6 L581.3 416.6 L588.6 423.1 L610 430.5 L626.2 438.6 L652 455.5 L673 474.1 L673.2 475.5 L680.3 482.2 L691.6 496.7 L700.5 510.5 L710.2 529.8 L719.1 554.9 L723.1 572.6 L725.5 592.1 L725.5 621.2 L722.3 645.5 L715.8 669.7 L709.4 686.7 L700.5 704.4 L683.5 730.3 L674.8 739.4 L674.7 740.8 L652.8 761.8 L642.4 769.8 L622.1 782.8 L603.6 791.6 L588.2 797.3 L570.5 802.1 L543 806.2 L529.1 806.2 L528.4 807 L505 806.2 L479.1 802.1 L447.5 792.4 L424.2 781.2 L408.8 771.4 L395.1 761 L373.3 740 L353.9 714.2 L341.8 691.5 L331.3 663.2 L326.4 642.3 L324 621.2 L324 234.9 L327.3 226.6 L332.2 221.7 L341.3 218.4 L436.5 218.4 L444.8 221.7 L449.7 226.6 L452.2 231.5 L453 235.7 L453 620.4 L453.8 626.1 L457.9 639.9 L465.2 653.7 L470 660.1 L481.3 670.7 L496.7 679.6 L506.5 682.8 L514.6 684.4 L534.9 684.4 L553.6 679.6 L563.3 674.7 L574.6 666.6 L581.1 660.1 L590 648 L594.9 638.3 L598.9 625.3 L600.6 614.8 L599.7 594.4 L594.9 577.4 L584.4 559.6 L570.6 545.8 L559.2 538.5 L557.2 538.5 L552 535.3 L536.5 531.3 L521.1 530.4 L508.1 532.1 L498.7 535.3 L491.2 535.3 L483.7 530.3 L481.2 525.3 L481.2 436.5 L482.9 431.5 L489.4 424.1 L495.2 421.6 L500.3 421.6 L516.2 418.4 L525.2 418.4 L531 416.7 L536.8 411.8 L540.1 404.3 L540.1 375.2 L536.8 366.2 L528.7 357.2 L516.8 350.6 L504.7 340 L496.6 329.6 L490.1 316.6 L485.3 296.3 L485.3 284.1 L486.9 273.5 L490.1 263 L495.8 251.7 L508 236.2 L521.7 225.8 L529.8 221.7 Z"), fill = SolidColor(Color.Black))
        clearGroup()
    }.build()
}
