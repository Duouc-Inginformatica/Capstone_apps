import 'package:flutter/material.dart';
import '../services/device/voice_nlp_service.dart';
import '../services/device/tts_service.dart';
import '../services/debug_logger.dart';

/// Ejemplo de integración del servicio de NLP local en MapScreen
/// 
/// Este mixin reemplaza el procesamiento de comandos basado en regex
/// por un sistema de NLP local con aceleración NPU
/// 
/// USO:
/// ```dart
/// class _MapScreenState extends State<MapScreen> with VoiceNlpCommandHandler {
///   @override
///   void initState() {
///     super.initState();
///     initializeNlp(); // Inicializar NLP
///   }
///   
///   void _onSpeechResult(String text) {
///     processVoiceCommandWithNlp(text); // Procesar con NLP
///   }
/// }
/// ```
mixin VoiceNlpCommandHandler<T extends StatefulWidget> on State<T> {
  final VoiceNlpService _nlpService = VoiceNlpService.instance;
  final TtsService _ttsService = TtsService.instance;

  /// Inicializa el servicio de NLP
  Future<void> initializeNlp() async {
    await _nlpService.initialize();
    DebugLogger.info('🧠 [NLP] Sistema de NLP local inicializado', context: 'VoiceNlp');
  }

  /// Procesa un comando de voz usando NLP local
  Future<void> processVoiceCommandWithNlp(String text) async {
    if (!_nlpService.isValidCommand(text)) {
      await _ttsService.speak('Comando demasiado corto. Por favor intenta de nuevo.');
      return;
    }

    DebugLogger.navigation('🎤 Procesando comando: "$text"');

    try {
      // Procesar comando con NLP
      final result = await _nlpService.processCommand(text);
      
      final intent = result['intent'] as String;
      final confidence = result['confidence'] as double;
      final entities = result['entities'] as Map<String, dynamic>;

      DebugLogger.navigation(
        '✅ NLP Result: intent=$intent, confidence=${confidence.toStringAsFixed(2)}',
      );

      // Ejecutar acción según la intención
      await _handleIntent(intent, entities, text);

    } catch (e) {
      DebugLogger.network('❌ Error procesando comando NLP: $e');
      await _ttsService.speak('No pude procesar el comando. Intenta de nuevo.');
    }
  }

  /// Maneja la intención detectada por el NLP
  Future<void> _handleIntent(
    String intent,
    Map<String, dynamic> entities,
    String originalText,
  ) async {
    switch (intent) {
      case 'navigate':
        await _handleNavigateIntent(entities);
        break;

      case 'location_query':
        await _handleLocationQueryIntent();
        break;

      case 'nearby_stops':
        await _handleNearbyStopsIntent(entities);
        break;

      case 'bus_arrivals':
        await _handleBusArrivalsIntent(entities);
        break;

      case 'cancel':
        await _handleCancelIntent();
        break;

      case 'repeat':
        await _handleRepeatIntent();
        break;

      case 'next_instruction':
        await _handleNextInstructionIntent();
        break;

      case 'time_query':
        await _handleTimeQueryIntent();
        break;

      case 'help':
        await _handleHelpIntent();
        break;

      default:
        DebugLogger.navigation('⚠️ Intención desconocida: $intent');
        await _ttsService.speak('No entendí el comando. ¿Puedes repetirlo?');
    }
  }

  // =========================================================================
  // HANDLERS DE INTENCIONES (A implementar en MapScreen)
  // =========================================================================

  /// Maneja comando de navegación: "ir a [destino]"
  Future<void> _handleNavigateIntent(Map<String, dynamic> entities) async {
    final destination = entities['normalized_destination'] as String?;
    
    if (destination == null || destination.isEmpty) {
      await _ttsService.speak('No detecté el destino. ¿A dónde quieres ir?');
      return;
    }

    DebugLogger.navigation('🎯 Navegando a: $destination');
    await _ttsService.speak('Buscando ruta a $destination');

    // TODO: Llamar a _planRouteToDestination(destination)
    // Este método debe estar implementado en MapScreen
    // await _planRouteToDestination(destination);
  }

  /// Maneja consulta de ubicación: "dónde estoy"
  Future<void> _handleLocationQueryIntent() async {
    DebugLogger.navigation('📍 Consultando ubicación actual');
    
    // TODO: Llamar a _announceCurrentLocation()
    // Este método debe estar implementado en MapScreen
    // await _announceCurrentLocation();
    
    await _ttsService.speak('Consultando tu ubicación actual');
  }

  /// Maneja búsqueda de paraderos cercanos
  Future<void> _handleNearbyStopsIntent(Map<String, dynamic> entities) async {
    final radius = entities['radius'] as int? ?? 500;
    
    DebugLogger.navigation('🚏 Buscando paraderos en radio de $radius metros');
    await _ttsService.speak('Buscando paraderos cercanos');

    // TODO: Llamar a _announceNearbyStops(radius)
    // await _announceNearbyStops(radius: radius);
  }

  /// Maneja consulta de llegadas de buses
  Future<void> _handleBusArrivalsIntent(Map<String, dynamic> entities) async {
    final stopCode = entities['stop_code'] as String?;
    
    DebugLogger.navigation('🚌 Consultando llegadas${stopCode != null ? ' para $stopCode' : ''}');
    await _ttsService.speak('Consultando llegadas de buses');

    // TODO: Implementar lógica de consulta de llegadas
    // if (stopCode != null) {
    //   await _getBusArrivalsForStop(stopCode);
    // } else {
    //   await _getBusArrivalsNearby();
    // }
  }

  /// Maneja cancelación de ruta
  Future<void> _handleCancelIntent() async {
    DebugLogger.navigation('❌ Cancelando ruta actual');
    await _ttsService.speak('Cancelando ruta');

    // TODO: Llamar a _cancelCurrentRoute()
    // await _cancelCurrentRoute();
  }

  /// Maneja repetición de instrucción
  Future<void> _handleRepeatIntent() async {
    DebugLogger.navigation('🔁 Repitiendo instrucción actual');
    
    // TODO: Llamar a _repeatCurrentInstruction()
    // await _repeatCurrentInstruction();
  }

  /// Maneja siguiente instrucción
  Future<void> _handleNextInstructionIntent() async {
    DebugLogger.navigation('➡️ Avanzando a siguiente instrucción');
    
    // TODO: Llamar a _nextInstruction()
    // await _nextInstruction();
  }

  /// Maneja consulta de hora
  Future<void> _handleTimeQueryIntent() async {
    final now = DateTime.now();
    final hour = now.hour;
    final minute = now.minute.toString().padLeft(2, '0');
    
    await _ttsService.speak('Son las $hour horas con $minute minutos');
  }

  /// Maneja solicitud de ayuda
  Future<void> _handleHelpIntent() async {
    final examples = _nlpService.getCommandExamples();
    
    var helpMessage = 'Puedes usar estos comandos. ';
    
    for (var category in examples.entries) {
      helpMessage += '${category.key}: ';
      helpMessage += category.value.take(2).join(', ');
      helpMessage += '. ';
    }

    await _ttsService.speak(helpMessage);
  }

  /// Obtiene sugerencias de comandos según el contexto
  List<String> getCommandSuggestions({String? context}) {
    return _nlpService.getSuggestions(context: context);
  }
}

// ============================================================================
// EJEMPLO DE USO EN MAPSCREEN
// ============================================================================

/// Ejemplo de cómo integrar VoiceNlpCommandHandler en MapScreen
/// 
/// ```dart
/// class _MapScreenState extends State<MapScreen> 
///     with VoiceNlpCommandHandler, TimerManagerMixin {
///   
///   @override
///   void initState() {
///     super.initState();
///     
///     // Inicializar NLP
///     WidgetsBinding.instance.addPostFrameCallback((_) {
///       initializeNlp();
///     });
///   }
///   
///   // Callback de speech_to_text
///   void _onSpeechResult(SpeechRecognitionResult result) {
///     if (result.finalResult) {
///       final text = result.recognizedWords;
///       
///       // ✅ NUEVO: Usar NLP en lugar de regex
///       processVoiceCommandWithNlp(text);
///       
///       // ❌ VIEJO: Procesamiento con regex (eliminar)
///       // _processVoiceCommand(text);
///     }
///   }
///   
///   // Implementar métodos específicos de navegación
///   Future<void> _planRouteToDestination(String destination) async {
///     // Lógica de planificación de ruta
///   }
///   
///   Future<void> _announceCurrentLocation() async {
///     // Anunciar ubicación actual
///   }
///   
///   Future<void> _announceNearbyStops({int radius = 500}) async {
///     // Anunciar paradas cercanas
///   }
/// }
/// ```
