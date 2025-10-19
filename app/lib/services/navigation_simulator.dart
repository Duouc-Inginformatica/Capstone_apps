// ============================================================================
// NAVIGATION SIMULATOR - Simulación Realista de Navegación
// ============================================================================
// Simula movimiento de persona caminando:
// - Velocidad realista (1.2 m/s para persona no vidente)
// - Orientación basada en dirección de movimiento
// - Instrucciones con nombres de calles y advertencias
// - Detección de giros y cruces
// - Variación de velocidad en giros y cruces
// ============================================================================

import 'dart:async';
import 'dart:math' as math;
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'tts_service.dart';
import 'geometry_service.dart';

/// Tipo de maniobra en navegación
enum ManeuverType {
  start, // Iniciar
  continueOn, // Continuar por
  turnLeft, // Girar a la izquierda
  turnRight, // Girar a la derecha
  turnSlightLeft, // Girar levemente a la izquierda
  turnSlightRight, // Girar levemente a la derecha
  turnSharpLeft, // Giro cerrado a la izquierda
  turnSharpRight, // Giro cerrado a la derecha
  keepLeft, // Mantenerse a la izquierda
  keepRight, // Mantenerse a la derecha
  uturn, // Dar vuelta en U
  roundabout, // Rotonda
  arrive, // Llegar al destino
  waypoint, // Punto intermedio
}

/// Instrucción de navegación enriquecida
class NavigationInstruction {
  final ManeuverType maneuverType;
  final String streetName;
  final double distanceMeters;
  final double heading; // Dirección en grados (0-360)
  final bool isCrossing; // ¿Es un cruce de calle?
  final bool hasTraffic; // ¿Tiene precaución por tráfico?
  final String? nextStreetName; // Nombre de la siguiente calle

  NavigationInstruction({
    required this.maneuverType,
    required this.streetName,
    required this.distanceMeters,
    required this.heading,
    this.isCrossing = false,
    this.hasTraffic = false,
    this.nextStreetName,
  });

  /// Genera anuncio de voz natural
  String toVoiceAnnouncement() {
    String announcement = '';

    // Simplificar nombres de calles (especialmente paraderos)
    final simplifiedStreet = _simplifyStreetName(streetName);
    final simplifiedNextStreet = nextStreetName != null
        ? _simplifyStreetName(nextStreetName!)
        : null;

    switch (maneuverType) {
      case ManeuverType.start:
        announcement = 'Inicie caminando por $simplifiedStreet';
        break;

      case ManeuverType.continueOn:
        announcement = 'Continúe por $simplifiedStreet';
        if (distanceMeters > 0) {
          announcement += ' durante ${_formatDistance(distanceMeters)}';
        }
        break;

      case ManeuverType.turnLeft:
        announcement = 'Gire a la izquierda';
        if (simplifiedNextStreet != null) {
          announcement += ' hacia $simplifiedNextStreet';
        }
        if (isCrossing) {
          announcement += '. Precaución, cruce de calle';
        }
        break;

      case ManeuverType.turnRight:
        announcement = 'Gire a la derecha';
        if (simplifiedNextStreet != null) {
          announcement += ' hacia $simplifiedNextStreet';
        }
        if (isCrossing) {
          announcement += '. Precaución, cruce de calle';
        }
        break;

      case ManeuverType.turnSlightLeft:
        announcement = 'Doble levemente a la izquierda';
        if (simplifiedNextStreet != null) {
          announcement += ' hacia $simplifiedNextStreet';
        }
        break;

      case ManeuverType.turnSlightRight:
        announcement = 'Doble levemente a la derecha';
        if (simplifiedNextStreet != null) {
          announcement += ' hacia $simplifiedNextStreet';
        }
        break;

      case ManeuverType.turnSharpLeft:
        announcement = 'Giro cerrado a la izquierda';
        if (simplifiedNextStreet != null) {
          announcement += ' hacia $simplifiedNextStreet';
        }
        break;

      case ManeuverType.turnSharpRight:
        announcement = 'Giro cerrado a la derecha';
        if (simplifiedNextStreet != null) {
          announcement += ' hacia $simplifiedNextStreet';
        }
        break;

      case ManeuverType.keepLeft:
        announcement = 'Manténgase a la izquierda';
        break;

      case ManeuverType.keepRight:
        announcement = 'Manténgase a la derecha';
        break;

      case ManeuverType.uturn:
        announcement = 'De vuelta en U';
        break;

      case ManeuverType.arrive:
        announcement = 'Ha llegado a su destino';
        break;

      case ManeuverType.waypoint:
        announcement = 'Punto intermedio alcanzado';
        break;

      default:
        announcement = 'Continúe';
    }

    // Agregar advertencias de tráfico
    if (hasTraffic && !isCrossing) {
      announcement += '. Precaución con vehículos';
    }

    return announcement;
  }

  /// Simplifica nombres de calles para TTS (especialmente paraderos)
  String _simplifyStreetName(String name) {
    // Si es un paradero, simplificar a solo "Paradero"
    if (name.toLowerCase().contains('paradero') ||
        name.toLowerCase().contains('parada')) {
      return 'Paradero';
    }

    // Remover números de ruta de los paraderos (ej: "PA1234 / Av. Providencia" -> "Avenida Providencia")
    String cleaned = name;

    // Remover código de paradero (PA seguido de números)
    cleaned = cleaned.replaceAll(RegExp(r'PA\d+\s*[/\-]\s*'), '');

    // Remover código de parada genérico
    cleaned = cleaned.replaceAll(RegExp(r'Paradero\s+\d+\s*[/\-]\s*'), '');
    cleaned = cleaned.replaceAll(RegExp(r'Parada\s+\d+\s*[/\-]\s*'), '');

    // Limpiar espacios extra
    cleaned = cleaned.trim();

    // Si después de limpiar está vacío, usar el nombre original
    if (cleaned.isEmpty) {
      cleaned = name;
    }

    return cleaned;
  }

  String _formatDistance(double meters) {
    if (meters < 100) {
      return '${meters.round()} metros';
    } else if (meters < 1000) {
      final rounded = (meters / 50).round() * 50; // Redondear a 50m
      return '$rounded metros';
    } else {
      return '${(meters / 1000).toStringAsFixed(1)} kilómetros';
    }
  }
}

/// Simulador de navegación realista
class NavigationSimulator {
  static final NavigationSimulator instance = NavigationSimulator._();
  NavigationSimulator._();

  Timer? _simulationTimer;
  bool _isSimulating = false;
  int _currentPointIndex = 0;
  List<LatLng>? _currentRoute;
  List<NavigationInstruction>? _instructions;

  // Callbacks
  Function(Position)? onPositionUpdate;
  Function(NavigationInstruction)? onInstructionAnnounced;
  Function()? onSimulationComplete;

  bool get isSimulating => _isSimulating;

  /// Inicia simulación de navegación con instrucciones de GraphHopper
  Future<void> startSimulation({
    required List<LatLng> routeGeometry,
    required List<Instruction> graphhopperInstructions,
    Function(Position)? onPositionUpdate,
    Function(NavigationInstruction)? onInstructionAnnounced,
    Function()? onSimulationComplete,
  }) async {
    if (_isSimulating) {
      print('⚠️ [Simulator] Ya hay simulación activa');
      return;
    }

    if (routeGeometry.length < 2) {
      print('❌ [Simulator] Ruta muy corta');
      return;
    }

    _currentRoute = routeGeometry;
    _currentPointIndex = 0;
    this.onPositionUpdate = onPositionUpdate;
    this.onInstructionAnnounced = onInstructionAnnounced;
    this.onSimulationComplete = onSimulationComplete;

    // Convertir instrucciones de GraphHopper a instrucciones enriquecidas
    _instructions = _enrichInstructions(graphhopperInstructions, routeGeometry);

    print('🚶 [Simulator] Iniciando navegación realista');
    print('   📍 Puntos: ${routeGeometry.length}');
    print('   📋 Instrucciones: ${_instructions?.length ?? 0}');

    _isSimulating = true;

    // Anunciar primera instrucción
    if (_instructions != null && _instructions!.isNotEmpty) {
      final firstInstruction = _instructions!.first;
      TtsService.instance.speak(
        firstInstruction.toVoiceAnnouncement(),
        urgent: true,
      );
      onInstructionAnnounced?.call(firstInstruction);
    }

    // Iniciar loop de simulación
    _runSimulationLoop();
  }

  /// Convierte instrucciones de GraphHopper a instrucciones enriquecidas
  List<NavigationInstruction> _enrichInstructions(
    List<Instruction> ghInstructions,
    List<LatLng> geometry,
  ) {
    final enriched = <NavigationInstruction>[];

    for (int i = 0; i < ghInstructions.length; i++) {
      final gh = ghInstructions[i];
      final text = gh.text.toLowerCase();

      // Detectar tipo de maniobra
      ManeuverType maneuverType = ManeuverType.continueOn;
      bool isCrossing = false;
      bool hasTraffic = false;

      if (text.contains('inicie') || text.contains('comience') || i == 0) {
        maneuverType = ManeuverType.start;
      } else if (text.contains('gire a la izquierda') ||
          text.contains('turn left')) {
        maneuverType = ManeuverType.turnLeft;
        isCrossing = true;
        hasTraffic = true;
      } else if (text.contains('gire a la derecha') ||
          text.contains('turn right')) {
        maneuverType = ManeuverType.turnRight;
        isCrossing = true;
        hasTraffic = true;
      } else if (text.contains('levemente a la izquierda') ||
          text.contains('slight left')) {
        maneuverType = ManeuverType.turnSlightLeft;
      } else if (text.contains('levemente a la derecha') ||
          text.contains('slight right')) {
        maneuverType = ManeuverType.turnSlightRight;
      } else if (text.contains('cerrado') && text.contains('izquierda')) {
        maneuverType = ManeuverType.turnSharpLeft;
        isCrossing = true;
        hasTraffic = true;
      } else if (text.contains('cerrado') && text.contains('derecha')) {
        maneuverType = ManeuverType.turnSharpRight;
        isCrossing = true;
        hasTraffic = true;
      } else if (text.contains('manténgase a la izquierda') ||
          text.contains('keep left')) {
        maneuverType = ManeuverType.keepLeft;
      } else if (text.contains('manténgase a la derecha') ||
          text.contains('keep right')) {
        maneuverType = ManeuverType.keepRight;
      } else if (text.contains('vuelta en u') || text.contains('u-turn')) {
        maneuverType = ManeuverType.uturn;
        isCrossing = true;
        hasTraffic = true;
      } else if (text.contains('llegue') ||
          text.contains('destino') ||
          text.contains('arrive')) {
        maneuverType = ManeuverType.arrive;
      }

      // Detectar cruces adicionales por palabras clave
      if (text.contains('cruce') ||
          text.contains('cruza') ||
          text.contains('cross')) {
        isCrossing = true;
        hasTraffic = true;
      }

      // Extraer nombre de calle
      String streetName = _extractStreetName(gh.text);

      // Calcular heading (dirección) basado en geometría
      double heading = 0;
      if (geometry.length > i + 1) {
        heading = _calculateBearing(geometry[i], geometry[i + 1]);
      }

      // Obtener siguiente calle si es un giro
      String? nextStreetName;
      if (maneuverType == ManeuverType.turnLeft ||
          maneuverType == ManeuverType.turnRight ||
          maneuverType == ManeuverType.turnSlightLeft ||
          maneuverType == ManeuverType.turnSlightRight) {
        if (i + 1 < ghInstructions.length) {
          nextStreetName = _extractStreetName(ghInstructions[i + 1].text);
        }
      }

      enriched.add(
        NavigationInstruction(
          maneuverType: maneuverType,
          streetName: streetName,
          distanceMeters: gh.distanceMeters,
          heading: heading,
          isCrossing: isCrossing,
          hasTraffic: hasTraffic,
          nextStreetName: nextStreetName,
        ),
      );
    }

    return enriched;
  }

  /// Extrae nombre de calle de la instrucción de texto
  String _extractStreetName(String instructionText) {
    // Intentar extraer nombre entre comillas o después de "por", "hacia", "en"
    final patterns = [
      RegExp(r'por\s+([A-ZÁÉÍÓÚÑ][a-záéíóúñ\s]+)'),
      RegExp(r'hacia\s+([A-ZÁÉÍÓÚÑ][a-záéíóúñ\s]+)'),
      RegExp(r'en\s+([A-ZÁÉÍÓÚÑ][a-záéíóúñ\s]+)'),
      RegExp(r'calle\s+([A-ZÁÉÍÓÚÑ][a-záéíóúñ\s]+)'),
      RegExp(r'avenida\s+([A-ZÁÉÍÓÚÑ][a-záéíóúñ\s]+)'),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(instructionText);
      if (match != null && match.groupCount > 0) {
        return match.group(1)!.trim();
      }
    }

    // Si no encuentra, retornar "la calle"
    return 'la calle';
  }

  /// Ejecuta el loop de simulación
  void _runSimulationLoop() {
    if (_currentRoute == null || !_isSimulating) return;

    // Calcular distancia total
    double totalDistance = 0;
    for (int i = 0; i < _currentRoute!.length - 1; i++) {
      totalDistance += _distanceBetween(
        _currentRoute![i],
        _currentRoute![i + 1],
      );
    }

    // Velocidad base: 1.2 m/s (persona no vidente)
    const baseSpeed = 1.2;
    final totalDuration = totalDistance / baseSpeed;
    final totalPoints = _currentRoute!.length;

    // Intervalo base entre puntos
    int intervalMs = ((totalDuration * 1000) / totalPoints).ceil();
    if (intervalMs < 100) intervalMs = 100;
    if (intervalMs > 3000) intervalMs = 3000;

    print(
      '🚶 [Simulator] Distancia: ${totalDistance.round()}m | Duración: ${(totalDuration / 60).toStringAsFixed(1)}min',
    );

    int instructionIndex = 0;
    double accumulatedDistance = 0;
    double distanceToNextInstruction =
        _instructions != null && _instructions!.isNotEmpty
        ? _instructions![0].distanceMeters
        : double.infinity;

    void _step() {
      if (!_isSimulating || _currentPointIndex >= _currentRoute!.length) {
        _completeSimulation();
        return;
      }

      final currentPoint = _currentRoute![_currentPointIndex];

      // Calcular heading (dirección de movimiento)
      double heading = 0;
      double speed = baseSpeed;

      if (_currentPointIndex < _currentRoute!.length - 1) {
        final nextPoint = _currentRoute![_currentPointIndex + 1];
        heading = _calculateBearing(currentPoint, nextPoint);

        final segmentDistance = _distanceBetween(currentPoint, nextPoint);
        accumulatedDistance += segmentDistance;

        // Reducir velocidad en giros (cuando cambia el heading significativamente)
        if (_currentPointIndex > 0) {
          final prevPoint = _currentRoute![_currentPointIndex - 1];
          final prevHeading = _calculateBearing(prevPoint, currentPoint);
          final headingChange = (heading - prevHeading).abs();

          if (headingChange > 30) {
            speed = 0.8; // 20% más lento en giros
            print(
              '🔄 [Simulator] Giro detectado: ${headingChange.toStringAsFixed(0)}° | Velocidad: ${speed}m/s',
            );
          }
        }

        // Anunciar siguiente instrucción cuando llegamos a la distancia
        if (_instructions != null &&
            instructionIndex < _instructions!.length &&
            accumulatedDistance >= distanceToNextInstruction - 10) {
          final instruction = _instructions![instructionIndex];
          print(
            '🗣️ [Simulator] Instrucción ${instructionIndex + 1}: ${instruction.toVoiceAnnouncement()}',
          );

          TtsService.instance.speak(
            instruction.toVoiceAnnouncement(),
            urgent: true,
          );

          onInstructionAnnounced?.call(instruction);

          instructionIndex++;
          if (instructionIndex < _instructions!.length) {
            distanceToNextInstruction +=
                _instructions![instructionIndex].distanceMeters;
          }
        }
      } else {
        speed = 0; // Detenerse al final
      }

      // Crear posición simulada
      final position = Position(
        latitude: currentPoint.latitude,
        longitude: currentPoint.longitude,
        timestamp: DateTime.now(),
        accuracy: 5.0,
        altitude: 0.0,
        altitudeAccuracy: 0.0,
        heading: heading,
        headingAccuracy: 0.0,
        speed: speed,
        speedAccuracy: 0.0,
      );

      // Emitir posición
      onPositionUpdate?.call(position);

      // Avanzar al siguiente punto
      _currentPointIndex++;

      // Programar siguiente paso
      _simulationTimer = Timer(Duration(milliseconds: intervalMs), _step);
    }

    // Iniciar loop
    _step();
  }

  /// Completa la simulación
  void _completeSimulation() {
    print('✅ [Simulator] Simulación completada');
    _isSimulating = false;
    _simulationTimer?.cancel();
    onSimulationComplete?.call();
  }

  /// Detiene la simulación
  void stop() {
    print('🛑 [Simulator] Deteniendo simulación');
    _isSimulating = false;
    _simulationTimer?.cancel();
    _currentRoute = null;
    _instructions = null;
    _currentPointIndex = 0;
  }

  /// Calcula el ángulo de dirección entre dos puntos (bearing en grados)
  double _calculateBearing(LatLng from, LatLng to) {
    final lat1 = from.latitude * math.pi / 180;
    final lat2 = to.latitude * math.pi / 180;
    final dLon = (to.longitude - from.longitude) * math.pi / 180;

    final y = math.sin(dLon) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);

    final bearing = math.atan2(y, x) * 180 / math.pi;
    return (bearing + 360) % 360;
  }

  /// Calcula distancia entre dos puntos
  double _distanceBetween(LatLng p1, LatLng p2) {
    return Geolocator.distanceBetween(
      p1.latitude,
      p1.longitude,
      p2.latitude,
      p2.longitude,
    );
  }
}
