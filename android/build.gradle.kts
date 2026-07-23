allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

subprojects {
    afterEvaluate {
        if (project.hasProperty("android")) {
            val android = project.extensions.findByName("android") as? com.android.build.gradle.BaseExtension
            android?.compileSdkVersion(36)
            
            try {
                val androidExtension = project.extensions.getByName("android")
                val methods = androidExtension.javaClass.methods
                val setNamespace = methods.find { it.name == "setNamespace" }
                val getNamespace = methods.find { it.name == "getNamespace" }
                
                if (setNamespace != null && getNamespace?.invoke(androidExtension) == null) {
                    setNamespace.invoke(androidExtension, project.group.toString())
                }
            } catch (_: Exception) {
                // Silencieux si l'extension n'est pas une librairie
            }
        }
    }
}

subprojects {
    if (project.path != ":app") {
        evaluationDependsOn(":app")
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
