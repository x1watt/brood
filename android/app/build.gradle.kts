plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.x1watt.brood"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.x1watt.brood"
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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

// The game files go into the APK under assets/BROOD (MainActivity.kt copies
// them into the app's storage at first start): the three MPQs and the melee
// maps from BROOD_DATA, default ~/box/media/games/BROOD. The browser version
// (build/web, from tool/build_web.sh, without its copy of the game files)
// goes under assets/web, for sharing the game on the network
// (lib/net/lan_host.dart).
val broodData = System.getenv("BROOD_DATA") ?: "${System.getProperty("user.home")}/box/media/games/BROOD"
val gameAssets = layout.buildDirectory.dir("generated/brood_game_files").get().asFile
val webBuild = file("../../build/web")
val copyGameFiles by tasks.registering(Sync::class) {
    if (!file("$broodData/StarDat.mpq").exists()) {
        logger.warn("No game files in $broodData: the APK will not include them.")
    }
    if (!file("$webBuild/index.html").exists()) {
        logger.warn("No browser version in $webBuild (tool/build_web.sh): the APK can't share the game on the network.")
    }
    from(webBuild) {
        exclude("gamedata/**")
        into("web")
    }
    from(broodData) {
        include("StarDat.mpq", "BrooDat.mpq", "Patch_rt.mpq", "maps/**/*.scm", "maps/**/*.scx")
        exclude("maps/campaign/**", "maps/scenario/**", "maps/save/**")
        into("BROOD")
    }
    into(gameAssets)
}
android.sourceSets["main"].assets.srcDir(gameAssets)
tasks.named("preBuild") { dependsOn(copyGameFiles) }

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
