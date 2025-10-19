import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'npu_detector_service.dart';

/// Servicio de TTS Neural Multi-Modelo usando Piper (ONNX Runtime)
///
/// Características:
/// - 6 voces reales (3 masculinas + 3 femeninas)
/// - Caché LRU para últimos 2 modelos
/// - NPU/NNAPI acceleration
///
/// Voces disponibles:
/// - M1: Carlos (Carl FM) - Voz profunda y clara
/// - M2: David (Dave FX) - Voz neutra profesional
/// - M3: Miguel (Sharvard M) - Voz equilibrada
/// - F1: Sara (Sharvard F) - Voz clara
/// - F2: María (MLS 9972) - Voz suave
/// - F3: Ana (MLS 10246) - Voz natural
class NeuralTtsService {
  static final NeuralTtsService instance = NeuralTtsService._internal();
  factory NeuralTtsService() => instance;
  NeuralTtsService._internal();

  static const MethodChannel _channel = MethodChannel(
    'com.wayfindcl/neural_tts', // ⚠️ Cambió de piper_tts a neural_tts
  );

  bool _isInitialized = false;
  bool _isAvailable = false;
  TfliteDelegate _delegate = TfliteDelegate.none;
  String _currentVoiceId = 'F1'; // Voz por defecto
  List<Map<String, dynamic>> _availableVoices = [];

  /// Inicializa el motor TTS neural y carga voces disponibles
  /// Retorna true si se inicializó correctamente
  Future<bool> initialize() async {
    if (_isInitialized) {
      return _isAvailable;
    }

    try {
      print('🧠 [NEURAL_TTS] Inicializando motor TTS multi-modelo...');

      // 1. Verificar capacidades del dispositivo
      final npuCapabilities = await NpuDetectorService.instance
          .detectCapabilities();

      if (!npuCapabilities.canRunNeuralTts) {
        print('⚠️ [NEURAL_TTS] Dispositivo no soporta TTS neural');
        print(
          '   Razón: ${npuCapabilities.hasNnapi ? "NNAPI versión insuficiente" : "Sin NNAPI"}',
        );
        _isInitialized = true;
        _isAvailable = false;
        return false;
      }

      // 2. Obtener delegado recomendado
      _delegate = await NpuDetectorService.instance.getRecommendedDelegate();
      print('🧠 [NEURAL_TTS] Delegado seleccionado: ${_delegate.name}');

      // 3. Inicializar plugin via platform channel
      try {
        final result = await _channel.invokeMethod<bool>('initialize');

        if (result == true) {
          _isAvailable = true;

          // 4. Cargar lista de voces disponibles
          await loadAvailableVoices();

          // 5. Cargar voz guardada en preferencias (o usar F1 por defecto)
          try {
            final prefs = await SharedPreferences.getInstance();
            final savedVoice = prefs.getString('assistant_voice');

            if (savedVoice != null && savedVoice.isNotEmpty) {
              // Usar voz guardada
              await switchVoice(savedVoice);
              _currentVoiceId = savedVoice;
              print('✅ [NEURAL_TTS] Voz guardada cargada: $savedVoice');
            } else {
              // Primera vez: usar F1 (Asistente Clara) por defecto
              const defaultVoice = 'F1';
              await switchVoice(defaultVoice);
              _currentVoiceId = defaultVoice;
              await prefs.setString('assistant_voice', defaultVoice);
              print(
                '✅ [NEURAL_TTS] Voz por defecto seleccionada: $defaultVoice (Asistente Clara)',
              );
            }
          } catch (e) {
            print('⚠️ [NEURAL_TTS] Error configurando voz: $e');
          }

          print('✅ [NEURAL_TTS] Motor TTS neural inicializado');
          print('   - Delegado: ${_delegate.name}');
          print('   - Voces disponibles: ${_availableVoices.length}');
          print('   - Voz activa: $_currentVoiceId');
        } else {
          print('❌ [NEURAL_TTS] Inicialización falló');
          _isAvailable = false;
        }
      } on PlatformException catch (e) {
        print('❌ [NEURAL_TTS] Platform error: ${e.message}');
        _isAvailable = false;
      }

      _isInitialized = true;
      return _isAvailable;
    } catch (e) {
      print('❌ [NEURAL_TTS] Error fatal en inicialización: $e');
      _isInitialized = true;
      _isAvailable = false;
      return false;
    }
  }

  /// Carga la lista de voces disponibles desde el plugin
  Future<void> loadAvailableVoices() async {
    try {
      final result = await _channel.invokeMethod('getAvailableVoices');
      _availableVoices = List<Map<String, dynamic>>.from(
        (result as List).map((voice) => Map<String, dynamic>.from(voice)),
      );
      print(
        '📊 [NEURAL_TTS] Voces cargadas: ${_availableVoices.map((v) => v['id']).join(", ")}',
      );
    } catch (e) {
      print('⚠️ [NEURAL_TTS] Error cargando voces: $e');
      _availableVoices = [];
    }
  }

  /// Cambia la voz activa
  /// voiceId: 'M1', 'M2', 'M3', 'F1', 'F2', 'F3'
  Future<bool> switchVoice(String voiceId) async {
    if (!_isAvailable) {
      print('⚠️ [NEURAL_TTS] Motor no disponible');
      return false;
    }

    try {
      print('🔄 [NEURAL_TTS] Cambiando a voz: $voiceId');

      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'switchVoice',
        {'voiceId': voiceId},
      );

      if (result?['success'] == true) {
        _currentVoiceId = voiceId;
        print('✅ [NEURAL_TTS] Voz cambiada a: $voiceId');
        return true;
      } else {
        print('❌ [NEURAL_TTS] Error cambiando voz');
        return false;
      }
    } on PlatformException catch (e) {
      print('❌ [NEURAL_TTS] Platform error: ${e.message}');
      return false;
    } catch (e) {
      print('❌ [NEURAL_TTS] Error: $e');
      return false;
    }
  }

  /// Sintetiza texto a voz usando el motor neural
  ///
  /// Parámetros:
  /// - text: Texto a sintetizar
  /// - rate: Velocidad (0.5 - 2.0, default 1.0)
  /// - pitch: Tono (0.5 - 2.0, default 1.0)
  /// - voiceId: ID de voz opcional (si no se especifica, usa la voz actual)
  ///            Valores: 'M1', 'M2', 'M3', 'F1', 'F2', 'F3'
  ///
  /// Retorna true si se sintetizó correctamente
  Future<bool> speak(
    String text, {
    double rate = 1.0,
    double pitch = 1.0,
    String? voiceId, // Ahora acepta voiceId específico
  }) async {
    if (!_isAvailable) {
      print('⚠️ [NEURAL_TTS] Motor no disponible para: "$text"');
      return false;
    }

    try {
      final targetVoiceId = voiceId ?? _currentVoiceId;
      print('🔊 [NEURAL_TTS] Sintetizando: "$text" (voz: $targetVoiceId)');

      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'speak',
        {'text': text, 'rate': rate, 'pitch': pitch, 'voiceId': targetVoiceId},
      );

      if (result?['success'] == true) {
        final latency = result?['latency_ms'] ?? 0;
        print('✅ [NEURAL_TTS] Síntesis completada en ${latency}ms');
        return true;
      } else {
        print('❌ [NEURAL_TTS] Error en síntesis: ${result?['error']}');
        return false;
      }
    } on PlatformException catch (e) {
      print('❌ [NEURAL_TTS] Platform error: ${e.message}');
      return false;
    } catch (e) {
      print('❌ [NEURAL_TTS] Error: $e');
      return false;
    }
  }

  /// Detiene la síntesis actual
  Future<void> stop() async {
    if (!_isAvailable) return;

    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      print('⚠️ [NEURAL_TTS] Error deteniendo síntesis: $e');
    }
  }

  /// Verifica si el motor está disponible
  bool get isAvailable => _isAvailable;

  /// Verifica si el motor está inicializado
  bool get isInitialized => _isInitialized;

  /// Obtiene el delegado en uso
  TfliteDelegate get delegate => _delegate;

  /// Obtiene la voz activa actual
  String get currentVoiceId => _currentVoiceId;

  /// Obtiene la lista de voces disponibles
  List<Map<String, dynamic>> get availableVoices => _availableVoices;

  /// Libera recursos
  Future<void> dispose() async {
    if (!_isInitialized) return;

    try {
      await _channel.invokeMethod('dispose');
      _isInitialized = false;
      _isAvailable = false;
      _availableVoices = [];
      print('🗑️ [NEURAL_TTS] Recursos liberados');
    } catch (e) {
      print('⚠️ [NEURAL_TTS] Error liberando recursos: $e');
    }
  }
}
