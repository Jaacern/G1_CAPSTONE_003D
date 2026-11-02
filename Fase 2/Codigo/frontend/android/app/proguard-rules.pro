# Reglas ProGuard/R8 para el build release de AgeCare.
#
# Motivo: en release, R8 ofusca/elimina clases que varias librerias instancian
# por REFLEXION en tiempo de ejecucion. Si se eliminan, la app crashea al
# arrancar. El caso observado fue:
#   java.lang.NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init>
# (WorkManager -> usado por flutter_local_notifications para notificaciones
# programadas). Estas reglas preservan lo necesario manteniendo la minificacion.

# ── Flutter (embedding) ──
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# ── AndroidX WorkManager + App Startup ──
# WorkManager genera WorkDatabase_Impl y la instancia por reflexion.
-keep class androidx.work.** { *; }
-keep class androidx.work.impl.** { *; }
-keep class * extends androidx.work.Worker
-keep class * extends androidx.work.ListenableWorker { *; }
-keep class androidx.startup.** { *; }
-keep class * implements androidx.startup.Initializer { *; }

# ── Room (la BD interna que usa WorkManager y otros) ──
# Room genera clases *_Impl instanciadas por reflexion.
-keep class * extends androidx.room.RoomDatabase { *; }
-keep class **_Impl { *; }
-keepclassmembers class * extends androidx.room.RoomDatabase {
    <init>();
}
-dontwarn androidx.room.paging.**

# ── flutter_local_notifications ──
-keep class com.dexterous.** { *; }
-keep class com.dexterous.flutterlocalnotifications.** { *; }

# ── Gson / serializacion (flutter_local_notifications usa Gson internamente) ──
-keep class com.google.gson.** { *; }
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses

# ── Firebase Messaging (push) ──
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**

# ── Mantener constructores sin argumentos usados por reflexion en general ──
-keepclassmembers class * {
    public <init>();
}
