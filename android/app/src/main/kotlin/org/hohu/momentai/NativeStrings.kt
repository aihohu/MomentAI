package org.hohu.momentai

import android.content.Context
import android.content.res.Configuration
import androidx.core.content.edit
import java.util.Locale

/** Resource lookup without recreating the Activity or interrupting recording. */
object NativeStrings {
    private var application: Context? = null
    fun initialize(context: Context) {
        application = context.applicationContext
    }
    fun select(language: String) {
        require(language in listOf("system", "zh", "en"))
        application?.getSharedPreferences("localization", Context.MODE_PRIVATE)
            ?.edit { putString("language", language) }
    }
    fun text(id: Int, vararg args: Any): String {
        val context = checkNotNull(application) { "Localization is not initialized" }
        val selected = context.getSharedPreferences("localization", Context.MODE_PRIVATE)
            .getString("language", "system")
        val requested = if (selected ==
            "system"
        ) {
            Locale.getDefault()
        } else {
            Locale.forLanguageTag(selected ?: "en")
        }
        val locale = if (requested.language == "zh") Locale.SIMPLIFIED_CHINESE else requested
        val configuration = Configuration(context.resources.configuration)
        configuration.setLocale(locale)
        return context.createConfigurationContext(configuration).resources.getString(id, *args)
    }
}
