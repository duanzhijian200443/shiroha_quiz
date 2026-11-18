package com.example.shiroha_quiz.external

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.*

/** Keeps the original engine/owner alive; holds no credential, Grant or Session.
 * No sticky restart, boot receiver, replacement engine or restored Enable.
 */
class DeviceReadService : Service() {
    internal class Session(val ready: (Boolean) -> Unit, val withdrawn: () -> Unit) {
        val token = java.util.UUID.randomUUID().toString()
        @Volatile var running = false
        @Volatile var ended = false
        var service: DeviceReadService? = null
        var stopping = false
        var stopFailed = false
        val stopped = mutableListOf<(Boolean) -> Unit>()
        fun settled(clean: Boolean) {
            if (!clean) stopFailed = true
            val callbacks = stopped.toList(); stopped.clear()
            callbacks.forEach { it(clean) }
        }
    }
    companion object {
        const val CHANNEL = "shiroha_finite_read"
        private const val STOP = "stop_read"
        private const val NOTIFICATION = 46444
        @Volatile private var owner: Session? = null
        internal fun start(context: Context, session: Session) {
            check(owner == null)
            owner = session
            try { context.startForegroundService(Intent(context, DeviceReadService::class.java).putExtra("session", session.token)) }
            catch (error: Exception) { owner = null; throw error }
        }
        internal fun finish(context: Context, session: Session, stopped: (Boolean) -> Unit = {}) {
            session.ended = true; session.running = false
            if (session.stopFailed) { stopped(false); return }
            if (owner === session) {
                if (session.service == null) {
                    try { context.stopService(Intent(context, DeviceReadService::class.java)) }
                    catch (_: Exception) { stopped(false); return }
                    owner = null; stopped(true) // No original service was acquired.
                } else {
                    session.stopped.add(stopped)
                    if (session.stopping) return
                    session.stopping = true
                    try { context.stopService(Intent(context, DeviceReadService::class.java)) }
                    catch (_: Exception) { session.settled(false); return }
                    Handler(Looper.getMainLooper()).postDelayed({
                        session.settled(false)
                    }, 5000)
                }
            } else stopped(session.service == null)
        }
        internal fun prepareNotifications(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "限时题目只读访问", NotificationManager.IMPORTANCE_LOW))
        }
        internal fun notifications(context: Context): Boolean {
            val manager = context.getSystemService(NotificationManager::class.java)
            val channel = manager.getNotificationChannel(CHANNEL) ?: return false
            return manager.areNotificationsEnabled() && channel.importance != NotificationManager.IMPORTANCE_NONE
        }
        internal fun runningNotification(context: Context) = notifications(context) &&
            context.getSystemService(NotificationManager::class.java).activeNotifications.any { it.id == NOTIFICATION }
    }
    private val main = Handler(Looper.getMainLooper())
    private var original: Session? = null
    private val deadline = Runnable { revoke() }
    private fun notification(remaining: Long? = null, continueWhileLocked: Boolean = false): Notification {
        val stop = PendingIntent.getService(this, 0,
            Intent(this, DeviceReadService::class.java).setAction(STOP)
                .setData(android.net.Uri.parse("shiroha-read:" + original!!.token))
                .putExtra("session", original!!.token), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(if (remaining == null) "Shiroha · 正在准备只读访问" else "Shiroha · 限时题目只读访问")
            .setContentText(when {
                remaining == null -> "保持前台，完成本轮访问证明"
                continueWhileLocked -> "已有只读连接可在锁屏时继续；到期或关闭即停止"
                else -> "后台可继续；锁屏、到期或关闭即停止"
            })
            .setWhen(System.currentTimeMillis() + (remaining ?: 0))
            .setUsesChronometer(remaining != null).setChronometerCountDown(true)
            .setOngoing(true).setDeleteIntent(stop)
            .addAction(Notification.Action.Builder(null, "关闭访问", stop).build()).build()
    }
    override fun onBind(intent: Intent?) = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val session = owner
        if (session == null) { stopSelf(); return START_NOT_STICKY }
        // A late start/notification from a prior owner cannot bind or stop a new one.
        if (intent?.getStringExtra("session") != session.token) return START_NOT_STICKY
        if (session.ended) { stopSelf(); return START_NOT_STICKY }
        original = session
        session.service = this // Retain failed promotion too until real onDestroy.
        if (intent?.action == STOP) { revoke(); return START_NOT_STICKY }
        try {
            if (!notifications(this)) throw IllegalStateException()
            if (Build.VERSION.SDK_INT >= 29)
                startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            else startForeground(NOTIFICATION, notification())
            if (!session.running) {
                session.running = true
                // Preparation is bounded too; this never grants background READ.
                main.postDelayed(deadline, 120000)
                session.ready(true)
            }
        } catch (_: Exception) { session.ready(false); revoke() }
        return START_NOT_STICKY
    }
    internal fun activated(ends: Long, continueWhileLocked: Boolean) {
        main.post {
            main.removeCallbacks(deadline)
            val remaining = ends - SystemClock.elapsedRealtime()
            if (remaining <= 0 || original?.running != true) revoke()
            else {
                try {
                    getSystemService(NotificationManager::class.java).notify(NOTIFICATION,
                        notification(remaining, continueWhileLocked))
                }
                catch (_: Exception) { revoke(); return@post }
                main.postDelayed(deadline, remaining)
            }
        }
    }
    private fun revoke() {
        val session = original ?: return
        if (!session.ended) {
            session.ended = true; session.running = false
            session.withdrawn() // Native withdrawal precedes asynchronous Dart drain.
        }
        // Original owner stops this service after its drain attempt, not here.
    }
    override fun onDestroy() {
        main.removeCallbacks(deadline)
        revoke()
        original?.service = null
        original?.let { session ->
            if (owner === session) owner = null
            session.settled(true)
        }
        super.onDestroy()
    }
}
