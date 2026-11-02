plugins {
    id("com.android.application")
    // Must come after the Android and Kotlin plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.luisnquin.upgrade"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 22 compiles against java.time, which
        // minSdk does not carry.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "dev.luisnquin.upgrade"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    sourceSets["main"].jniLibs.srcDirs(
        System.getenv("PROOT_ANDROID_LIBS")
            ?: error("PROOT_ANDROID_LIBS is unset; build from the nix dev shell"),
        System.getenv("ENGINE_ANDROID_LIBS")
            ?: error("ENGINE_ANDROID_LIBS is unset; build from the nix dev shell"),
    )
    // Plugins bring every locale's strings; the app ships English only.
    androidResources {
        localeFilters += "en"
    }
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            // TODO: a real signing config. Debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
        }
    }
}

// --target-platform only trims Flutter's own libraries, and a build-type abiFilters
// never reaches packaging: plugin libraries kept every ABI in the release apk.
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        // sherpa_onnx's Dart side opens only the C API.
        variant.packaging.jniLibs.excludes.addAll(
            "lib/x86_64/**",
            "lib/armeabi-v7a/**",
            "lib/*/libsherpa-onnx-cxx-api.so",
        )
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("org.tukaani:xz:1.10")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
