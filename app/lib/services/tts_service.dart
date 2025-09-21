import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  TtsService._internal();
  static final TtsService instance = TtsService._internal();

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;

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
      // Interrumpe cualquier reproducción en curso antes de hablar
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {
      // Silencioso en caso de error de TTS
    }
  }

  Future<void> stop() async {
    if (!_initialized) return;
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
