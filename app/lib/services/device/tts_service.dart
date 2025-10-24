import 'package:flutter_tts/flutter_tts.dart';
import 'dart:developer' as developer;
import 'dart:collection';

/// Prioridad de mensajes TTS para mejor gestión de cola
enum TtsPriority {
  /// Mensajes críticos de seguridad (ej: "Cruzar con precaución")
  critical(3),

  /// Instrucciones de navegación importantes (ej: "Gira a la izquierda en 50 metros")
  high(2),

  /// Información general (ej: "Llegaste a tu destino")
  normal(1),

  /// Mensajes de baja prioridad (ej: confirmaciones)
  low(0);

  const TtsPriority(this.value);
  final int value;
}

/// Servicio TTS mejorado con caché, priorización y configuración avanzada
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

  // Cola con prioridad (ordenada por priority)
  final List<_PrioritySpeechMessage> _messageQueue = [];

  // Configuración de voz optimizada para accesibilidad
  double _rate = 0.45; // Velocidad lenta para mejor comprensión
  double _pitch = 0.95; // Tono ligeramente bajo, más natural
  double _volume = 1.0; // Volumen máximo por defecto

  // Caché de texto reciente para evitar repeticiones innecesarias
  final Queue<String> _recentMessages = Queue();
  static const int _maxRecentCache = 5;
  static const Duration _duplicateWindow = Duration(seconds: 3);
  final Map<String, DateTime> _messageTimestamps = {};

  // Historial de mensajes (para funcionalidad "repetir último")
  String? _lastSpokenText;
  final List<String> _speechHistory = [];
  static const int maxHistorySize = 20; // Aumentado de 10 a 20

  // Configuración de audio optimizada
  bool _useEnhancedVoice = true; // Intentar usar voces premium del sistema
  String? _selectedVoice; // Voz actualmente seleccionada

  /// Inicializa el motor TTS con configuración optimizada
  Future<void> initialize() async {
    if (_initialized) return;

    developer.log('🔊 [TTS] Inicializando motor TTS mejorado');

    // Configurar TTS nativo con optimizaciones
    await _initializeNativeTts();

    _initialized = true;
    developer.log('✅ [TTS] Motor TTS listo');
  }

  Future<void> _initializeNativeTts() async {
    // Configuración mejorada para voz más natural
    await _tts.setLanguage('es-ES');

    // Aplicar configuración inicial
    await _tts.setSpeechRate(_rate);
    await _tts.setVolume(_volume);
    await _tts.setPitch(_pitch);

    // Configurar callbacks para saber cuándo termina de hablar
    _tts.setCompletionHandler(() {
      developer.log('🔇 [TTS] Reproducción completada');
      _isSpeaking = false;
      _processQueue(); // Procesar siguiente mensaje en cola
    });

    _tts.setErrorHandler((msg) {
      developer.log('❌ [TTS] Error: $msg');
      _isSpeaking = false;
      _processQueue();
    });

    // Intentar usar voces del sistema de alta calidad
    if (_useEnhancedVoice) {
      await _selectBestVoice();
    }

    _initialized = true;
  }

  /// Selecciona la mejor voz disponible del sistema
  Future<void> _selectBestVoice() async {
    try {
      final voices = await _tts.getVoices;
      if (voices == null || voices.isEmpty) {
        developer.log('⚠️ [TTS] No hay voces disponibles en el sistema');
        return;
      }

      developer.log('🎙️ [TTS] Voces disponibles: ${voices.length}');

      // Buscar voces españolas de alta calidad
      // Prioridad: voces neuronales > premium > estándar
      final spanishVoices = voices.where((voice) {
        final name = voice['name']?.toString().toLowerCase() ?? '';
        final locale = voice['locale']?.toString().toLowerCase() ?? '';
        return locale.contains('es') || locale.contains('spa');
      }).toList();

      if (spanishVoices.isEmpty) {
        developer.log('⚠️ [TTS] No hay voces españolas disponibles');
        return;
      }

      // Ordenar por calidad (neural/premium primero)
      spanishVoices.sort((a, b) {
        final nameA = a['name']?.toString().toLowerCase() ?? '';
        final nameB = b['name']?.toString().toLowerCase() ?? '';

        // Priorizar voces neuronales o premium
        if (nameA.contains('neural') && !nameB.contains('neural')) return -1;
        if (!nameA.contains('neural') && nameB.contains('neural')) return 1;
        if (nameA.contains('premium') && !nameB.contains('premium')) return -1;
        if (!nameA.contains('premium') && nameB.contains('premium')) return 1;

        // Preferir voces femeninas (más claras generalmente)
        if (nameA.contains('female') && !nameB.contains('female')) return -1;
        if (!nameA.contains('female') && nameB.contains('female')) return 1;

        return 0;
      });

      final bestVoice = spanishVoices.first;
      _selectedVoice = bestVoice['name']?.toString();

      await _tts.setVoice({
        'name': bestVoice['name'],
        'locale': bestVoice['locale'],
      });

      developer.log('✅ [TTS] Voz seleccionada: $_selectedVoice');
    } catch (e) {
      developer.log('⚠️ [TTS] Error al cargar voces: $e');
    }
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

  /// Procesa la cola de mensajes pendientes con priorización
  void _processQueue() {
    if (_messageQueue.isEmpty || _isSpeaking) return;

    // Ordenar por prioridad (mayor valor = mayor prioridad)
    _messageQueue.sort((a, b) => b.priority.value.compareTo(a.priority.value));

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

  /// Verifica si un mensaje es duplicado reciente
  bool _isDuplicateMessage(String text) {
    final now = DateTime.now();

    // Limpiar timestamps antiguos
    _messageTimestamps.removeWhere(
      (key, timestamp) => now.difference(timestamp) > _duplicateWindow,
    );

    // Verificar si el mensaje ya se habló recientemente
    if (_messageTimestamps.containsKey(text)) {
      final lastTime = _messageTimestamps[text]!;
      if (now.difference(lastTime) < _duplicateWindow) {
        developer.log('🔇 [TTS] Mensaje duplicado ignorado: "${text.substring(0, text.length > 30 ? 30 : text.length)}..."');
        return true;
      }
    }

    return false;
  }

  /// Habla un texto con pausas naturales y gestión inteligente de cola
  Future<void> speak(
    String text, {
    bool urgent = false,
    String? context,
    TtsPriority priority = TtsPriority.normal,
  }) async {
    if (text.trim().isEmpty) return;

    // Asegurar inicialización
    if (!_initialized) {
      await initialize();
    }

    try {
      final targetContext = context ?? _activeContext;

      // Verificar duplicados (excepto mensajes críticos)
      if (priority != TtsPriority.critical && _isDuplicateMessage(text)) {
        return;
      }

      // Evitar hablar si el contexto no coincide y no es urgente/crítico
      if (targetContext != _activeContext && !urgent && priority != TtsPriority.critical) {
        developer.log(
          '🔇 [TTS] Mensaje descartado por contexto inactivo ($targetContext)',
        );
        return;
      }

      // Guardar en historial
      _lastSpokenText = text;
      _speechHistory.insert(0, text);

      // Mantener máximo N mensajes en historial
      if (_speechHistory.length > maxHistorySize) {
        _speechHistory.removeRange(maxHistorySize, _speechHistory.length);
      }

      // Registrar timestamp
      _messageTimestamps[text] = DateTime.now();

      final message = _PrioritySpeechMessage(
        text: text,
        context: targetContext,
        priority: priority,
      );

      // Si es urgente o crítico, interrumpir y limpiar cola de baja prioridad
      if (urgent || priority == TtsPriority.critical) {
        await stop(clearQueue: false); // Mantener mensajes críticos en cola

        // Limpiar solo mensajes de baja prioridad
        _messageQueue.removeWhere((msg) =>
            msg.priority.value < TtsPriority.high.value);

        _isSpeaking = false;
        await _speakNow(message);
      } else {
        // Si no está hablando, hablar inmediatamente
        if (!_isSpeaking) {
          await _speakNow(message);
        } else {
          if (_currentContext == targetContext) {
            // Misma pantalla: encolar con prioridad
            _messageQueue.add(message);
            developer.log(
              '📋 [TTS] Mensaje encolado (prioridad: ${priority.name}): "${text.substring(0, text.length > 30 ? 30 : text.length)}..."',
            );
          } else {
            // Otra pantalla: interrumpir solo si prioridad alta
            if (priority == TtsPriority.high) {
              await stop();
              await _speakNow(message);
            } else {
              // Ignorar mensaje de baja prioridad de otro contexto
              developer.log(
                '🔇 [TTS] Mensaje ignorado (contexto diferente, baja prioridad)',
              );
            }
          }
        }
      }
    } catch (e) {
      developer.log('❌ [TTS] Error: $e');
      _isSpeaking = false;
    }
  }

  /// Habla inmediatamente (uso interno)
  Future<void> _speakNow(_PrioritySpeechMessage message) async {
    _isSpeaking = true;
    _currentContext = message.context;

    // Usar TTS nativo
    final text = message.text;
    final priorityIcon = _getPriorityIcon(message.priority);

    developer.log(
      '$priorityIcon [TTS] (${message.context}) [${message.priority.name}] "${text.substring(0, text.length > 50 ? 50 : text.length)}..."',
    );

    // Agregar pausas naturales para mejor comprensión
    // . → pausa larga, , → pausa corta
    final textWithPauses = text
        .replaceAll('.', '... ')
        .replaceAll(',', ', ')
        .replaceAll(';', '; ');

    await _tts.speak(textWithPauses);
  }

  String _getPriorityIcon(TtsPriority priority) {
    switch (priority) {
      case TtsPriority.critical:
        return '🚨';
      case TtsPriority.high:
        return '🔊';
      case TtsPriority.normal:
        return '🔉';
      case TtsPriority.low:
        return '🔈';
    }
  }

  /// Anuncia una instrucción de navegación importante con prioridad alta
  Future<void> announceNavigation(
    String instruction, {
    bool urgent = false,
  }) async {
    // Instrucciones de navegación siempre con prioridad alta
    await speak(
      'Atención. $instruction',
      urgent: urgent,
      priority: urgent ? TtsPriority.critical : TtsPriority.high,
    );
  }

  /// Anuncia un peligro o advertencia crítica
  Future<void> announceWarning(String warning) async {
    await speak(
      '¡Atención! $warning',
      urgent: true,
      priority: TtsPriority.critical,
    );
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

  /// Establece la velocidad de habla (0.1 = muy lento, 1.0 = normal, 2.0 = rápido)
  Future<void> setRate(double rate) async {
    _rate = rate.clamp(0.1, 2.0);
    await _tts.setSpeechRate(_rate);
    developer.log('🎚️ [TTS] Velocidad ajustada: $_rate');
  }

  /// Establece el tono de voz (0.5 = grave, 1.0 = normal, 2.0 = agudo)
  Future<void> setPitch(double pitch) async {
    _pitch = pitch.clamp(0.5, 2.0);
    await _tts.setPitch(_pitch);
    developer.log('🎵 [TTS] Tono ajustado: $_pitch');
  }

  /// Establece el volumen (0.0 = silencio, 1.0 = máximo)
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    await _tts.setVolume(_volume);
    developer.log('🔊 [TTS] Volumen ajustado: $_volume');
  }

  /// Obtiene la configuración actual de audio
  Map<String, dynamic> getAudioConfig() {
    return {
      'rate': _rate,
      'pitch': _pitch,
      'volume': _volume,
      'voice': _selectedVoice ?? 'default',
      'enhancedVoice': _useEnhancedVoice,
    };
  }

  /// Aplica un perfil de audio predefinido
  Future<void> applyAudioProfile(AudioProfile profile) async {
    switch (profile) {
      case AudioProfile.accessibility:
        // Optimizado para personas con discapacidad visual
        await setRate(0.4); // Muy lento
        await setPitch(0.95); // Ligeramente grave
        await setVolume(1.0); // Volumen máximo
        break;

      case AudioProfile.normal:
        // Configuración estándar
        await setRate(0.5);
        await setPitch(1.0);
        await setVolume(0.8);
        break;

      case AudioProfile.fast:
        // Para usuarios experimentados
        await setRate(0.7);
        await setPitch(1.05);
        await setVolume(0.8);
        break;

      case AudioProfile.quiet:
        // Para ambientes silenciosos
        await setRate(0.45);
        await setPitch(0.9);
        await setVolume(0.6);
        break;
    }

    developer.log('🎛️ [TTS] Perfil aplicado: ${profile.name}');
  }

  /// Para la reproducción y limpia la cola
  Future<void> stop({bool clearQueue = true}) async {
    if (!_initialized) return;
    try {
      await _tts.stop();
      if (clearQueue) {
        _messageQueue.clear();
        developer.log('🛑 [TTS] Detenido (cola limpiada)');
      } else {
        _messageQueue.removeWhere((msg) => msg.context != _activeContext);
        developer.log('🛑 [TTS] Detenido (mensajes críticos preservados)');
      }
      _isSpeaking = false;
      _currentContext = null;
    } catch (e) {
      developer.log('❌ [TTS] Error al detener: $e');
    }
  }

  /// Obtiene estadísticas del servicio TTS
  Map<String, dynamic> getStats() {
    return {
      'initialized': _initialized,
      'isSpeaking': _isSpeaking,
      'queueSize': _messageQueue.length,
      'historySize': _speechHistory.length,
      'activeContext': _activeContext,
      'currentContext': _currentContext,
      'config': getAudioConfig(),
    };
  }

  /// Obtiene el tamaño actual de la cola
  int get queueSize => _messageQueue.length;

  /// Verifica si hay mensajes críticos en cola
  bool get hasCriticalMessages =>
      _messageQueue.any((msg) => msg.priority == TtsPriority.critical);

  /// Verifica si TTS está hablando actualmente
  bool get isSpeaking => _isSpeaking;

  /// Espera a que TTS termine de hablar
  Future<void> waitUntilDone() async {
    while (_isSpeaking || _messageQueue.isNotEmpty) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }
}

/// Perfiles de audio predefinidos para diferentes situaciones
enum AudioProfile {
  /// Optimizado para accesibilidad (lento, claro, volumen alto)
  accessibility,

  /// Configuración normal
  normal,

  /// Velocidad rápida para usuarios experimentados
  fast,

  /// Volumen bajo para ambientes silenciosos
  quiet,
}

/// Mensaje TTS con prioridad
class _PrioritySpeechMessage {
  const _PrioritySpeechMessage({
    required this.text,
    required this.context,
    required this.priority,
  });

  final String text;
  final String context;
  final TtsPriority priority;
}
