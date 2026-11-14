package io.dockhive.push

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import java.util.Locale
import java.util.TimeZone

/** Where the device id and the last push token are kept between launches. */
internal interface DeviceStore {
    var deviceId: String?
    var token: String?
}

internal class PrefsDeviceStore(context: Context, key: String) : DeviceStore {
    private val prefs = context.applicationContext.getSharedPreferences("io.dockhive.push", Context.MODE_PRIVATE)
    private val prefix = "$key."

    override var deviceId: String?
        get() = prefs.getString(prefix + "device_id", null)
        set(v) = prefs.edit().putString(prefix + "device_id", v).apply()

    override var token: String?
        get() = prefs.getString(prefix + "token", null)
        set(v) = prefs.edit().putString(prefix + "token", v).apply()
}

internal class MemoryDeviceStore : DeviceStore {
    @Volatile override var deviceId: String? = null
    @Volatile override var token: String? = null
}

/** The optional app version / locale / time zone sent with a registration. */
internal data class DeviceInfo(val appVersion: String?, val locale: String?, val timezone: String?) {
    fun fields(): Map<String, String> = buildMap {
        appVersion?.let { put("app_version", it) }
        locale?.let { put("locale", it) }
        timezone?.let { put("timezone", it) }
    }

    companion object {
        private val versionRe = Regex("^[\\x20-\\x7e]{1,32}$")
        private val localeRe = Regex("^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8}){0,4}$")
        private val timezoneRe = Regex("^[A-Za-z0-9_+\\-/]{1,64}$")

        fun sanitizeVersion(v: String?): String? = v?.takeIf { versionRe.matches(it) }

        fun sanitizeLocale(tag: String?): String? =
            tag?.replace('_', '-')?.takeIf { it.length <= 35 && localeRe.matches(it) }

        fun sanitizeTimezone(id: String?): String? = id?.takeIf { timezoneRe.matches(it) }

        fun current(context: Context): DeviceInfo {
            val version = try {
                val pm = context.packageManager
                if (Build.VERSION.SDK_INT >= 33) {
                    pm.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0)).versionName
                } else {
                    @Suppress("DEPRECATION")
                    pm.getPackageInfo(context.packageName, 0).versionName
                }
            } catch (_: Exception) {
                null
            }
            return DeviceInfo(
                sanitizeVersion(version),
                sanitizeLocale(Locale.getDefault().toLanguageTag()),
                sanitizeTimezone(TimeZone.getDefault().id),
            )
        }
    }
}
