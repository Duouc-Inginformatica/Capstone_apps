import 'dart:io';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';
import '../debug_logger.dart';

/// Servicio para detectar capacidades de NPU/NNAPI en dispositivos Android
/// Determina si el dispositivo puede ejecutar modelos TensorFlow Lite con aceleración por hardware
class NpuDetectorService {
  static final NpuDetectorService instance = NpuDetectorService._internal();
  factory NpuDetectorService() => instance;
  NpuDetectorService._internal();

  static const MethodChannel _channel = MethodChannel(
    'com.wayfindcl/npu_detector',
  );

  NpuCapabilities? _cachedCapabilities;

  /// Detecta las capacidades de aceleración por hardware del dispositivo
  Future<NpuCapabilities> detectCapabilities() async {
    if (_cachedCapabilities != null) {
      return _cachedCapabilities!;
    }

    if (!Platform.isAndroid) {
      _cachedCapabilities = NpuCapabilities(
        hasNnapi: false,
        nnApiVersion: 0,
        hasGpuDelegate: false,
        hasNpuDelegate: false,
        acceleratorType: AcceleratorType.none,
        deviceInfo: 'iOS - No NNAPI support',
      );
      return _cachedCapabilities!;
    }

    try {
      // Obtener información del dispositivo
      final deviceInfo = await DeviceInfoPlugin().androidInfo;
      final sdkInt = deviceInfo.version.sdkInt;

      // NNAPI disponible desde Android 8.1 (API 27)
      final hasNnapi = sdkInt >= 27;

      // Versión de NNAPI:
      // - API 27: NNAPI 1.0
      // - API 28: NNAPI 1.1
      // - API 29: NNAPI 1.2
      // - API 30+: NNAPI 1.3+
      int nnApiVersion = 0;
      if (sdkInt >= 30) {
        nnApiVersion = 13;
      } else if (sdkInt >= 29) {
        nnApiVersion = 12;
      } else if (sdkInt >= 28) {
        nnApiVersion = 11;
      } else if (sdkInt >= 27) {
        nnApiVersion = 10;
      }

      // Intentar detectar NPU/GPU via platform channel
      Map<String, dynamic> nativeCapabilities = {};
      try {
        nativeCapabilities =
            await _channel.invokeMapMethod<String, dynamic>('detectNpu') ??
                <String, dynamic>{};
      } catch (e) {
        DebugLogger.info('⚠️ [NPU] Platform channel no disponible: $e');
      }

      final hasGpuDelegate = nativeCapabilities['has_gpu'] as bool? ?? false;
      final hasNpuDelegate = nativeCapabilities['has_npu'] as bool? ?? false;
      final acceleratorName =
          nativeCapabilities['accelerator_name'] as String? ?? '';
  final rawHardware = deviceInfo.hardware;
      final hardware = rawHardware.toLowerCase();

      // Determinar tipo de acelerador basado en chipset
      AcceleratorType acceleratorType = AcceleratorType.none;

      if (hasNpuDelegate) {
        // NPU dedicado (Qualcomm Hexagon, Samsung Exynos NPU, MediaTek APU, etc.)
        if (hardware.contains('qcom') == true ||
            acceleratorName.toLowerCase().contains('hexagon')) {
          acceleratorType = AcceleratorType.qualcommHexagon;
        } else if (hardware.contains('exynos') == true) {
          acceleratorType = AcceleratorType.samsungNpu;
        } else if (hardware.contains('mt') == true) {
          acceleratorType = AcceleratorType.mediatekApu;
        } else {
          acceleratorType = AcceleratorType.genericNpu;
        }
      } else if (hasGpuDelegate && hasNnapi) {
        acceleratorType = AcceleratorType.gpu;
      } else if (hasNnapi) {
        acceleratorType = AcceleratorType.nnapi;
      }

      _cachedCapabilities = NpuCapabilities(
        hasNnapi: hasNnapi,
        nnApiVersion: nnApiVersion,
        hasGpuDelegate: hasGpuDelegate,
        hasNpuDelegate: hasNpuDelegate,
        acceleratorType: acceleratorType,
        deviceInfo:
            '${deviceInfo.manufacturer} ${deviceInfo.model} (SDK $sdkInt)',
  chipset: rawHardware.isNotEmpty ? rawHardware : 'unknown',
      );

      DebugLogger.info('🧠 [NPU] Capacidades detectadas:');
      DebugLogger.info('   - NNAPI: ${hasNnapi ? "v${nnApiVersion / 10}" : "No"}');
      DebugLogger.info('   - GPU Delegate: $hasGpuDelegate');
      DebugLogger.info('   - NPU Delegate: $hasNpuDelegate');
      DebugLogger.info('   - Acelerador: ${acceleratorType.name}');
      DebugLogger.info('   - Dispositivo: ${_cachedCapabilities!.deviceInfo}');
      DebugLogger.info('   - Chipset: ${_cachedCapabilities!.chipset}');

      return _cachedCapabilities!;
    } catch (e) {
      DebugLogger.info('❌ [NPU] Error detectando capacidades: $e');

      _cachedCapabilities = NpuCapabilities(
        hasNnapi: false,
        nnApiVersion: 0,
        hasGpuDelegate: false,
        hasNpuDelegate: false,
        acceleratorType: AcceleratorType.none,
        deviceInfo: 'Error: $e',
      );

      return _cachedCapabilities!;
    }
  }

  /// Verifica si el dispositivo puede ejecutar TTS neural con aceleración
  Future<bool> canRunNeuralTts() async {
    final capabilities = await detectCapabilities();

    // Requiere al menos NNAPI 1.1 (Android 9) para TFLite con buen rendimiento
    if (!capabilities.hasNnapi || capabilities.nnApiVersion < 11) {
      return false;
    }

    // Preferiblemente con NPU o GPU
    return capabilities.hasNpuDelegate || capabilities.hasGpuDelegate;
  }

  /// Obtiene el delegado recomendado para TFLite
  Future<TfliteDelegate> getRecommendedDelegate() async {
    final capabilities = await detectCapabilities();

    if (capabilities.hasNpuDelegate) {
      return TfliteDelegate.nnapi;
    } else if (capabilities.hasGpuDelegate) {
      return TfliteDelegate.gpu;
    } else if (capabilities.hasNnapi) {
      return TfliteDelegate.nnapi;
    } else {
      return TfliteDelegate.none;
    }
  }

  /// Obtiene un mensaje descriptivo de las capacidades
  String getCapabilitiesDescription(NpuCapabilities capabilities) {
    if (capabilities.hasNpuDelegate) {
      return 'IA Neural (${capabilities.acceleratorType.displayName})';
    } else if (capabilities.hasGpuDelegate) {
      return 'IA Acelerada por GPU';
    } else if (capabilities.hasNnapi) {
      return 'IA Acelerada (NNAPI ${capabilities.nnApiVersion / 10})';
    } else {
      return 'Sin aceleración IA';
    }
  }
}

/// Capacidades de aceleración por hardware detectadas
class NpuCapabilities {
  final bool hasNnapi;
  final int nnApiVersion; // 10 = 1.0, 11 = 1.1, 12 = 1.2, etc.
  final bool hasGpuDelegate;
  final bool hasNpuDelegate;
  final AcceleratorType acceleratorType;
  final String deviceInfo;
  final String? chipset;

  const NpuCapabilities({
    required this.hasNnapi,
    required this.nnApiVersion,
    required this.hasGpuDelegate,
    required this.hasNpuDelegate,
    required this.acceleratorType,
    required this.deviceInfo,
    this.chipset,
  });

  bool get hasAcceleration => hasNnapi || hasGpuDelegate || hasNpuDelegate;

  bool get canRunNeuralTts => hasNnapi && nnApiVersion >= 11;
}

/// Tipos de aceleradores por hardware
enum AcceleratorType {
  none,
  nnapi,
  gpu,
  genericNpu,
  qualcommHexagon,
  samsungNpu,
  mediatekApu;

  String get displayName {
    switch (this) {
      case AcceleratorType.none:
        return 'CPU';
      case AcceleratorType.nnapi:
        return 'NNAPI';
      case AcceleratorType.gpu:
        return 'GPU';
      case AcceleratorType.genericNpu:
        return 'NPU';
      case AcceleratorType.qualcommHexagon:
        return 'Hexagon NPU';
      case AcceleratorType.samsungNpu:
        return 'Exynos NPU';
      case AcceleratorType.mediatekApu:
        return 'MediaTek APU';
    }
  }
}

/// Delegados de TensorFlow Lite
enum TfliteDelegate {
  none,
  nnapi,
  gpu,
  xnnpack;

  String get name {
    switch (this) {
      case TfliteDelegate.none:
        return 'CPU';
      case TfliteDelegate.nnapi:
        return 'NNAPI';
      case TfliteDelegate.gpu:
        return 'GPU';
      case TfliteDelegate.xnnpack:
        return 'XNNPACK';
    }
  }
}
