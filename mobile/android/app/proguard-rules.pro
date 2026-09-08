# Flutter release build keep rules (R8 / ProGuard).
#
# Reference this file from app/build.gradle AFTER `flutter create .` scaffolds
# the Android project:
#   buildTypes {
#     release {
#       signingConfig signingConfigs.debug
#       minifyEnabled true
#       shrinkResources true
#       proguardFiles getDefaultProguardFile('proguard-android.txt'),
#                     'proguard-rules.pro'
#     }
#   }
# Then build with obfuscation (see build/deploy runbook):
#   flutter build apk --release --obfuscate --split-debug-info=build/symbols

# --- Flutter engine / embedder (never shrink these) ---------------------------
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.embedding.** { *; }

# --- Retrofit / JSON model reflection -----------------------------------------
# Our mobile layer parses JSON manually (fromJson/whereType), but Hive-backed
# cache models and any plugin reflection need their fields preserved.
-keepclassmembers class * {
    @com.fasterxml.jackson.annotation.JsonProperty *;
}
-keepclassmembers class com.mogokmaung.mobile.** {
    <fields>;
}

# --- Third-party keep (video_player, web_socket_channel, connectivity_plus) ---
-dontwarn io.flutter.embedding.**
-keep class com.google.android.exoplayer2.** { *; }
-dontwarn com.google.android.exoplayer2.**

# --- Obfuscation: map file for decode later -----------------------------------
# Output mapping is printed to build/app/outputs/mapping/release/mapping.txt
-printmapping build/app/outputs/mapping/release/mapping.txt