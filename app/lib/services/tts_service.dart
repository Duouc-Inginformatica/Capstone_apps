import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  TtsService._internal();
  static final TtsService instance = TtsService._internal();

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _isSpeaking = false; // Estado de si está hablando
  final List<String> _messageQueue = []; // Cola de mensajes pendientes

  // Historial de mensajes
  String? _lastSpokenText;
  final List<String> _speechHistory = [];
  static const int maxHistorySize = 10;

  Future<void> _ensureInit() async {
    if (_initialized) return;

    // Configuración mejorada para voz más natural
    await _tts.setLanguage('es-ES');

    // Velocidad más lenta para mejor comprensión (0.4 = más lento, 1.0 = normal)
    await _tts.setSpeechRate(0.45);

    // Volumen máximo
    await _tts.setVolume(1.0);

    // Tono ligeramente más bajo para sonar más natural (1.0 = normal)
    await _tts.setPitch(0.95);

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
      print('No se pudieron cargar voces del sistema: $e');
    }

    _initialized = true;
  }

  /// Procesa la cola de mensajes pendientes
  void _processQueue() {
    if (_messageQueue.isEmpty || _isSpeaking) return;

    final nextMessage = _messageQueue.removeAt(0);
    _speakNow(nextMessage);
  }

  /// Habla inmediatamente (uso interno)
  Future<void> _speakNow(String text) async {
    _isSpeaking = true;

    // Agregar pausas naturales en puntos y comas
    final textWithPauses = text
        .replaceAll('.', '... ') // Pausa larga después de punto
        .replaceAll(',', ', '); // Pausa corta después de coma

    await _tts.speak(textWithPauses);
  }

  /// Habla un texto con pausas naturales
  Future<void> speak(String text, {bool urgent = false}) async {
    if (text.trim().isEmpty) return;
    await _ensureInit();

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
        await _tts.stop();
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
      print('Error en TTS: $e');
      _isSpeaking = false;
    }
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
}
