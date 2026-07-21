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

    afterEvaluate {
        if (project.hasProperty("android")) {
            val android = project.extensions.findByName("android") as? com.android.build.gradle.BaseExtension
            android?.compileSdkVersion(36)
            
            // Correction automatique du Namespace pour les plugins obsolètes comme raw_gnss
            // On utilise une approche plus simple compatible KTS
            try {
                val androidExtension = project.extensions.getByName("android")
                val namespaceProperty = androidExtension::class.java.methods.find { it.name == "setNamespace" }
                if (namespaceProperty != null) {
                    val currentNamespace = androidExtension::class.java.methods.find { it.name == "getNamespace" }?.invoke(androidExtension)
                    if (currentNamespace == null) {
                        namespaceProperty.invoke(androidExtension, project.group.toString())
                    }
                }
            } catch (e: Exception) {
                // Silencieux si l'extension n'est pas une librairie
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
