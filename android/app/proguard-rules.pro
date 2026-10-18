# UtaNote release R8/ProGuard rules.
#
# Hotfix: release builds crashed on startup with
#   Unable to get provider androidx.startup.InitializationProvider
#   Caused by: Failed to create an instance of androidx.work.impl.WorkDatabase
# WorkManager (pulled in by google_mobile_ads) creates its Room database and
# InputMergers via reflection. R8 stripped their no-arg constructors, so
# keep them.

-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class * extends androidx.work.InputMerger { <init>(); }
