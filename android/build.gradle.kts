allprojects {
    repositories {
        google()
        mavenCentral()
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
    project.evaluationDependsOn(":app")
}

// Post-Flutter-3.47 upgrade (2026-08-27): Kotlin 2.2 turned the JVM-target
// consistency check into a hard ERROR, and third-party plugin modules
// (tflite_flutter: Java 11 vs Kotlin 21) fail it. We can't repin their
// finalized compileOptions from here; the supported knob is
// `kotlin.jvm.target.validation.mode=warning` in gradle.properties
// (restores the pre-2.x lenient behavior for code we don't own).


tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
