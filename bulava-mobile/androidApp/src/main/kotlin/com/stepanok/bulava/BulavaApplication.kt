package com.stepanok.bulava

import android.app.Application
import com.stepanok.bulava.platform.AndroidComponents
import com.stepanok.bulava.platform.AndroidPlatform
import com.stepanok.bulava.state.AppController
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import com.stepanok.bulava.widgets.redrawWeekWidgets
import com.stepanok.bulava.widgets.refreshWeekPreviews

/**
 * One controller for the whole process: the screen and the background service share the same
 * connection to the Mac, so a request that arrives while the app is closed is the same request the
 * screen shows when it opens.
 */
class BulavaApplication : Application() {
    lateinit var platform: AndroidPlatform
        private set
    lateinit var controller: AppController
        private set

    /** Lives as long as the process: work started by a notification button finishes here. */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    override fun onCreate() {
        super.onCreate()
        platform = AndroidPlatform(
            this,
            AndroidComponents(
                mainActivity = MainActivity::class.java,
                linkService = LinkService::class.java,
                answerActivity = NotificationAnswerActivity::class.java,
                notificationIcon = R.drawable.ic_stat_bulava,
                requestsChannelName = getString(R.string.channel_requests),
                finishedChannelName = getString(R.string.channel_finished),
                linkChannelName = getString(R.string.channel_link),
                weekChanged = { context -> scope.launch { redrawWeekWidgets(context) } },
            ),
        )
        controller = AppController(platform, scope) { System.currentTimeMillis() }
        scope.launch { refreshWeekPreviews(this@BulavaApplication) }
    }
}
