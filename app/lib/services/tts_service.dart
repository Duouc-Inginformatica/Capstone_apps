import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  TtsService._internal();
  static final TtsService instance = TtsService._internal();

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;

  // ============================================================================
  // SPRINT 4 CAP-28: Sistema de Repetición Mejorado
  // ============================================================================
  String? _lastSpokenText;
  final List<String> _speechHistory = [];
  static const int maxHistorySize = 10;

  Future<void> _ensureInit() async {
    if (_initialized) return;
    // Configure idioma/es-ES con fallback
    await _tts.setLanguage('es-ES');
    await _tts.setSpeechRate(0.5); // velocidad media
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    _initialized = true;
  }

  Future<void> speak(String text) async {
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

      // Interrumpe cualquier reproducción en curso antes de hablar
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {
      // Silencioso en caso de error de TTS
    }
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

  Future<void> stop() async {
    if (!_initialized) return;
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
