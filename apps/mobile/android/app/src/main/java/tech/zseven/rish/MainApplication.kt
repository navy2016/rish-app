package tech.zseven.rish

import android.app.Application
import com.facebook.react.PackageList
import com.facebook.react.ReactApplication
import com.facebook.react.ReactHost
import com.facebook.react.ReactNativeApplicationEntryPoint.loadReactNative
import com.facebook.react.defaults.DefaultReactHost.getDefaultReactHost

class MainApplication : Application(), ReactApplication {

  override val reactHost: ReactHost by lazy {
    getDefaultReactHost(
      context = applicationContext,
      useDevSupport = BuildConfig.DEBUG && !BuildConfig.RISH_STANDALONE,
      packageList =
        PackageList(this).packages.apply {
          // Task alerts have a native implementation. Runtime/workspace
          // modules still reject unavailable capabilities explicitly.
          add(tech.zseven.rish.RishNativePackage())
        },
    )
  }

  override fun onCreate() {
    super.onCreate()
    tech.zseven.rish.tasks.TaskExperience.initialize(this)
    loadReactNative(this)
  }
}
