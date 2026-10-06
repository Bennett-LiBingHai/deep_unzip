package com.bennett.deep_unzip

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * 解压期间的前台服务：**只为保住进程，不干别的活儿。**
 *
 * ## 为什么必须有它
 *
 * 解压跑在我们自己的 worker isolate 里，长任务动辄几分钟到几十分钟。这期间
 * 用户锁屏、切到别的应用、或者干脆把手机放兜里 —— 那时应用是后台进程，
 * 国产 ROM（尤其 MIUI 的 LMK）随时可以把它回收掉。表现是「解到一半回来一看，
 * 什么都没了」，而且没有任何错误提示：不是我们出的错，是进程没了。
 *
 * 前台服务是 Android 唯一官方认可的「我还在干活，别杀我」声明。它必须带一条
 * 常驻通知 —— 那既是代价也是好处：用户看得见进度，也看得见随时可以自己停。
 *
 * ## 为什么不是 `flutter_foreground_task`
 *
 * 那个插件能做这件事，但为了这件事要连带接受：开机自启的 `RebootReceiver`
 * （`RECEIVE_BOOT_COMPLETED` + 一个 `exported=true` 的接收器）、它自己的
 * 任务 isolate（我们不需要，活儿已经在 worker isolate 里跑着）、以及一个
 * `allowWakeLock` 默认打开的唤醒锁 —— 而我们真正需要的只有「保住进程」这一件事。
 * 上架要求「最小必要」逐条声明权限，那三样都得再花力气剥掉。
 *
 * 自己写就是下面这一百多行，零新增依赖，而且**复用已有的那条方法通道**
 * （见 `MainActivity` 的 `CHANNEL`），与 `freeSpace` 同一条路。
 *
 * ## 与 `wakelock_plus` 的区别（别再想加它）
 *
 * 唤醒锁分两种。这里要的是 **PARTIAL**（CPU 不休眠、**屏幕可以黑**）—— 前台
 * 服务本身就持有它。而 `wakelock_plus` 管的是 `SCREEN_BRIGHT`（屏幕一直亮着），
 * 那是另一回事：解压时强制亮屏二十分钟，用户既没法把手机放兜里，也白耗电池。
 *
 * 所以 `pubspec.yaml` 里**没有** `wakelock_plus`，也不该有。
 */
class ExtractKeepAliveService : Service() {

    /**
     * **不能写成 `private companion object`**：那样连 `MainActivity` 都够不着
     * 里面的 [start] —— 编译期就报 `Cannot access 'companion object Companion'`。
     * 收窄靠的是**逐个成员加 `private`**（下面除三个入口外全是 private），
     * 而不是把整个伴生对象藏起来。
     */
    companion object {
        private const val TAG = "DuzKeepAlive"

        /** 通知渠道 id。建过就不再建 —— 重复建会把用户改过的通知设置抹掉。 */
        private const val CHANNEL_ID = "duz_extract_progress"

        private const val CHANNEL_NAME = "解压进度"

        /**
         * 通知 id。**固定值**：它同时是「更新这条通知」和「撤掉这条通知」的句柄，
         * 每次 start 都换一个的话，旧的那条会永远挂在通知栏上撤不掉。
         */
        private const val NOTIFICATION_ID = 0x1001

        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"

        /**
         * 状态栏上那个小图标。
         *
         * ## 为什么不是 `R.mipmap.ic_launcher`
         *
         * 小图标从 Android 5 起**只取 alpha 通道**，颜色整个丢掉、系统自己染色。
         * 而 `ic_launcher` 是自适应图标，它的 `<background>` 是铺满的深色渐变 ——
         * 只有 `<foreground>` 会被蒙版裁。于是整张图的 alpha 是一块实心，
         * 蒙版取出来就是一个**白方块**。（API 24 / 25 上更直接：那时
         * `mipmap/ic_launcher` 就是张铺满的方形位图，同样一块白。）
         *
         * ## 为什么不是 `android.R.drawable.stat_sys_download`
         *
         * 这里原来用的是它。它确实是公开 API（`android.jar` 的
         * `android.R.drawable` 里有），也不会炸 —— 但 **OEM 会重画状态栏图标**，
         * MIUI / EMUI 上那个"下载"箭头长什么样各家不一样，换主题还会再变。
         * 现在有了自己的一份，观感就是定死的。
         *
         * `drawable-*dpi/ic_notification.png` 是 24dp 起的五档单色位图
         * （24/36/48/72/96），图形是「文档 + 向上箭头」。
         */
        private val SMALL_ICON_RES = R.drawable.ic_notification

        /**
         * 服务是不是活着。
         *
         * 自己记一个静态标志，而不是用 `ActivityManager.getRunningServices` ——
         * 那个方法从 API 26 起对第三方应用只返回自己的服务，行为在各家 ROM 上
         * 还不一致。我们只关心自己这一个服务的状态，静态标志够了。
         *
         * 代价说清楚：进程被杀之后这个标志会跟着没了（那时服务也确实没了，
         * 因为进程都没了）。所以它只在「同一个进程活着」这个前提下有意义 ——
         * 而那正是需要判断的那个前提。
         */
        @Volatile
        private var isRunning: Boolean = false

        /** 启动服务。供 `MainActivity` 调用。 */
        fun start(context: Context, title: String, text: String) {
            val intent = Intent(context, ExtractKeepAliveService::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /**
         * 更新通知上的那行字。服务没在跑时静默忽略。
         *
         * 用 `notify` 而不是再发一次 `startForeground`：后者每次都要走一遍
         * `onStartCommand`，进度一跳一次的话就成了拿启动服务当刷新用。
         */
        fun update(context: Context, title: String, text: String) {
            if (!isRunning) return
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, buildNotification(context, title, text))
        }

        /** 停服务并撤掉通知。没在跑时静默忽略（重复 stop 不该抛）。 */
        fun stop(context: Context) {
            if (!isRunning) return
            context.stopService(Intent(context, ExtractKeepAliveService::class.java))
        }

        /** 通知的公开构造。API 26 起必须带渠道 id。 */
        private fun buildNotification(
            context: Context,
            title: String,
            text: String
        ): Notification {
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }

            // 点一下回到应用 —— 没有 contentIntent 的话点通知毫无反应，用户会
            // 以为应用卡死了。
            val tapIntent = Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            val pending = PendingIntent.getActivity(
                context,
                0,
                tapIntent,
                // FLAG_IMMUTABLE 从 API 23 起可用（minSdk 24，安全）；
                // Android 12 起不带它会在启动时崩。
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

            return builder
                .setSmallIcon(SMALL_ICON_RES)
                // 展开通知后标题左边那个大图。**那一栏是原样彩色的**，系统也不会
                // 拿它做单色蒙版 —— 所以桌面图标该来的是这儿，而不是上面那格。
                .setLargeIcon(
                    Icon.createWithResource(context, R.mipmap.ic_launcher)
                )
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(pending)
                // 解压期间这条通知不该能被划掉：划掉等于用户以为自己停掉了它。
                .setOngoing(true)
                // 每次更新只换字，不再响一次 —— 否则进度一跳一响。
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .build()
        }

        /** 建通知渠道。API 26 起，没有渠道的通知**根本不会显示**。 */
        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return

            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                // LOW：不出声、不弹横幅。它是进度条，不是闹钟。
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "解压进行中的进度提示"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }

    /** CPU 唤醒锁：屏幕可以黑，但解压不能因为 CPU 睡了而停。 */
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "正在解压"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""

        try {
            ensureChannel(this)
            val notification = buildNotification(this, title, text)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            acquireWakeLock()
            isRunning = true
        } catch (e: Exception) {
            // Android 12+ 起，从后台起前台服务会抛 ForegroundServiceStartNotAllowed。
            // 正常路径上我们是在用户点了「开始解压」之后才起来的（那时应用在前台），
            // 撞不到；真撞到了也不能崩 —— 少一层保活而已，解压本身还在跑。
            //
            // 这里**必须记一条日志**：这条路失败之后，用户看到的现象是「锁屏后
            // 解压没了」，而现场什么都留不下。日志是唯一能分出「是服务没起来」
            // 还是「起来了还是被杀了」的证据。
            Log.e(TAG, "前台服务没起来，解压期间不保活", e)
            isRunning = false
            stopSelf()
        }

        // START_NOT_STICKY：被系统杀掉之后**不要**自动重来。活儿在 Dart 侧的内存里，
        // 进程没了就没有活儿了，重启一个服务只会留下一条说着谎的常驻通知。
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        releaseWakeLock()
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val manager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = manager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "DeepUnzip:ExtractWakeLock"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            // 拿不到唤醒锁不该让服务起不来：前台服务本身已经大幅降低被回收的
            // 概率，唤醒锁只是再加一层。
            Log.w(TAG, "没拿到唤醒锁，只靠前台服务保活", e)
            wakeLock = null
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let {
                if (it.isHeld) it.release()
            }
        } catch (e: Exception) {
            // 释放失败没有补救手段，也不影响正确性（进程退出时系统会回收）。
        }
        wakeLock = null
    }
}
