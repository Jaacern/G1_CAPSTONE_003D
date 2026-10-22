allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://gitlab.com/api/v4/projects/43396247/packages/maven") }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    // Fuerza a TODOS los plugins Android (health, image_picker, geolocator…) a
    // compilar contra Android SDK 36. Sin esto cada plugin usa su propio
    // compileSdk (algunos 34) y el build falla por metadata AAR incompatible.
    // Patrón para AGP 9 / Gradle 9: en afterEvaluate, sobre cualquier plugin de
    // Android (BasePlugin), si su compileSdk es menor al objetivo, se sube.
    afterEvaluate {
        plugins.withType<com.android.build.gradle.BasePlugin> {
            extensions.configure<com.android.build.gradle.BaseExtension> {
                val current =
                    (compileSdkVersion ?: "android-1").substring(8).toIntOrNull() ?: 0
                if (current < 36) {
                    compileSdkVersion(36)
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
