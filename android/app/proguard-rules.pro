# Release builds go through R8 (Flutter turns it on). youtubedl-android ships
# no consumer rules, and without these R8 renames and strips its classes and
# Jackson, which it runs by reflection: YoutubeDL's static init (new
# ObjectMapper()) then dies with ExceptionInInitializerError on some phones.
-keep class com.yausername.** { *; }
-keep class com.fasterxml.jackson.** { *; }
-keep class org.apache.commons.** { *; }
-keepattributes Signature,*Annotation*,InnerClasses,EnclosingMethod
-dontwarn com.fasterxml.jackson.**
-dontwarn org.apache.commons.**
-dontwarn java.beans.**
-dontwarn org.w3c.dom.bootstrap.**
