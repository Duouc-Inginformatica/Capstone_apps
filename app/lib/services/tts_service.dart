import 'package:flutter_tts/flutter_tts.dart';
import 'dart:developer' as developer;

/// Servicio TTS clásico usando flutter_tts
class TtsService {
  TtsService._internal();
  static final TtsService instance = TtsService._internal();

  // Constructor singleton accesible sin parámetros
  factory TtsService() => instance;

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _isSpeaking = false;
  final List<String> _messageQueue = [];

  // Configuración de voz
  double _rate = 0.45;
  double _pitch = 0.95;

  // Historial de mensajes
  String? _lastSpokenText;
  final List<String> _speechHistory = [];
  static const int maxHistorySize = 10;

  /// Inicializa el motor TTS clásico
  Future<void> initialize() async {
    if (_initialized) return;

    developer.log('🔊 [TTS] Inicializando motor TTS clásico');

    // Configurar TTS nativo
    await _initializeNativeTts();

    _initialized = true;
  }

  Future<void> _initializeNativeTts() async {
    // Configuración mejorada para voz más natural
    await _tts.setLanguage('es-ES');

    // Velocidad más lenta para mejor comprensión (0.4 = más lento, 1.0 = normal)
  await _tts.setSpeechRate(_rate);

    // Volumen máximo
    await _tts.setVolume(1.0);

    // Tono ligeramente más bajo para sonar más natural (1.0 = normal)
  await _tts.setPitch(_pitch);

    // Configurar callbacks para saber cuándo termina de hablar
    _tts.setCompletionHandler(() {
      _isSpeaking = false;
      _processQueue(); // Procesar siguiente mensaje en cola
    });

    _tts.setErrorHandler((msg) {
      _isSpeaking = false;
      _processQueue();
    });

    // Intentar usar voces del sistema más naturales
    try {
      final voices = await _tts.getVoices;
      if (voices != null && voices.isNotEmpty) {
        // Buscar voz española femenina o masculina de alta calidad
        final spanishVoices = voices.where((voice) {
          final name = voice['name']?.toString().toLowerCase() ?? '';
          final locale = voice['locale']?.toString().toLowerCase() ?? '';
          return locale.contains('es') &&
              (name.contains('female') ||
                  name.contains('male') ||
                  name.contains('spanish') ||
                  name.contains('español'));
        }).toList();

        if (spanishVoices.isNotEmpty) {
          final bestVoice = spanishVoices.first;
          await _tts.setVoice({
            'name': bestVoice['name'],
            'locale': bestVoice['locale'],
          });
        }
      }
    } catch (e) {
      // Si falla, usar configuración por defecto
      developer.log('No se pudieron cargar voces del sistema: $e');
    }

    _initialized = true;
  }

  /// Procesa la cola de mensajes pendientes
  void _processQueue() {
    if (_messageQueue.isEmpty || _isSpeaking) return;

    final nextMessage = _messageQueue.removeAt(0);
    _speakNow(nextMessage);
  }

  /// Habla un texto con pausas naturales
  Future<void> speak(String text, {bool urgent = false}) async {
    if (text.trim().isEmpty) return;

    // Asegurar inicialización
    if (!_initialized) {
      await initialize();
    }

    try {
      // Guardar en historial
      _lastSpokenText = text;
      _speechHistory.insert(0, text);

      // Mantener máximo 10 mensajes en historial
      if (_speechHistory.length > maxHistorySize) {
        _speechHistory.removeRange(maxHistorySize, _speechHistory.length);
      }

      // Si es urgente, interrumpir y limpiar cola
      if (urgent) {
        await stop();
        _messageQueue.clear();
        _isSpeaking = false;
        await _speakNow(text);
      } else {
        // Si no está hablando, hablar inmediatamente
        if (!_isSpeaking) {
          await _speakNow(text);
        } else {
          // Si está hablando, agregar a la cola
          _messageQueue.add(text);
        }
      }
    } catch (e) {
      developer.log('Error en TTS: $e');
      _isSpeaking = false;
    }
  }

  /// Habla inmediatamente (uso interno)
  Future<void> _speakNow(String text) async {
    _isSpeaking = true;

    // Usar TTS nativo clásico
    developer.log(
      '🔊 [TTS] Hablando: "${text.substring(0, text.length > 50 ? 50 : text.length)}..."',
    );
    final textWithPauses = text.replaceAll('.', '... ').replaceAll(',', ', ');
    await _tts.speak(textWithPauses);
  }

  /// Anuncia una instrucción de navegación importante
  Future<void> announceNavigation(
    String instruction, {
    bool urgent = false,
  }) async {
    // Agregar sonido de notificación antes de la instrucción
    await speak('Atención. $instruction', urgent: urgent);
  }

  /// Repite el último mensaje hablado
  Future<void> repeatLast() async {
    if (_lastSpokenText != null && _lastSpokenText!.isNotEmpty) {
      await speak('Repitiendo: $_lastSpokenText');
    } else {
      await speak('No hay ningún mensaje para repetir');
    }
  }

  /// Repite el mensaje N posiciones atrás en el historial
  Future<void> repeatFromHistory(int index) async {
    if (index < 0 || index >= _speechHistory.length) {
      await speak('No hay mensaje en esa posición del historial');
      return;
    }

    final message = _speechHistory[index];
    await speak('Mensaje anterior: $message');
  }

  /// Obtiene el historial de mensajes
  List<String> getHistory() => List.unmodifiable(_speechHistory);

  /// Limpia el historial
  void clearHistory() {
    _speechHistory.clear();
    _lastSpokenText = null;
  }

  /// Limpia la cola de mensajes pendientes
  void clearQueue() {
    _messageQueue.clear();
  }

  /// Para la reproducción y limpia la cola
  Future<void> stop() async {
    if (!_initialized) return;
    try {
      await _tts.stop();
      _messageQueue.clear();
      _isSpeaking = false;
    } catch (_) {}
  }

  /// Establece la velocidad de habla
  void setRate(double rate) {
    _rate = rate;
    _tts.setSpeechRate(rate);
  }

  /// Establece el tono de voz
  void setPitch(double pitch) {
    _pitch = pitch;
    _tts.setPitch(pitch);
  }

  /// Verifica si TTS está hablando actualmente
  bool get isSpeaking => _isSpeaking;

  /// Espera a que TTS termine de hablar
  Future<void> waitUntilDone() async {
    while (_isSpeaking || _messageQueue.isNotEmpty) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }
}
