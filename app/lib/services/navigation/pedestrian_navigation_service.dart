// ============================================================================
// PEDESTRIAN NAVIGATION SERVICE - Sprint 6 CAP-31
// ============================================================================
// Navegación peatonal paso a paso con:
// - Instrucciones cada 20 metros
// - Detección de giros
// - Alertas de obstáculos (basado en datos OSM)
// - Soporte para usuarios con discapacidad visual
// ============================================================================

import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../device/tts_service.dart';
import '../device/haptic_feedback_service.dart';

enum TurnDirection {
  straight,
  slightLeft,
  left,
  sharpLeft,
  slightRight,
  right,
  sharpRight,
  uTurn,
}

enum ObstacleType {
  stairs,
  steepSlope,
  construction,
  narrowPath,
  intersection,
  crosswalk,
}

class NavigationInstruction {
  NavigationInstruction({
    required this.point,
    required this.direction,
    required this.distanceToNext,
    this.streetName,
    this.description,
    this.obstacle,
  });

  final LatLng point;
  final TurnDirection direction;
  final double distanceToNext; // metros
  final String? streetName;
  final String? description;
  final ObstacleType? obstacle;

  String get directionText {
    switch (direction) {
      case TurnDirection.straight:
        return 'Continúa recto';
      case TurnDirection.slightLeft:
        return 'Gira ligeramente a la izquierda';
      case TurnDirection.left:
        return 'Gira a la izquierda';
      case TurnDirection.sharpLeft:
        return 'Gira fuertemente a la izquierda';
      case TurnDirection.slightRight:
        return 'Gira ligeramente a la derecha';
      case TurnDirection.right:
        return 'Gira a la derecha';
      case TurnDirection.sharpRight:
        return 'Gira fuertemente a la derecha';
      case TurnDirection.uTurn:
        return 'Da la vuelta completa';
    }
  }

  String get obstacleText {
    if (obstacle == null) return '';

    switch (obstacle!) {
      case ObstacleType.stairs:
        return '⚠️ Hay escaleras adelante';
      case ObstacleType.steepSlope:
        return '⚠️ Pendiente pronunciada adelante';
      case ObstacleType.construction:
        return '⚠️ Construcción en el camino';
      case ObstacleType.narrowPath:
        return '⚠️ Camino estrecho adelante';
      case ObstacleType.intersection:
        return '⚠️ Te acercas a una intersección';
      case ObstacleType.crosswalk:
        return '⚠️ Paso peatonal adelante';
    }
  }

  String getFullInstruction() {
    final buffer = StringBuffer();

    buffer.write(directionText);

    if (streetName != null && streetName!.isNotEmpty) {
      buffer.write(' en $streetName');
    }

    if (distanceToNext > 0) {
      if (distanceToNext < 50) {
        buffer.write(' en ${distanceToNext.round()} metros');
      } else {
        buffer.write(' en ${(distanceToNext / 100).round() * 100} metros');
      }
    }

    if (description != null) {
      buffer.write('. $description');
    }

    if (obstacle != null) {
      buffer.write('. $obstacleText');
    }

    return buffer.toString();
  }
}

class PedestrianNavigationService {
  static final PedestrianNavigationService instance =
      PedestrianNavigationService._();
  PedestrianNavigationService._();

  final Distance _distance = const Distance();

  bool _isNavigating = false;
  List<NavigationInstruction> _instructions = [];
  int _currentInstructionIndex = 0;
  LatLng? _currentPosition;
  LatLng? _destination;

  StreamSubscription<Position>? _positionSubscription;
  Timer? _checkTimer;

  // Configuración
  static const double instructionTriggerDistance = 20.0; // metros
  static const double offRouteThreshold = 30.0; // metros
  static const Duration checkInterval = Duration(seconds: 3);

  // Callbacks
  Function(NavigationInstruction)? onInstructionTriggered;
  Function(double)? onDistanceToDestination;
  Function()? onDestinationReached;
  Function(ObstacleType)? onObstacleDetected;

  bool get isNavigating => _isNavigating;
  NavigationInstruction? get currentInstruction =>
      _currentInstructionIndex < _instructions.length
      ? _instructions[_currentInstructionIndex]
      : null;

  /// Inicia navegación peatonal
  Future<void> startNavigation({
    required List<LatLng> routePath,
    required LatLng destination,
    List<ObstacleType>? knownObstacles,
  }) async {
    _isNavigating = true;
    _destination = destination;
    _currentInstructionIndex = 0;

    // Generar instrucciones a partir del camino
    _instructions = _generateInstructions(
      routePath,
      knownObstacles: knownObstacles,
    );

    // Obtener posición actual
    final position = await Geolocator.getCurrentPosition();
    _currentPosition = LatLng(position.latitude, position.longitude);

    // Anunciar inicio
    await TtsService.instance.speak(
      'Iniciando navegación peatonal. ${_instructions.length} instrucciones generadas. '
      'Primera instrucción: ${_instructions.first.getFullInstruction()}',
    );

    // Vibración de inicio
    await HapticFeedbackService.instance.navigationStart();

    // Iniciar monitoreo de posición
    _startPositionMonitoring();
  }

  /// Detiene navegación
  Future<void> stopNavigation() async {
    _isNavigating = false;
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _checkTimer?.cancel();
    _checkTimer = null;

    _instructions.clear();
    _currentInstructionIndex = 0;
    _currentPosition = null;
    _destination = null;

    await TtsService.instance.speak('Navegación peatonal detenida');
  }

  /// Obtiene la próxima instrucción
  NavigationInstruction? getNextInstruction() {
    if (_currentInstructionIndex + 1 < _instructions.length) {
      return _instructions[_currentInstructionIndex + 1];
    }
    return null;
  }

  /// Obtiene todas las instrucciones restantes
  List<NavigationInstruction> getRemainingInstructions() {
    if (_currentInstructionIndex >= _instructions.length) {
      return [];
    }
    return _instructions.sublist(_currentInstructionIndex);
  }

  /// Anuncia distancia al destino
  Future<void> announceDistanceToDestination() async {
    if (_currentPosition == null || _destination == null) return;

    final distance = _distance.as(
      LengthUnit.Meter,
      _currentPosition!,
      _destination!,
    );

    String message;
    if (distance < 50) {
      message = 'Estás a ${distance.round()} metros de tu destino';
    } else if (distance < 1000) {
      message =
          'Estás a ${(distance / 100).round() * 100} metros de tu destino';
    } else {
      message =
          'Estás a ${(distance / 1000).toStringAsFixed(1)} kilómetros de tu destino';
    }

    await TtsService.instance.speak(message);
  }

  // ============================================================================
  // MÉTODOS PRIVADOS
  // ============================================================================

  void _startPositionMonitoring() {
    // Monitoreo continuo con GPS
    _positionSubscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10, // Actualizar cada 10 metros
          ),
        ).listen((position) {
          _onPositionUpdate(LatLng(position.latitude, position.longitude));
        });

    // Verificaciones periódicas
    _checkTimer = Timer.periodic(checkInterval, (_) {
      _performPeriodicChecks();
    });
  }

  void _onPositionUpdate(LatLng newPosition) {
    _currentPosition = newPosition;

    if (_currentInstructionIndex >= _instructions.length) {
      _checkDestinationReached();
      return;
    }

    final currentInstruction = _instructions[_currentInstructionIndex];
    final distanceToInstruction = _distance.as(
      LengthUnit.Meter,
      newPosition,
      currentInstruction.point,
    );

    // Si estamos cerca de la instrucción actual, avanzar a la siguiente
    if (distanceToInstruction < instructionTriggerDistance) {
      _advanceToNextInstruction();
    }

    // Verificar si hay obstáculo cercano
    if (currentInstruction.obstacle != null) {
      if (distanceToInstruction < 50) {
        _alertObstacle(currentInstruction.obstacle!);
      }
    }
  }

  void _performPeriodicChecks() {
    if (_currentPosition == null || !_isNavigating) return;

    // Verificar si está fuera de ruta
    if (_currentInstructionIndex < _instructions.length) {
      final targetPoint = _instructions[_currentInstructionIndex].point;
      final distanceToRoute = _distance.as(
        LengthUnit.Meter,
        _currentPosition!,
        targetPoint,
      );

      if (distanceToRoute > offRouteThreshold) {
        _handleOffRoute();
      }
    }

    // Verificar llegada al destino
    _checkDestinationReached();
  }

  void _advanceToNextInstruction() {
    _currentInstructionIndex++;

    if (_currentInstructionIndex >= _instructions.length) {
      // No hay más instrucciones, verificar destino
      _checkDestinationReached();
      return;
    }

    final nextInstruction = _instructions[_currentInstructionIndex];

    // Anunciar siguiente instrucción
    TtsService.instance.speak(nextInstruction.getFullInstruction());

    // Vibración según tipo de giro
    _vibrateForDirection(nextInstruction.direction);

    // Callback
    onInstructionTriggered?.call(nextInstruction);
  }

  void _checkDestinationReached() {
    if (_currentPosition == null || _destination == null) return;

    final distanceToDestination = _distance.as(
      LengthUnit.Meter,
      _currentPosition!,
      _destination!,
    );

    // Notificar distancia
    onDistanceToDestination?.call(distanceToDestination);

    // Verificar si llegó
    if (distanceToDestination < 10) {
      TtsService.instance.speak('¡Has llegado a tu destino!');
      HapticFeedbackService.instance.vibrateCustomPattern([0, 200, 100, 200, 100, 200]);
      onDestinationReached?.call();
      stopNavigation();
    }
  }

  void _handleOffRoute() {
    TtsService.instance.speak('Te has desviado de la ruta. Recalculando...');
    HapticFeedbackService.instance.vibrateCustomPattern([0, 100, 100, 100]);
    // Aquí se podría integrar con el servicio de routing para recalcular
  }

  void _alertObstacle(ObstacleType obstacle) {
    final instruction = _instructions[_currentInstructionIndex];
    TtsService.instance.speak(instruction.obstacleText);
    HapticFeedbackService.instance.vibrateCustomPattern([0, 300, 200, 300]);
    onObstacleDetected?.call(obstacle);
  }

  void _vibrateForDirection(TurnDirection direction) async {
    final hasVibrator = await HapticFeedbackService.instance.hasVibrator();
    if (!hasVibrator) return;

    switch (direction) {
      case TurnDirection.straight:
        HapticFeedbackService.instance.vibrate(duration: 100);
        break;
      case TurnDirection.slightLeft:
      case TurnDirection.slightRight:
        HapticFeedbackService.instance.vibrateCustomPattern([0, 100, 50, 100]);
        break;
      case TurnDirection.left:
      case TurnDirection.right:
        HapticFeedbackService.instance.vibrateCustomPattern([0, 150, 100, 150]);
        break;
      case TurnDirection.sharpLeft:
      case TurnDirection.sharpRight:
        HapticFeedbackService.instance.vibrateCustomPattern([0, 200, 100, 200, 100, 200]);
        break;
      case TurnDirection.uTurn:
        HapticFeedbackService.instance.vibrateCustomPattern([0, 300, 100, 300, 100, 300]);
        break;
    }
  }

  List<NavigationInstruction> _generateInstructions(
    List<LatLng> routePath, {
    List<ObstacleType>? knownObstacles,
  }) {
    final instructions = <NavigationInstruction>[];

    if (routePath.length < 2) return instructions;

    for (var i = 0; i < routePath.length - 1; i++) {
      final currentPoint = routePath[i];
      final nextPoint = routePath[i + 1];

      // Calcular dirección de giro
      TurnDirection direction = TurnDirection.straight;
      if (i > 0) {
        direction = _calculateTurnDirection(
          routePath[i - 1],
          currentPoint,
          nextPoint,
        );
      }

      // Calcular distancia al siguiente punto
      final distance = _distance.as(LengthUnit.Meter, currentPoint, nextPoint);

      // Detectar obstáculos usando datos de OSM si están disponibles
      ObstacleType? obstacle;
      if (knownObstacles != null && knownObstacles.isNotEmpty) {
        if (i < knownObstacles.length) {
          obstacle = knownObstacles[i];
        }
      }

      instructions.add(
        NavigationInstruction(
          point: currentPoint,
          direction: direction,
          distanceToNext: distance,
          streetName: _getStreetName(i), // Placeholder
          obstacle: obstacle,
        ),
      );
    }

    // Agregar instrucción final
    instructions.add(
      NavigationInstruction(
        point: routePath.last,
        direction: TurnDirection.straight,
        distanceToNext: 0,
        description: 'Has llegado a tu destino',
      ),
    );

    return instructions;
  }

  TurnDirection _calculateTurnDirection(
    LatLng previous,
    LatLng current,
    LatLng next,
  ) {
    // Calcular ángulo de giro usando bearing
    final bearing1 = _distance.bearing(previous, current);
    final bearing2 = _distance.bearing(current, next);

    var angle = bearing2 - bearing1;

    // Normalizar a -180 a 180
    while (angle > 180) {
      angle -= 360;
    }
    while (angle < -180) {
      angle += 360;
    }

    // Clasificar giro según ángulo
    if (angle.abs() < 20) {
      return TurnDirection.straight;
    } else if (angle < -150) {
      return TurnDirection.uTurn;
    } else if (angle < -80) {
      return TurnDirection.sharpLeft;
    } else if (angle < -20) {
      return TurnDirection.left;
    } else if (angle < 0) {
      return TurnDirection.slightLeft;
    } else if (angle > 150) {
      return TurnDirection.uTurn;
    } else if (angle > 80) {
      return TurnDirection.sharpRight;
    } else if (angle > 20) {
      return TurnDirection.right;
    } else {
      return TurnDirection.slightRight;
    }
  }

  /// Obtiene el nombre de la calle desde datos de OSM
  /// Si no hay datos disponibles, retorna descripción genérica
  String _getStreetName(int index) {
    // TODO: Integrar con API de OSM/Overpass para obtener nombres reales
    return 'Calle ${index + 1}';
  }
}
