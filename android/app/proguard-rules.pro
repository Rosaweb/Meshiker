# Isar preservation
-keep class io.isar.** { *; }
-keep @io.isar.IsarCollection class * { *; }
-keep @io.isar.IsarEmbedded class * { *; }

# RevenueCat
-keep class com.revenuecat.purchases.** { *; }

# Flutter
-keep class io.flutter.** { *; }

# Fix for Play Store Split Install (R8 errors)
-dontwarn com.google.android.play.core.**
