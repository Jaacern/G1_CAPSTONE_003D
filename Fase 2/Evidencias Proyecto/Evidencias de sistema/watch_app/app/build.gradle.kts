plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.agecare.watch"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.agecare.watch"
        minSdk = 30            // Wear OS 3+ (Galaxy Watch 4 y superiores)
        targetSdk = 34
        versionCode = 1
        versionName = "0.1"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation(platform("androidx.compose:compose-bom:2024.09.03"))
    implementation("androidx.compose.runtime:runtime")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.ui:ui")
    // Componentes Compose específicos de Wear OS.
    implementation("androidx.wear.compose:compose-material:1.4.0")
    implementation("androidx.wear.compose:compose-foundation:1.4.0")
    // Red (envío al backend).
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // Samsung Health Sensor SDK (sensores del Galaxy Watch: HR, SpO2, temperatura
    // de piel). Librería local .aar descargada del portal Samsung. Funciona con
    // el modo desarrollador de Health Sensor Service activado en el reloj.
    implementation(files("libs/samsung-health-sensor-api-1.4.1.aar"))
    // Health Services de Wear OS (respaldo de HR; también se usa como fallback).
    implementation("androidx.health:health-services-client:1.1.0-alpha05")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("androidx.concurrent:concurrent-futures-ktx:1.2.0")
    implementation("androidx.lifecycle:lifecycle-service:2.8.6")
    // Almacenamiento cifrado del token de dispositivo (emparejamiento por código).
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    // ListenableFuture (lo exponen las APIs async de Health Services).
    implementation("com.google.guava:guava:33.3.1-android")
}
