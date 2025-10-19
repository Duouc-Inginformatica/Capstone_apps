package com.example.wayfindcl

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Registrar plugin de detección NPU
        // Mantiene la UI del badge "IA" para futuras funcionalidades de IA
        flutterEngine.plugins.add(NpuDetectorPlugin())
    }
}
