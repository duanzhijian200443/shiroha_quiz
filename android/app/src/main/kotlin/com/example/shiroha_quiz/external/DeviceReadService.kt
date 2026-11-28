package com.example.shiroha_quiz.external

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock

/**
 * Non-exported foreground service that keeps the original engine/owner alive
 * for pure-question-READ windows. Holds no credentials, Grants, or Sessions.
 * Uses START_NOT_STICKY and stopWithTask="true": no sticky restart, boot
 * receiver, replacement engine, or restored Enable.
 */
class DeviceReadService : Service() {
    internal class Session(val ready: (Boolean) -> Unit, val withdrawn: () -> Unit) {
        val token: String = java.util.UUID.randomUUID().toString()
        @Volatile var running = false
        @Volatile var active = false
        @Volatile var ended = false
        @Volatile var service: DeviceReadService? = null
        @Volatile var startFailure: String? = null
        var stopping = false
        var stopFailed = false
        var stopTimeout: Runnable? = null
        val stopped = mutableListOf<(Boolean) -> Unit>()

        fun settled(clean: Boolean) {
            stopTimeout?.let { ownershipHandler.removeCallbacks(it) }
            stopTimeout = null
            stopFailed = !clean
            val callbacks = stopped.toList()
            stopped.clear()
            callbacks.forEach { it(clean) }
        }
    }

    companion object {
        const val CHANNEL = "shiroha_finite_read"
        private const val STOP = "stop_read"
        private const val NOTIFICATION = 46444
        private val ownershipHandler = Handler(Looper.getMainLooper())
        private var owner: Session? = null

        internal fun start(context: Context, session: Session) {
            check(owner == null)
            owner = session
            try {
                val intent = Intent(context, DeviceReadService::class.java)
                    .putExtra("session", session.token)
                val started = if (Build.VERSION.SDK_INT >= 26) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                if (started == null) throw DeviceLinkFailure("service_start_failed")
            } catch (error: Exception) {
                owner = null
                throw error
            }
        }

        internal fun finish(context: Context, session: Session, stopped: (Boolean) -> Unit = {}) {
            session.ended = true
            session.running = false
            if (owner === session) {
                if (session.stopFailed) {
                    stopped(false)
                    return
                }
                if (session.service == null) {
                    try {
                        context.stopService(Intent(context, DeviceReadService::class.java))
                    } catch (_: Exception) {
                        stopped(false)
                        return
                    }
                    owner = null
                    stopped(true)
                } else {
                    session.stopped.add(stopped)
                    if (session.stopping) return
                    session.stopping = true
                    try {
                        context.stopService(Intent(context, DeviceReadService::class.java))
                    } catch (_: Exception) {
                        session.settled(false)
                        return
                    }
                    val timeout = Runnable { session.settled(false) }
                    session.stopTimeout = timeout
                    ownershipHandler.postDelayed(timeout, 5000)
                }
            } else {
                stopped(session.service == null)
            }
        }

        internal fun prepareNotifications(context: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "题目只读访问", NotificationManager.IMPORTANCE_LOW)
            )
        }

        internal fun notifications(context: Context): Boolean {
            val manager = context.getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                val channel = manager.getNotificationChannel(CHANNEL)
                return manager.areNotificationsEnabled() &&
                    channel?.importance != NotificationManager.IMPORTANCE_NONE
            }
            return true
        }

        internal fun runningNotification(context: Context): Boolean {
            if (!notifications(context)) return false
            if (Build.VERSION.SDK_INT < 23) return true
            return context.getSystemService(NotificationManager::class.java)
                .activeNotifications.any { it.id == NOTIFICATION }
        }

        internal fun backgroundRunning(context: Context, session: Session?): Boolean =
            session?.active == true && session.running && !session.ended && runningNotification(context)
    }

    private val main = Handler(Looper.getMainLooper())
    private var original: Session? = null
    private val deadline = Runnable { revoke() }
    private val notificationWatch = object : Runnable {
        override fun run() {
            if (!backgroundRunning(this@DeviceReadService, original)) revoke()
            else main.postDelayed(this, 500)
        }
    }

    private fun notification(
        active: Boolean = false,
        remaining: Long? = null,
        continueWhileLocked: Boolean = false,
    ): Notification {
        val sessionToken = original!!.token
        val stop = PendingIntent.getService(
            this,
            0,
            Intent(this, DeviceReadService::class.java)
                .setAction(STOP)
                .setData(Uri.parse("shiroha-read:$sessionToken"))
                .putExtra("session", sessionToken),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(if (active) "Shiroha · 题目只读访问" else "Shiroha · 正在准备只读访问")
            .setContentText(
                when {
                    !active -> "保持前台，完成本轮访问准备"
                    remaining == null && continueWhileLocked -> "应用运行期间有效；锁屏可保留已认证客户端"
                    remaining == null -> "应用运行期间有效；锁屏或关闭即停止"
                    continueWhileLocked -> "已认证只读客户端可在锁屏时继续；到期或关闭即停止"
                    else -> "后台可继续；锁屏、到期或关闭即停止"
                }
            )
            .setWhen(System.currentTimeMillis() + (remaining ?: 0L))
            .setShowWhen(remaining != null)
            .setUsesChronometer(remaining != null)
            .setOngoing(true)
            .setDeleteIntent(stop)
            .addAction(
                Notification.Action.Builder(
                    null as android.graphics.drawable.Icon?,
                    "关闭访问",
                    stop,
                ).build()
            )
        if (Build.VERSION.SDK_INT >= 24) {
            builder.setChronometerCountDown(true)
        }
        if (Build.VERSION.SDK_INT >= 31) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    override fun onBind(intent: Intent?): android.os.IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val session = owner
        if (session == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        // A late start/notification from a prior owner cannot bind or stop a new one.
        if (intent?.getStringExtra("session") != session.token) return START_NOT_STICKY
        if (session.ended) {
            stopSelf()
            return START_NOT_STICKY
        }
        original = session
        session.service = this // Retain failed promotion too until real onDestroy.
        if (intent?.action == STOP) {
            revoke()
            return START_NOT_STICKY
        }
        try {
            if (!notifications(this)) throw IllegalStateException("notifications_unavailable")
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(
                    NOTIFICATION,
                    notification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                )
            } else {
                startForeground(NOTIFICATION, notification())
            }
            if (!session.running) {
                session.running = true
                // Preparation is bounded too; this never grants background READ.
                main.postDelayed(deadline, 120000)
                session.ready(true)
            }
        } catch (_: Exception) {
            session.ready(false)
            revoke()
        }
        return START_NOT_STICKY
    }

    /** Main-thread acknowledgement after promotion and the visible notification. */
    internal fun activate(ends: Long?, continueWhileLocked: Boolean): Boolean {
        val session = original ?: return false
        val remaining = ends?.minus(SystemClock.elapsedRealtime())
        if (session.ended || !session.running || session.active ||
            (remaining != null && remaining <= 0) || !runningNotification(this)
        ) return false
        try {
            getSystemService(NotificationManager::class.java).notify(
                NOTIFICATION,
                notification(
                    active = true,
                    remaining = remaining,
                    continueWhileLocked = continueWhileLocked,
                ),
            )
        } catch (_: Exception) {
            revoke()
            return false
        }
        session.active = true
        main.removeCallbacks(deadline)
        if (remaining != null) main.postDelayed(deadline, remaining)
        main.postDelayed(notificationWatch, 500)
        return true
    }

    private fun revoke() {
        val session = original ?: return
        if (!session.ended) {
            session.ended = true
            session.running = false
            session.active = false
            main.removeCallbacks(notificationWatch)
            session.withdrawn() // Native withdrawal precedes asynchronous Dart drain.
        }
        // Original owner stops this service after its drain attempt, not here.
    }

    override fun onDestroy() {
        main.removeCallbacks(deadline)
        main.removeCallbacks(notificationWatch)
        revoke()
        original?.service = null
        original?.let { session ->
            if (owner === session) owner = null
            session.settled(true)
        }
        super.onDestroy()
    }
}
