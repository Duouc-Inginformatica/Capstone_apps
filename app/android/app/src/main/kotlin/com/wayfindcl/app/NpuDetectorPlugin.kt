package com.example.wayfindcl

import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Plugin nativo para detectar capacidades de NPU/NNAPI en Android
 * Verifica si TensorFlow Lite puede usar delegados de aceleración por hardware
 */
class NpuDetectorPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "com.wayfindcl/npu_detector")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "detectNpu" -> {
                try {
                    val capabilities = detectNpuCapabilities()
                    result.success(capabilities)
                } catch (e: Exception) {
                    result.error("NPU_DETECTION_ERROR", e.message, null)
                }
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    /**
     * Detecta capacidades de NPU/GPU para TensorFlow Lite
     */
    private fun detectNpuCapabilities(): Map<String, Any> {
        val capabilities = mutableMapOf<String, Any>()

        // Verificar versión de Android (NNAPI desde API 27)
        val hasNnapi = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1
        capabilities["has_nnapi"] = hasNnapi

        // Detectar soporte de GPU delegate
        val hasGpu = detectGpuSupport()
        capabilities["has_gpu"] = hasGpu

        // Detectar NPU dedicado (Qualcomm Hexagon, Samsung Exynos, MediaTek APU)
        val npuInfo = detectNpuHardware()
        capabilities["has_npu"] = npuInfo.first
        capabilities["accelerator_name"] = npuInfo.second

        // Información del chipset
        capabilities["hardware"] = Build.HARDWARE ?: "unknown"
        capabilities["manufacturer"] = Build.MANUFACTURER ?: "unknown"
        capabilities["model"] = Build.MODEL ?: "unknown"
        capabilities["sdk_int"] = Build.VERSION.SDK_INT

        return capabilities
    }

    /**
     * Detecta soporte de GPU Delegate para TFLite
     */
    private fun detectGpuSupport(): Boolean {
        return try {
            // GPU delegate disponible desde OpenGL ES 3.1+
            // La mayoría de dispositivos Android 5.0+ lo soportan
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Detecta NPU dedicado basado en hardware
     */
    private fun detectNpuHardware(): Pair<Boolean, String> {
        val hardware = Build.HARDWARE?.lowercase() ?: ""
        val board = Build.BOARD?.lowercase() ?: ""
        val soc = Build.SOC_MANUFACTURER?.lowercase() ?: ""

        return when {
            // Qualcomm Hexagon DSP/NPU
            hardware.contains("qcom") || 
            soc.contains("qualcomm") ||
            hardware.contains("snapdragon") -> {
                val hexagonVersion = detectHexagonVersion()
                Pair(true, "Qualcomm Hexagon $hexagonVersion")
            }

            // Samsung Exynos NPU
            hardware.contains("exynos") ||
            soc.contains("samsung") -> {
                Pair(true, "Samsung Exynos NPU")
            }

            // MediaTek APU (AI Processing Unit)
            hardware.contains("mt") ||
            soc.contains("mediatek") -> {
                Pair(true, "MediaTek APU")
            }

            // Google Tensor (Pixel 6+)
            hardware.contains("tensor") ||
            board.contains("tensor") -> {
                Pair(true, "Google Tensor TPU")
            }

            // Huawei Kirin NPU
            hardware.contains("kirin") ||
            hardware.contains("hi36") -> {
                Pair(true, "Huawei Kirin NPU")
            }

            else -> Pair(false, "CPU only")
        }
    }

    /**
     * Detecta versión de Hexagon DSP (Qualcomm)
     */
    private fun detectHexagonVersion(): String {
        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> "v73+" // Snapdragon 8 Gen 2+
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> "v69-v73" // Snapdragon 888-8 Gen 1
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> "v66-v68" // Snapdragon 865-888
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> "v65" // Snapdragon 855
            else -> "v60-v64" // Snapdragon 835-845
        }
    }
}
