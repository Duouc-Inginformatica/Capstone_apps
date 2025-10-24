import 'package:flutter/material.dart';
import '../../services/device/tts_service.dart';

/// Mixin para el manejo de comandos de voz en la pantalla de mapa
/// 
/// Extrae la lógica de procesamiento de voz del MapScreen para mejor
/// organización y mantenibilidad del código.
mixin VoiceCommandHandler on State {
  // Campos requeridos que deben estar presentes en el State
  String get lastWords;
  set lastWords(String value);
  
  void Function(VoidCallback fn) get setStateCallback;
  
  // Métodos que deben implementarse en la clase principal
  void searchRouteToDestination(String destination);
  void requestDestinationConfirmation(String destination);
  void onIntegratedNavigationVoiceCommand(String command);
  void readNextInstruction();
  void repeatCurrentInstruction();
  void centerOnUserLocation();
  void readAllInstructions();
  void showSuccessNotification(String message);
  void showWarningNotification(String message);
  
  /// Extrae el destino de un comando de voz
  String? extractDestination(String command) {
    final trimmed = command.trim().toLowerCase();
    
    // Patrones de extracción más robustos
    final patterns = [
      RegExp(r'(?:ir a|voy a|ruta a|ruta hacia|llévame a|quiero ir a|navega a|navegar a)\s+(.+)',
          caseSensitive: false),
      RegExp(r'(?:buscar|busca)\s+(?:ruta a|ruta hacia)\s+(.+)',
          caseSensitive: false),
      RegExp(r'(?:cómo llego a|como llegar a|llegar a)\s+(.+)',
          caseSensitive: false),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(trimmed);
      if (match != null && match.groupCount >= 1) {
        final destination = match.group(1)?.trim();
        if (destination != null && destination.isNotEmpty) {
          return destination;
        }
      }
    }

    return null;
  }

  /// Convierte texto a Title Case
  String toTitleCase(String input) {
    if (input.isEmpty) return input;
    return input
        .split(' ')
        .map((word) =>
            word.isEmpty ? '' : word[0].toUpperCase() + word.substring(1).toLowerCase())
        .join(' ');
  }

  /// Normaliza texto eliminando acentos y caracteres especiales
  String normalizeText(String text) {
    const Map<String, String> replacements = {
      'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u',
      'ü': 'u', 'ñ': 'n',
      'Á': 'A', 'É': 'E', 'Í': 'I', 'Ó': 'O', 'Ú': 'U',
      'Ü': 'U', 'Ñ': 'N',
    };

    String normalized = text.toLowerCase();
    replacements.forEach((key, value) {
      normalized = normalized.replaceAll(key, value);
    });

    return normalized;
  }

  /// Verifica si un comando contiene intención de navegación
  bool containsNavigationIntent(String command) {
    final navigationKeywords = [
      'ir a', 'voy a', 'ruta a', 'ruta hacia',
      'llevame a', 'quiero ir a', 'navega a', 'navegar a',
      'buscar ruta', 'busca ruta', 'como llego a', 'llegar a',
    ];

    return navigationKeywords.any((keyword) => command.contains(keyword));
  }

  /// Procesa comandos de voz mejorados
  bool processVoiceCommandEnhanced(String command) {
    if (command.trim().isEmpty) return false;

    final normalized = normalizeText(command);

    // Primero probar comandos de navegación específicos (ayuda, orientación, etc.)
    if (handleNavigationCommand(normalized)) {
      setStateCallback(() {
        lastWords = command;
      });
      return true;
    }

    // 🚌 Comando para navegación integrada con Moovit (buses Red)
    if (normalized.contains('navegacion red') ||
        normalized.contains('ruta red') ||
        normalized.contains('bus red')) {
      final destination = extractDestination(command);
      if (destination != null && destination.isNotEmpty) {
        setStateCallback(() {
          lastWords = command;
        });

        // Llamar a navegación integrada con Moovit en vez de ruta normal
        onIntegratedNavigationVoiceCommand(command);
        return true;
      }
    }

    // Intentar extraer destino del comando original (sin normalizar demasiado)
    final destination = extractDestination(command);
    if (destination != null && destination.isNotEmpty) {
      final pretty = toTitleCase(destination);
      setStateCallback(() {
        lastWords = command;
      });

      // Feedback más natural
      showSuccessNotification('Buscando ruta a: $pretty');
      TtsService.instance.speak('Perfecto, buscando la ruta a $pretty');
      searchRouteToDestination(destination);
      return true;
    }

    // Si contiene palabras clave de navegación pero no se pudo extraer destino
    if (containsNavigationIntent(normalized)) {
      showWarningNotification(
        'No pude entender el destino. Intenta decir: "ir a [nombre del lugar]"',
      );
      TtsService.instance.speak(
        'No pude entender el destino. Puedes decir por ejemplo: ir a mall vivo los trapenses',
      );
      return true; // Se reconoció la intención aunque no el destino
    }

    // Si no se reconoce ningún comando específico
    setStateCallback(() {
      lastWords = command;
    });

    return false; // Comando no reconocido
  }

  /// Maneja comandos de navegación específicos
  bool handleNavigationCommand(String command) {
    // Ayuda general
    if (command.contains('ayuda') || command.contains('que puedo decir')) {
      TtsService.instance.speak(
        'Puedes decirme: ir a un lugar, repetir instrucción, siguiente instrucción, '
        'dónde estoy, cancelar navegación, o centrar mapa',
      );
      return true;
    }

    // Repetir instrucción actual
    if (command.contains('repetir') ||
        command.contains('repite') ||
        command.contains('otra vez')) {
      repeatCurrentInstruction();
      return true;
    }

    // Siguiente instrucción
    if (command.contains('siguiente') ||
        command.contains('proxima') ||
        command.contains('continua')) {
      readNextInstruction();
      return true;
    }

    // Leer todas las instrucciones
    if (command.contains('todas las instrucciones') ||
        command.contains('leer todo') ||
        command.contains('instrucciones completas')) {
      readAllInstructions();
      return true;
    }

    // Centrar en ubicación actual
    if (command.contains('donde estoy') ||
        command.contains('mi ubicacion') ||
        command.contains('centrar mapa')) {
      centerOnUserLocation();
      TtsService.instance.speak('Centrando el mapa en tu ubicación');
      return true;
    }

    // Cancelar navegación
    if (command.contains('cancelar') ||
        command.contains('detener') ||
        command.contains('parar')) {
      // Este comando se manejará en la clase principal
      return false;
    }

    return false;
  }

  /// Procesa el comando de voz principal (método de entrada)
  void processVoiceCommand(String command) {
    if (command.trim().isEmpty) return;

    final normalized = normalizeText(command);

    // Comando de confirmación (sí/no)
    if (normalized == 'si' || normalized == 'confirmar') {
      // Manejar confirmación en clase principal
      return;
    }

    if (normalized == 'no' || normalized == 'cancelar') {
      // Manejar cancelación en clase principal
      return;
    }

    // Intentar extraer destino del comando
    final destination = extractDestination(normalized);
    if (destination != null) {
      setStateCallback(() {
        lastWords = command;
      });

      // Solicitar confirmación antes de buscar ruta
      requestDestinationConfirmation(destination);
      return;
    }

    setStateCallback(() {
      lastWords = command;
    });
  }
}
