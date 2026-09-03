import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("io.sentry.android.gradle")
}

// Clé de signature release (jamais commitée, cf. android/key.properties.example
// et .gitignore) : android/key.properties doit exister localement, avec les
// vraies valeurs, avant de produire un AAB release.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.meshiker.app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.meshiker.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String?
            }
        }
    }

    buildTypes {
        release {
            // Signature release réelle si android/key.properties existe et est
            // rempli ; sinon repli sur la clé debug pour que `flutter run
            // --release` continue de fonctionner sans configuration locale.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// Upload automatique du mapping ProGuard/R8 vers Sentry à chaque build
// release (spec-crash-reporting.md §3.3). Le token est lu depuis
// `sentry.properties` à la racine du repo Flutter (généré par le wizard
// Sentry, jamais commité — cf. .gitignore), avec la même logique que
// `key.properties` ci-dessus : sans ce fichier localement, l'upload est
// simplement désactivé plutôt que de faire échouer `flutter build apk`.
// Le format attendu (`auth_token=...`, sans préfixe) est celui lu par
// `sentry_dart_plugin` (voir pubspec.yaml, bloc `sentry:` pour org/projet) ;
// on le réutilise ici tel quel plutôt que de dépendre de la découverte
// automatique du fichier par le plugin Gradle (chemin non garanti selon
// le répertoire de travail de Gradle).
val sentryProperties = Properties()
val sentryPropertiesFile = rootProject.file("../sentry.properties")
if (sentryPropertiesFile.exists()) {
    sentryProperties.load(FileInputStream(sentryPropertiesFile))
}
val sentryAuthToken = sentryProperties.getProperty("auth_token")

sentry {
    org.set("rosaweb")
    projectName.set("meshiker")
    authToken.set(sentryAuthToken)
    autoUploadProguardMapping.set(sentryAuthToken != null)
}

flutter {
    source = "../.."
}
