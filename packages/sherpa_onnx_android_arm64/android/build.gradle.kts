// Copyright 2026 hohu.org. Licensed under Apache-2.0.
plugins {
    id("com.android.library")
}

group = "org.hohu.momentai.speech"
version = "1.13.5"

android {
    namespace = "org.hohu.momentai.speech"
    compileSdk = 37
    ndkVersion = "28.2.13676358"
    defaultConfig {
        minSdk = 24
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

val verifyMomentaiRuntime = tasks.register("verifyMomentaiRuntime") {
    doLast {
        listOf("libsherpa-onnx-c-api.so", "libonnxruntime.so").forEach { name ->
            require(file("src/main/jniLibs/arm64-v8a/$name").isFile) {
                "Run python3 scripts/build_native_runtime.py --platform android first."
            }
        }
    }
}
tasks.named("preBuild").configure { dependsOn(verifyMomentaiRuntime) }
