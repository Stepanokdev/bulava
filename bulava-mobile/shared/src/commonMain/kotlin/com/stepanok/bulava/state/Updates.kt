package com.stepanok.bulava.state

import com.stepanok.bulava.link.ErrorCodes
import com.stepanok.bulava.link.Home
import com.stepanok.bulava.link.LinkProtocol
import com.stepanok.bulava.link.LinkState
import com.stepanok.bulava.link.PhoneApp

/**
 * What the banner at the top says about versions, if anything.
 *
 * Two different things, kept apart the way Slack keeps an optional update apart from an enforced
 * minimum, and named the way Signal names the device to update:
 *
 * - **One side is too old for the other.** The Mac turned this phone away and said which side:
 *   `protocol_too_old` — this app; `protocol_too_new` — Bulava on the Mac. Not dismissible, since
 *   nothing works until it is done, and it does not take the screen: the chats already here stay
 *   readable and drafts stay where they are.
 * - **A newer app is out.** The Mac read bulava.app for it (the phone looks nothing up itself) and
 *   says so in its `home`; this phone's build is older. Dismissible, and dismissed per build: the
 *   next release asks again, this one does not.
 */
sealed interface UpdateNotice {
    /** This phone's app must be updated before it can talk to the Mac. */
    data class PhoneTooOld(
        val installed: String,
        val macName: String,
        val macVersion: String?,
        /** The newest the Mac knows of, when it said: "1.1". */
        val newest: String?,
        val url: String,
    ) : UpdateNotice

    /** Bulava on the Mac must be updated before this phone can talk to it. */
    data class MacTooOld(val macName: String, val macVersion: String?, val installed: String) : UpdateNotice

    /** A newer phone app is out; nothing is broken. */
    data class Available(val installed: String, val newest: PhoneApp) : UpdateNotice
}

object Updates {
    /**
     * Where an update is when the Mac has not said: the TestFlight invitation an iPhone was
     * installed from (the one `site/render.py` puts on the download page), and the download page
     * itself for Android, whose button is the APK.
     */
    const val TESTFLIGHT = "https://testflight.apple.com/join/wtWcPjb1"

    fun fallbackUrl(platform: String) = if (platform == "ios") TESTFLIGHT else LinkProtocol.DOWNLOAD_PAGE

    /**
     * The banner for this moment. [dismissedBuild] is the newest build the person already said
     * "not now" to; [installedBuild] is 0 where the build cannot be read, and then no optional
     * update is offered — a guess would offer the update to the very build it is.
     */
    fun decide(
        link: LinkState,
        home: Home?,
        platform: String,
        installed: String,
        installedBuild: Int,
        dismissedBuild: Int?,
    ): UpdateNotice? {
        if (link is LinkState.Incompatible) {
            return when (link.code) {
                ErrorCodes.PROTOCOL_TOO_OLD -> {
                    val newest = link.phoneApps?.forPlatform(platform)
                    UpdateNotice.PhoneTooOld(
                        installed = installed, macName = link.macName, macVersion = link.desktopVersion,
                        newest = newest?.version?.ifBlank { null },
                        url = newest?.url?.takeIf { it.startsWith("https://") } ?: fallbackUrl(platform),
                    )
                }
                ErrorCodes.PROTOCOL_TOO_NEW -> UpdateNotice.MacTooOld(link.macName, link.desktopVersion, installed)
                else -> null
            }
        }
        val newest = home?.phoneApps?.forPlatform(platform) ?: return null
        if (installedBuild <= 0 || newest.build <= installedBuild) return null
        if (!newest.url.startsWith("https://") || newest.version.isBlank()) return null
        if (dismissedBuild != null && dismissedBuild >= newest.build) return null
        return UpdateNotice.Available(installed, newest)
    }

    /** Where "not now" to an update is kept: the build it was said to. */
    const val DISMISSED = "bulava.update.dismissed"
}
