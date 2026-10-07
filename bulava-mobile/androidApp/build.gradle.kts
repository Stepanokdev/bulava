import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.androidApplication)
    alias(libs.plugins.composeCompiler)
}

val mobileVersion = Properties().apply { rootProject.file("version.properties").inputStream().use { load(it) } }

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_11
    }
}
dependencies {
    implementation(project(":shared"))

    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.core.ktx)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.compose.runtime)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)
    implementation(libs.mlkit.barcode)
    implementation(libs.androidx.glance.appwidget)

    implementation(libs.compose.uiToolingPreview)
    debugImplementation(libs.compose.uiTooling)
}

android {
    namespace = "com.stepanok.bulava"
    compileSdk = libs.versions.android.compileSdk.get().toInt()

    defaultConfig {
        applicationId = "com.stepanok.bulava"
        minSdk = libs.versions.android.minSdk.get().toInt()
        targetSdk = libs.versions.android.targetSdk.get().toInt()
        // One place for both platforms' version: bulava-mobile/version.properties.
        versionCode = mobileVersion.getProperty("build").toInt()
        versionName = mobileVersion.getProperty("version")
        // Phones are arm64; x86_64 is for emulators on Intel machines. The barcode reader ships
        // native code for every ABI otherwise, and triples the download.
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
    // The upload key lives in bulava-mobile/secrets/ on the release machine only (git ignores the
    // folder). Without it a release build is still made, unsigned, so CI and other machines build.
    val signing = rootProject.file("secrets/android-signing.properties")
    if (signing.exists()) {
        val p = Properties().apply { signing.inputStream().use { load(it) } }
        signingConfigs.create("release") {
            storeFile = rootProject.file("secrets/" + p.getProperty("storeFile"))
            storePassword = p.getProperty("storePassword")
            keyAlias = p.getProperty("keyAlias")
            keyPassword = p.getProperty("keyPassword")
        }
    }
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = signingConfigs.findByName("release")
        }
        // A release build signed with the debug key, for trying a shrunk build on a device before
        // the release keystore exists. Never for the site or a store.
        create("preview") {
            initWith(getByName("release"))
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += listOf("release")
            applicationIdSuffix = ".preview"
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    buildFeatures {
        compose = true
    }
}