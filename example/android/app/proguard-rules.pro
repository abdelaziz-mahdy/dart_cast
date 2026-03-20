## Flutter framework and engine
## Prevents R8 from stripping plugin registration classes
## that Flutter discovers via reflection at runtime.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**
-keep class io.flutter.embedding.engine.plugins.** { *; }

## FFmpegKit — if added as a dependency
## Without these rules, R8 strips FFmpegKit's plugin registration
## which corrupts the entire Flutter plugin channel initialization,
## breaking shared_preferences, path_provider, and other plugins.
-keep class com.antonkarpenko.ffmpegkit.** { *; }
-dontwarn com.antonkarpenko.ffmpegkit.**
-keepclasseswithmembernames class * {
    native <methods>;
}
