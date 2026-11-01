plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.shiroha_quiz"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // Explicit task installation; ordinary Debug/Release retain their identity.
    val androidReadValidation = providers.gradleProperty("androidReadValidation")
        .map { it == "true" }.getOrElse(false)
    val androidLinkIsolationValidation = providers.gradleProperty("androidLinkIsolationValidation")
        .map { it == "true" }.getOrElse(false)
    val androidLinkIsolationValidationTag = providers.gradleProperty("androidLinkIsolationValidationTag")
        .getOrElse("")
    check(!androidLinkIsolationValidation || androidReadValidation) {
        "Link isolation requires the explicit Android READ validation build."
    }
    check(androidLinkIsolationValidationTag.isEmpty() ||
        (androidLinkIsolationValidation && androidLinkIsolationValidationTag.matches(Regex("[a-z][a-z0-9]{0,23}")))) {
        "A fresh Link validation tag requires isolation and a bounded lowercase identifier."
    }
    val linkValidationApplicationId = "com.example.shiroha_quiz.linkvalidation" +
        if (androidLinkIsolationValidationTag.isEmpty()) "" else ".$androidLinkIsolationValidationTag"
    buildFeatures { buildConfig = true }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.shiroha_quiz"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("boolean", "ANDROID_READ_VALIDATION", "false")
        buildConfigField("String", "ANDROID_READ_VALIDATION_APPLICATION_ID", "\"\"")
        manifestPlaceholders["applicationLabel"] = "shiroha_quiz"
        manifestPlaceholders["androidNativeProofEnabled"] = "false"
    }

    buildTypes {
        debug {
            if (androidReadValidation) {
                applicationIdSuffix = if (androidLinkIsolationValidation)
                    linkValidationApplicationId.removePrefix("com.example.shiroha_quiz") else ".androidread"
                buildConfigField("boolean", "ANDROID_READ_VALIDATION", "true")
                buildConfigField("String", "ANDROID_READ_VALIDATION_APPLICATION_ID",
                    if (androidLinkIsolationValidation) "\"$linkValidationApplicationId\""
                    else "\"com.example.shiroha_quiz.androidread\"")
                if (androidLinkIsolationValidation) {
                    manifestPlaceholders["applicationLabel"] = "Shiroha Link validation"
                }
                manifestPlaceholders["androidNativeProofEnabled"] = "true"
            }
        }
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
