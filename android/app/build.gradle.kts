// 必须显式 import：在 .kts 里裸写 `java.util.Properties` 会被 Gradle 的 `java`
// 扩展遮住，报 `Unresolved reference 'util'`（本机踩过）。
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名的材料。模板见 `android/key.properties.example`，那个文件没有密钥、
// 可以入库；真正的 `key.properties` 在 .gitignore 里。
//
// **读不到就退回 debug 签名，而不是让构建失败。** 这是个公开仓库，别人 clone
// 下来没有签名文件是常态，第一件事得是能编过、能装到手机上看。要出真正的发布包，
// 就把 key.properties 备好 —— 那时 `flutter build apk --release` 自动带上正确签名。
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { this.load(it) }
}
val releaseStoreFile = keystoreProperties.getProperty("storeFile")
val hasReleaseKey = !releaseStoreFile.isNullOrBlank()

android {
    namespace = "com.example.deep_unzip"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.deep_unzip"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(releaseStoreFile!!)
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 有 key.properties 就用它，没有就退回 debug 签名（见上面那段说明）。
            //
            // **debug 签名的包不能上架，也不能覆盖安装到别人机器上装过的版本** ——
            // 它只是为了让「clone 下来 `flutter build apk --release`」这件事能成。
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
