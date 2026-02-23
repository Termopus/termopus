# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.plugin.** { *; }

# Termopus — only keep JNI entry points and bridge channel handler
-keep class com.termopus.app.bridge.SecurityChannel {
    public void onMethodCall(io.flutter.plugin.common.MethodCall, io.flutter.plugin.common.MethodChannel$Result);
}

# Native methods (JNI) — keep any class with native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# OkHttp (WebSocket)
-dontwarn okhttp3.internal.platform.**
-dontwarn org.bouncycastle.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
-keep class okhttp3.internal.publicsuffix.PublicSuffixDatabase { *; }

# Firebase
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**

# Play Core (Integrity, deferred components, tasks)
-keep class com.google.android.play.core.** { *; }
-dontwarn com.google.android.play.core.**

# Serialization
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# Parcelable
-keep class * implements android.os.Parcelable {
    public static final android.os.Parcelable$Creator *;
}

# Development debugging — remove for final release
-printusage unused.txt
