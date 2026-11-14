import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library") version "8.11.1"
    id("org.jetbrains.kotlin.android") version "2.2.20"
    `maven-publish`
}

group = "io.dockhive"
version = "0.1.0"

android {
    namespace = "io.dockhive.push"
    compileSdk = 36

    defaultConfig {
        minSdk = 23
        consumerProguardFiles("consumer-rules.pro")
        buildConfigField("String", "SDK_VERSION", "\"${project.version}\"")
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_11)
    }
}

dependencies {
    api("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // The app adds Firebase Messaging itself (it also needs google-services.json);
    // the SDK only uses it for HivePushMessagingService and registerWithFirebase().
    compileOnly("com.google.firebase:firebase-messaging:25.1.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("org.json:json:20240303")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = "io.dockhive"
            artifactId = "push"
            version = project.version.toString()
            afterEvaluate {
                from(components["release"])
            }
            pom {
                name.set("Hive Push for Android")
                description.set("Native push notifications and an in-app inbox for Android apps, with Hive Push.")
                licenses {
                    license {
                        name.set("MIT")
                        url.set("https://opensource.org/licenses/MIT")
                    }
                }
            }
        }
    }
}
