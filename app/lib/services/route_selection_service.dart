import 'dart:developer' as developer;
// ============================================================================
// ROUTE SELECTION SERVICE
// ============================================================================
// Maneja la presentación de múltiples opciones de ruta y selección por voz
// ============================================================================

import 'dart:async';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'red_bus_service.dart';
import 'tts_service.dart';

class RouteSelectionService {
  static final RouteSelectionService instance = RouteSelectionService._();
  RouteSelectionService._();

  final TtsService _tts = TtsService.instance;
  final stt.SpeechToText _speech = stt.SpeechToText();

  RouteOptions? _currentOptions;
  bool _isListening = false;

  /// Presenta las opciones de ruta al usuario usando TTS
  Future<void> presentOptions(RouteOptions options) async {
    _currentOptions = options;

    developer.log('🗣️  Presentando ${options.optionsCount} opciones de ruta');

    // Construir mensaje de presentación
    final messages = <String>[];

    if (options.optionsCount == 1) {
      // Solo una opción disponible
      messages.add('Se encontró una ruta disponible.');
      messages.add(options.getOptionSummary(0));
      messages.add('Di "aceptar" para continuar.');
    } else {
      // Múltiples opciones
      messages.add('Se encontraron ${options.optionsCount} rutas disponibles.');

      for (int i = 0; i < options.optionsCount; i++) {
        messages.add(options.getOptionSummary(i));
      }

      messages.add(
        'Di el número de la opción que prefieres. Por ejemplo, "opción uno" o "número dos".',
      );
    }

    // Anunciar todas las opciones
    for (final message in messages) {
      await _tts.speak(message);
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  /// Inicia escucha de selección por voz
  Future<int?> waitForSelection() async {
    if (_currentOptions == null) {
      developer.log('❌ No hay opciones disponibles');
      return null;
    }

    if (_currentOptions!.optionsCount == 1) {
      // Si solo hay una opción, preguntar confirmación
      return await _waitForConfirmation();
    } else {
      // Si hay múltiples, esperar número de opción
      return await _waitForOptionNumber();
    }
  }

  /// Espera confirmación para una sola opción
  Future<int?> _waitForConfirmation() async {
    await _tts.speak('Di "sí", "aceptar" o "confirmar" para continuar.');

    final result = await _listenForSpeech(timeoutSeconds: 10);
    if (result == null) return null;

    final normalized = _normalizeText(result);

    if (_isPositiveConfirmation(normalized)) {
      await _tts.speak('Perfecto, iniciando navegación.');
      return 0; // Primera opción
    } else {
      await _tts.speak('Búsqueda cancelada.');
      return null;
    }
  }

  /// Espera que el usuario diga el número de opción
  Future<int?> _waitForOptionNumber() async {
    const maxAttempts = 3;
    int attempt = 0;

    while (attempt < maxAttempts) {
      attempt++;

      final result = await _listenForSpeech(timeoutSeconds: 15);
      if (result == null) {
        if (attempt < maxAttempts) {
          await _tts.speak(
            'No escuché tu respuesta. Por favor, di el número de la opción que prefieres.',
          );
        }
        continue;
      }

      final normalized = _normalizeText(result);
      final optionNumber = _extractOptionNumber(normalized);

      if (optionNumber != null &&
          optionNumber >= 1 &&
          optionNumber <= _currentOptions!.optionsCount) {
        final index = optionNumber - 1;
        await _tts.speak(
          'Has elegido la opción $optionNumber. Iniciando navegación.',
        );
        return index;
      } else {
        if (attempt < maxAttempts) {
          await _tts.speak(
            'No entendí tu selección. Di el número de la opción, por ejemplo, "uno", "dos" o "tres".',
          );
        }
      }
    }

    await _tts.speak(
      'No pude entender tu selección. Seleccionando la primera opción automáticamente.',
    );
    return 0; // Default a primera opción
  }

  /// Escucha voz del usuario
  Future<String?> _listenForSpeech({int timeoutSeconds = 10}) async {
    if (!_isListening) {
      final available = await _speech.initialize(
        onError: (error) => developer.log('❌ Error en reconocimiento de voz: $error'),
        onStatus: (status) => developer.log('🎤 Estado de voz: $status'),
      );

      if (!available) {
        developer.log('❌ Reconocimiento de voz no disponible');
        return null;
      }
    }

    final completer = Completer<String?>();

    await _speech.listen(
      onResult: (result) {
        if (result.finalResult) {
          completer.complete(result.recognizedWords);
        }
      },
      listenFor: Duration(seconds: timeoutSeconds),
      pauseFor: const Duration(seconds: 3),
      localeId: 'es_ES',
    );

    _isListening = true;

    // Timeout
    Future.delayed(Duration(seconds: timeoutSeconds + 1), () {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    });

    final result = await completer.future;

    await _speech.stop();
    _isListening = false;

    return result;
  }

  /// Normaliza texto para comparación
  String _normalizeText(String text) {
    return text
        .toLowerCase()
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .trim();
  }

  /// Verifica si es una confirmación positiva
  bool _isPositiveConfirmation(String text) {
    final positiveWords = [
      'si',
      'sí',
      'yes',
      'ok',
      'vale',
      'aceptar',
      'acepto',
      'confirmar',
      'confirmo',
      'adelante',
      'continuar',
      'continuo',
    ];

    return positiveWords.any((word) => text.contains(word));
  }

  /// Extrae número de opción del texto hablado
  int? _extractOptionNumber(String text) {
    // Buscar números directos
    final numberMatch = RegExp(r'\b(\d+)\b').firstMatch(text);
    if (numberMatch != null) {
      return int.tryParse(numberMatch.group(1)!);
    }

    // Mapeo de palabras a números
    final numberWords = {
      'uno': 1,
      'primera': 1,
      'dos': 2,
      'segunda': 2,
      'tres': 3,
      'tercera': 3,
      'cuatro': 4,
      'cuarta': 4,
      'cinco': 5,
      'quinta': 5,
    };

    for (final entry in numberWords.entries) {
      if (text.contains(entry.key)) {
        return entry.value;
      }
    }

    return null;
  }

  /// Limpia el estado actual
  void clear() {
    _currentOptions = null;
    _isListening = false;
  }
}
