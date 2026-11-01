# C calls these by name.
-keep class com.warriorbiswas.margin.LlamaBridge { *; }
-keep class com.warriorbiswas.margin.LlamaBridge$PieceCallback { *; }

# PDFBox loads its fonts and tables by class name, and refers to optional image codecs it doesn't ship.
-keep class com.tom_roush.** { *; }
-dontwarn com.gemalto.jp2.**
-dontwarn org.bouncycastle.**
