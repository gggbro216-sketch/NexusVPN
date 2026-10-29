plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

// Compile-only inputs (not bundled into the plugin AAR):
//  - godot-lib: provided by the Godot export at build time
//  - libbox.aar: shipped next to the plugin AAR and added by the export plugin
// tools/build_android_plugin.sh extracts their classes.jar into libs/.
val libsDir = layout.projectDirectory.dir("libs")

android {
    namespace = "com.nexusvpn.bridge"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    compileOnly(files(libsDir.file("godot-lib-classes.jar")))
    compileOnly(files(libsDir.file("libbox-classes.jar")))
    // Declared again in the Godot export plugin (_get_android_dependencies) so the
    // final APK gets them; versions must stay in sync with export_plugin.gd.
    compileOnly("com.google.zxing:core:3.5.3")
    compileOnly("com.google.android.gms:play-services-code-scanner:16.1.0")
}
