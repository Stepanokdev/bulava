# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# If your project uses WebView with JS, uncomment the following
# and specify the fully qualified class name to the JavaScript interface
# class:
#-keepclassmembers class fqcn.of.javascript.interface.for.webview {
#   public *;
#}

# Uncomment this to preserve the line number information for
# debugging stack traces.
#-keepattributes SourceFile,LineNumberTable

# If you keep the line number information, uncomment this to
# hide the original source file name.
#-renamesourcefileattribute SourceFile
# ML Kit (and anything else built on firebase-components) looks its parts up by the class names in
# the manifest and makes each one through its no-argument constructor. The library's own rule keeps
# those classes but names no members, and R8's full mode — the default — then removes the
# constructor: every registrar fails to load ("Invalid component registrar"), BarcodeScanning
# .getClient() gets null, and the scanner took the whole app down the moment it opened. Only in
# minified builds, so a debug build never showed it.
-keep class * implements com.google.firebase.components.ComponentRegistrar { <init>(); }

# The same story for Room, which WorkManager keeps its jobs in and Glance — the week's widgets —
# runs every widget update through. Room finds a database by its generated `<Name>_Impl` class and
# makes it through its no-argument constructor; the libraries keep the class, full mode removes the
# constructor, and androidx.startup took the app down before its first screen ("Failed to create an
# instance of androidx.work.impl.WorkDatabase") — on a fresh install and on an update alike, and,
# again, only in a minified build. WorkManager makes its workers through a constructor too.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class * extends androidx.work.ListenableWorker { public <init>(android.content.Context, androidx.work.WorkerParameters); }
-keep class * extends androidx.work.InputMerger { public <init>(); }
