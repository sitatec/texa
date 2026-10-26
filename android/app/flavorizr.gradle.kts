import com.android.build.gradle.AppExtension

val android = project.extensions.getByType(AppExtension::class.java)

android.apply {
    flavorDimensions("app")

    productFlavors {
        create("dev") {
            dimension = "app"
            applicationId = "dev.berete.texa.dev"
            resValue(type = "string", name = "app_name", value = "Texa Dev")
        }
        create("staging") {
            dimension = "app"
            applicationId = "dev.berete.texa.staging"
            resValue(type = "string", name = "app_name", value = "Texa Staging")
        }
        create("production") {
            dimension = "app"
            applicationId = "dev.berete.texa"
            resValue(type = "string", name = "app_name", value = "Texa")
        }
    }

    buildFeatures.resValues = true
}