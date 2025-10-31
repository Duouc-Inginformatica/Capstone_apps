import 'package:flutter_tts/flutter_tts.dart';
import '../debug_logger.dart';

/// Prioridad para anuncios TTS (alias usado por la UI)
enum TtsPriority { low, normal, high, critical }

/// Servicio TTS clásico usando flutter_tts
class TtsService {
  TtsService._internal();
  static final TtsService instance = TtsService._internal();

  // Constructor singleton accesible sin parámetros
  factory TtsService() => instance;

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _isSpeaking = false;
  String _activeContext = 'global';
  String? _currentContext;
  final List<_SpeechMessage> _messageQueue = [];

  // Configuración de voz optimizada para accesibilidad
  double _rate = 0.4; // Más lento para mejor comprensión (era 0.45)
  double _pitch = 1.0; // Tono normal para claridad (era 0.95)

  // Historial de mensajes
  String? _lastSpokenText;
  final List<String> _speechHistory = [];
  static const int maxHistorySize = 10;

  /// Inicializa el motor TTS clásico
  Future<void> initialize() async {
    if (_initialized) return;

    DebugLogger.voice('🔊 [TTS] Inicializando motor TTS clásico');

    // Configurar TTS nativo
    await _initializeNativeTts();

    _initialized = true;
  }

  Future<void> _initializeNativeTts() async {
    // Configuración mejorada para voz más natural y clara
    await _tts.setLanguage('es-ES');

    // Velocidad más lenta para mejor comprensión (0.4 = más lento, 1.0 = normal)
    await _tts.setSpeechRate(_rate);

    // Volumen máximo
    await _tts.setVolume(1.0);

    // Tono normal para mejor claridad (1.0 = normal, era 0.95)
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
      DebugLogger.voice('No se pudieron cargar voces del sistema: $e');
    }

    _initialized = true;
  }

  /// Define el contexto activo (pantalla o flujo) para reproducir mensajes.
  Future<void> setActiveContext(
    String context, {
    bool stopCurrent = true,
  }) async {
    if (context.isEmpty) return;
    if (_activeContext == context) return;

    if (stopCurrent && _currentContext != null && _currentContext != context) {
      await stop();
    }

    _activeContext = context;

    // Limpiar mensajes que pertenecen a otros contextos
    _messageQueue.removeWhere((msg) => msg.context != _activeContext);
  }

  /// Libera el contexto actual regresando a "global".
  Future<void> releaseContext(String context) async {
    if (_activeContext != context) return;
    await stop();
    _activeContext = 'global';
    _currentContext = null;
  }

  /// Procesa la cola de mensajes pendientes
  void _processQueue() {
    if (_messageQueue.isEmpty || _isSpeaking) return;

    // Buscar el siguiente mensaje válido para el contexto activo
    final nextIndex = _messageQueue.indexWhere(
      (msg) => msg.context == _activeContext,
    );

    if (nextIndex == -1) {
      // Si no hay mensajes para este contexto, limpiar la cola restante
      _messageQueue.clear();
      return;
    }

    final nextMessage = _messageQueue.removeAt(nextIndex);
    _speakNow(nextMessage);
  }

  /// Habla un texto con pausas naturales
  Future<void> speak(
    String text, {
    bool urgent = false,
    String? context,
  }) async {
    if (text.trim().isEmpty) return;

    // Asegurar inicialización
    if (!_initialized) {
      await initialize();
    }

    try {
      final targetContext = context ?? _activeContext;

      // Evitar hablar si el contexto no coincide y no es urgente
      if (targetContext != _activeContext && !urgent) {
        DebugLogger.voice(
          '🔇 [TTS] Mensaje descartado por contexto inactivo ($targetContext)',
        );
        return;
      }

      // Guardar en historial
      _lastSpokenText = text;
      _speechHistory.insert(0, text);

      // Mantener máximo 10 mensajes en historial
      if (_speechHistory.length > maxHistorySize) {
        _speechHistory.removeRange(maxHistorySize, _speechHistory.length);
      }

      final message = _SpeechMessage(text: text, context: targetContext);

      // Si es urgente, interrumpir y limpiar cola
      if (urgent) {
        await stop();
        _messageQueue.clear();
        _isSpeaking = false;
        await _speakNow(message);
      } else {
        // Si no está hablando, hablar inmediatamente
        if (!_isSpeaking) {
          await _speakNow(message);
        } else {
          if (_currentContext == targetContext) {
            // Misma pantalla: encolar
            _messageQueue.add(message);
          } else {
            // Otra pantalla: interrumpir y reproducir nuevo contexto
            await stop();
            await _speakNow(message);
          }
        }
      }
    } catch (e) {
      DebugLogger.voice('Error en TTS: $e');
      _isSpeaking = false;
    }
  }

  /// Habla inmediatamente (uso interno)
  Future<void> _speakNow(_SpeechMessage message) async {
    _isSpeaking = true;
    _currentContext = message.context;

    // Usar TTS nativo clásico
    final text = message.text;
    DebugLogger.voice(
      '🔊 [TTS] (${message.context}) "${text.substring(0, text.length > 50 ? 50 : text.length)}..."',
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

  /// Compatibilidad: método `announce` usado en varias pantallas
  Future<void> announce(
    String text, {
    TtsPriority priority = TtsPriority.normal,
    String? context,
  }) async {
    // Mapear prioridad a urgent flag
    final urgent =
        (priority == TtsPriority.high || priority == TtsPriority.critical);
    await speak(text, urgent: urgent, context: context);
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
  Future<void> stop({bool clearQueue = true}) async {
    if (!_initialized) return;
    try {
      await _tts.stop();
      if (clearQueue) {
        _messageQueue.clear();
      } else {
        _messageQueue.removeWhere((msg) => msg.context != _activeContext);
      }
      _isSpeaking = false;
      _currentContext = null;
    } catch (e) {
      // Ignorar errores al detener TTS - puede ocurrir si ya estaba detenido
      DebugLogger.voice('[TtsService] ⚠️ Error al detener TTS: $e');
    }
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

class _SpeechMessage {
  const _SpeechMessage({required this.text, required this.context});

  final String text;
  final String context;
}
