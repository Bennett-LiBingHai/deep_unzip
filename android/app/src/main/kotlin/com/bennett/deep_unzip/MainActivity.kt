package com.bennett.deep_unzip

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.os.StatFs
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 宿主 Activity。除了启动 Flutter 之外，它是**所有「得问系统」的能力的唯一出口**
 * （走下面那条 `CHANNEL`），目前三件：
 *
 * 1. 让系统文件管理器打开解压出来的那个目录（下面一大段注释都在讲它）。
 * 2. 量一个路径所在卷还剩多少字节（`freeSpace`，给炸弹/空间闸门用）。
 * 3. 解压期间起停那个保活的前台服务（`*KeepAlive`，见 `ExtractKeepAliveService`）。
 *
 * ## 为什么这件事得在原生做
 *
 * Android 没有「打开这个文件夹」的标准 Intent。往上能搜到的写法里有两类是坑：
 *
 * - `ACTION_VIEW` + `file://`：targetSdk ≥ 24 的 app 把 `file://` 交给别的 app 会抛
 *   `FileUriExposedException`，**直接崩**。网上大量示例还在这么写，因为那都是
 *   targetSdk 23 时代留下的。
 * - `FileProvider`：它只服务单个文件，不实现 `queryChildDocuments`，把**目录**
 *   交给别的 app 是列不出来的。别浪费时间去加 `file_paths.xml`。
 *
 * 能走通的是第三条：用系统自带的 `ExternalStorageProvider`，把路径翻成
 * `content://com.android.externalstorage.documents/document/<volumeId>:<相对路径>`，
 * 再把这份 `content://` URI 交给文件管理器。接收方不需要认识我们。
 *
 * ## 为什么结果有这么多档
 *
 * 因为「打开成功」有好几档含义。真正认识那个 URI 的是 AOSP 的 DocumentsUI，
 * 而**国产 ROM 经常把它换掉或包一层**；换掉之后就只剩「随便开一个文件管理器」
 * 这条兜底 —— 那也是「成功」，但用户眼前的界面根本没定位到目标目录。
 * 把这两种情况压成一个 `true`，界面就只能假装成功。所以往上如实回结果码，
 * 由 Dart 侧（见 `lib/services/file_manager_bridge.dart`）决定怎么跟用户说。
 *
 * ## 为什么必须**显式点名**组件，不能发隐式 Intent
 *
 * 真机上量出来的（Redmi Note 13 Pro / Android 16）：
 *
 * - `VIEW + vnd.android.document/directory` 有 **7 个**处理者 —— 除了
 *   DocumentsUI，还有夸克浏览器、百度网盘、UC、智慧树、以及另一个解压软件。
 *   隐式发出去就是一个「用哪个应用打开」的选择器。「打开输出目录」弹这个，
 *   等于请用户拿浏览器的文件夹视图去看解压结果。
 * - 而且 targetSdk 30+ 的 app 没有 `<queries>` 时**一个都看不见**，隐式 Intent
 *   连解析都失败，直接 `ActivityNotFoundException`。（这一条我一开始写反了：
 *   以为 `startActivity` 不受包可见性过滤 —— 那是「显式 Intent 不受过滤」，
 *   隐式照样受。）
 * - 本机的 DocumentsUI 是**小米塞的 Google 版**，包名
 *   `com.google.android.documentsui`，而类名还是 AOSP 的
 *   `com.android.documentsui.files.FilesActivity`。点名 AOSP 包名会
 *   `START_CLASS_NOT_FOUND`。所以包名要两条都试。
 *
 * 结论：先用 `<queries>` 放行的 `queryIntentActivities` 问出**设备上真实存在**
 * 的 DocumentsUI，逐个显式开；问不出来再猜两个已知包名。隐式 Intent 只留一道，
 * 排在最后当兜底。
 */
class MainActivity : FlutterActivity() {

    private companion object {
        /** 方法通道名。**必须与 `file_manager_bridge.dart` 里的逐字一致。** */
        const val CHANNEL = "com.bennett.deep_unzip/native"

        /** 系统 ExternalStorageProvider 的 authority。 */
        const val EXTERNAL_STORAGE_AUTHORITY = "com.android.externalstorage.documents"

        /**
         * DocumentsUI 的文件浏览界面。**类名在 AOSP 与 Google 版上是一样的**，
         * 不一样的是包名 —— 见 [KNOWN_DOCUMENTSUI_PACKAGES]。
         */
        const val DOCUMENTSUI_FILES_ACTIVITY = "com.android.documentsui.files.FilesActivity"

        /**
         * 已知的 DocumentsUI 包名，两个都试。
         *
         * 第一个是 Google 版（小米等 ROM 直接塞的这个，本机实测就是它）；
         * 第二个是 AOSP 原版。`queryIntentActivities` 那一路问不出来时靠这个兜底。
         */
        val KNOWN_DOCUMENTSUI_PACKAGES =
            listOf("com.google.android.documentsui", "com.android.documentsui")

        /** 主存储卷的 docId 前缀。`StorageVolume.getUuid()` 对主卷返回 null。 */
        const val PRIMARY_VOLUME_ID = "primary"

        // ===== 结果码 =====
        // **Dart 侧 `FileManagerBridge._parse` 认的就是这几个字面量。改这里必须同步改那边。**

        /** 精确打开到了目标目录。 */
        const val R_OPENED = "opened"

        /** 只打开了某个文件管理器，没定位到目标目录。 */
        const val R_OPENED_GENERIC = "opened_generic"

        /** 路径不在任何外部存储卷上（或不存在），系统 provider 表达不了它。 */
        const val R_UNSUPPORTED_PATH = "unsupported_path"

        /** 设备上没有能处理它的文件管理器。 */
        const val R_NO_HANDLER = "no_handler"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 弹窗和 startActivity 都要主线程，方法通道默认就在主线程回调。
                    "openFolderInFileManager" ->
                        result.success(openFolderInFileManager(call.argument<String>("path")))
                    "freeSpace" ->
                        result.success(freeSpace(call.argument<String>("path")))
                    // ===== 解压期间的前台服务（保活，见 ExtractKeepAliveService）=====
                    // 三条都回 true/false「叫没叫动」，**不回「现在是不是在跑」**：
                    // Dart 侧只关心自己那次调用有没有得逞，拿一个可能有延迟的
                    // 状态回去做判断只会多出一类竞态。三个方法都是幂等的。
                    "startKeepAlive" -> {
                        ExtractKeepAliveService.start(
                            this,
                            call.argument<String>("title") ?: "正在解压",
                            call.argument<String>("text") ?: ""
                        )
                        result.success(true)
                    }
                    "updateKeepAlive" -> {
                        ExtractKeepAliveService.update(
                            this,
                            call.argument<String>("title") ?: "正在解压",
                            call.argument<String>("text") ?: ""
                        )
                        result.success(true)
                    }
                    "stopKeepAlive" -> {
                        ExtractKeepAliveService.stop(this)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 打开 [path] 所在的目录，返回上面那组结果码之一。
     *
     * 不抛异常：所有失败都折进返回值，调用方按字符串分支。
     */
    private fun openFolderInFileManager(path: String?): String {
        if (path.isNullOrEmpty()) return R_UNSUPPORTED_PATH

        val uri = documentUriFor(path) ?: return R_UNSUPPORTED_PATH

        // 逐个点名 DocumentsUI。只要有一个起得来就算成功 ——
        // 注意「起得来」只说明这个组件接受了 Intent，不代表它乖乖跳到了目标
        // 目录（那是它的事，我们查不了）。所以下面还有 generic 一档。
        for (component in documentsUiCandidates()) {
            if (tryStart(documentsUiIntent(uri).setComponent(component))) {
                return R_OPENED
            }
        }

        // 设备上认 content:// 目录 URI 的 app 可能一个都不叫 documentsui
        // （包名对不上、或者 `<queries>` 跟新 ROM 对不上，两条路都落空）。
        // 隐式发一道 —— 代价是装了几个处理者的话会弹选择器，所以排在最后，
        // 而且必须在 generic 之前：它至少还带着目标目录。
        if (tryStart(documentsUiIntent(uri))) return R_OPENED

        // 最后一档：不指定目录，只要能开出一个文件管理器。
        // 如实回 opened_generic，界面会把路径摆给用户让他自己点进去。
        if (tryStart(genericFilesIntent())) return R_OPENED_GENERIC

        return R_NO_HANDLER
    }

    /**
     * 能开目录、且包名像 DocumentsUI 的组件，按可信度排序。
     *
     * 见类注释：为什么不能用隐式 Intent，以及为什么包名要试两个。
     * 显式 Intent 打别的 app 没导出的组件会吃 `SecurityException`，
     * [tryStart] 一并当「没找到」处理。
     */
    private fun documentsUiCandidates(): List<ComponentName> {
        val out = LinkedHashSet<ComponentName>()

        // 1. 问系统要设备上**真实存在**的处理者，只留包名像 DocumentsUI 的。
        //    这一条能扛住 OEM 改名，优先于任何写死的名字。
        val query = Intent(Intent.ACTION_VIEW)
            .setType(DocumentsContract.Document.MIME_TYPE_DIR)
            .addCategory(Intent.CATEGORY_DEFAULT)
        packageManager.queryIntentActivities(query, 0)
            .map { it.activityInfo }
            .filter { it.packageName.contains("documentsui", ignoreCase = true) }
            .forEach { out += ComponentName(it.packageName, it.name) }

        // 2. 猜名字兜底。上一步依赖 Manifest 里的 `<queries>` 与 ROM 对得上，
        //    对不上时这里是最后的机会。
        KNOWN_DOCUMENTSUI_PACKAGES.forEach {
            out += ComponentName(it, DOCUMENTSUI_FILES_ACTIVITY)
        }

        return out.toList()
    }

    /**
     * 「这是一份目录」—— 正规写法，带 MIME type。DocumentsUI 收到后会直接
     * 跳进这个目录。
     */
    private fun documentsUiIntent(uri: Uri): Intent =
        Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)

    /**
     * 「随便开个文件管理器」。不带目标目录 —— 这一档的用户体验就是「界面开了，
     * 但停在别处」，所以它是 [R_OPENED_GENERIC] 而不是 [R_OPENED]。
     *
     * `CATEGORY_APP_FILES` 是 API 29 才加的常量，但它是编译期内联的字符串，
     * 在 minSdk 24 的设备上引用不会炸；匹配不到就是 `ActivityNotFoundException`，
     * 由 [tryStart] 吃掉。
     */
    private fun genericFilesIntent(): Intent =
        Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_APP_FILES)

    /**
     * 起一个 Intent，只回答「有没有 app 接受它」。
     *
     * **不要换成 `resolveActivity`**：包可见性规则下（API 30+ 默认收紧）它会因为
     * 看不见对方的 `<queries>` 而返回 null，把能用的路径误判成不能用。
     * 「直接试、捕异常」是官方推荐的替代写法。
     */
    private fun tryStart(intent: Intent): Boolean = try {
        startActivity(intent)
        true
    } catch (e: ActivityNotFoundException) {
        false
    } catch (e: SecurityException) {
        // 显式点名了别的 app 没导出的组件。当没找到处理者。
        false
    }

    /**
     * 文件系统路径 → `ExternalStorageProvider` 的 document URI。
     *
     * 返回 null 表示系统 provider 表达不了这个路径（不在任何已挂载的外部存储卷上、
     * 或者不是目录）。
     *
     * **绝不允许手工拼 URI 字符串。** docId 里的 `:`、`/` 以及路径本身的中文和空格
     * 都要编码，手拼出来的在 `/sdcard/我的 下载/` 这类路径上必然坏，而且坏得很难查。
     * `DocumentsContract.buildDocumentUri` 就是干这件事的。
     */
    private fun documentUriFor(path: String): Uri? {
        val target = try {
            File(path).canonicalFile
        } catch (e: Exception) {
            // canonicalFile 在极端路径上会抛 IOException。
            return null
        }
        // 注意：这里没权限时会把「没权限」误判成「不存在」。可以接受 ——
        // 没有存储权限的话扫描阶段就跑不出结果，也走不到这个按钮。
        if (!target.isDirectory) return null

        val targetPath = target.path
        for ((volumeId, root) in externalVolumeRoots()) {
            val rootPath = root.path
            val relative = when {
                targetPath == rootPath -> ""
                targetPath.startsWith("$rootPath/") -> targetPath.substring(rootPath.length + 1)
                else -> continue
            }
            // 卷根自己的 docId 是 `primary:`（appendPath 会编码成 `primary%3A`）。
            val docId = "$volumeId:$relative"
            return DocumentsContract.buildDocumentUri(EXTERNAL_STORAGE_AUTHORITY, docId)
        }
        return null
    }

    /**
     * [path] 所在卷还剩多少字节；量不到回 null。
     *
     * ## 为什么路径可能还不存在
     *
     * 调用它的是炸弹/空间闸门，那道闸门**刻意排在建输出目录之前** —— 被拒的包
     * 不该在磁盘上留下一个空目录。所以 [path] 经常是个还不存在的路径，
     * `StatFs` 对它要么抛异常要么给出垃圾。这里向上找**最近的已存在祖先**再量：
     * 同一个卷，答案一样。
     *
     * 也不能退回 `getExternalStorageDirectory()` 了事 —— 那在可移动卷上会
     * 量错卷，而「还剩 60 GB」和「还剩 0 GB」是两个相反的结论。
     *
     * 回 null 而不是 0：Dart 侧把 null 当「不知道」并跳过检查，把 0 当
     * 「一格不剩」并拒绝每一个包。这两者搞混是灾难性的。
     */
    private fun freeSpace(path: String?): Long? {
        if (path.isNullOrEmpty()) return null

        // 向上找到第一个真实存在的祖先。循环上限 64 层，防「路径本身就是坏的」
        // 时一路爬到根 —— 正常路径三四层就到了。
        var probe: File? = File(path)
        var hops = 0
        while (probe != null && !probe.exists() && hops < 64) {
            probe = probe.parentFile
            hops++
        }
        val target = probe ?: return null

        return try {
            StatFs(target.path).availableBytes
        } catch (e: IllegalArgumentException) {
            // 路径不是文件系统上的真实位置（比如空串、或某些 ROM 上的怪路径）。
            null
        }
    }

    /**
     * 已挂载的外部存储卷 → (volumeId, 卷根目录)。
     *
     * 主卷的 id 是字面量 `primary`；可移动卷用自己的 UUID（形如 `1234-5678`）。
     * `ExternalStorageProvider` 的 docId 前缀认这两个。
     *
     * 可移动卷的**卷根是从 `getExternalFilesDirs` 反推的** —— API 24–29 上没有
     * 公开 API 能直接拿卷根（`StorageVolume.getDirectory()` 要 API 30），而
     * `getExternalFilesDirs` 返回的路径形如
     * `/storage/1234-5678/Android/data/<pkg>/files`，砍掉 `/Android/` 之后就是卷根。
     */
    private fun externalVolumeRoots(): List<Pair<String, File>> {
        val roots = LinkedHashMap<String, File>()

        Environment.getExternalStorageDirectory()?.let {
            roots[PRIMARY_VOLUME_ID] = it
        }

        getExternalFilesDirs(null)?.forEach { dir ->
            val full = dir?.canonicalPath ?: return@forEach
            val idx = full.indexOf("/Android/")
            if (idx <= 0) return@forEach
            val rootPath = full.substring(0, idx)
            // 主卷也会从这条路冒出来（rootPath == /storage/emulated/0），去重。
            if (roots.values.any { it.path == rootPath }) return@forEach
            roots[rootPath.substringAfterLast('/')] = File(rootPath)
        }

        return roots.entries.map { it.key to it.value }
    }
}
