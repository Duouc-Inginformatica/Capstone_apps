import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'package:speech_to_text/speech_to_text.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../services/device/tts_service.dart';
import '../services/device/npu_detector_service.dart';
import '../services/backend/api_client.dart';
import '../services/backend/address_validation_service.dart';
import '../services/navigation/route_tracking_service.dart';
import '../services/navigation/transit_boarding_service.dart';
import '../services/navigation/integrated_navigation_service.dart';
import '../services/backend/geometry_service.dart';
import '../widgets/map/accessible_notification.dart';
import 'settings_screen.dart';
import '../widgets/bottom_nav.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  static const routeName = '/map';

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  void _log(String message, {Object? error, StackTrace? stackTrace}) {
    // Imprimir en consola para que sea visible en modo debug
    debugPrint('[MapScreen] $message');
    
    // También usar developer.log para análisis detallado
    developer.log(
      message,
      name: 'MapScreen',
      error: error,
      stackTrace: stackTrace,
    );
    
    if (error != null) {
      debugPrint('[MapScreen] ERROR: $error');
    }
    if (stackTrace != null) {
      debugPrint('[MapScreen] STACK: $stackTrace');
    }
  }

  bool _isListening = false;
  String _lastWords = '';
  final SpeechToText _speech = SpeechToText();
  bool _speechEnabled = false;
  Timer? _resultDebounce;
  String _pendingWords = '';
  String? _pendingDestination;

  // Mejoras de reconocimiento de voz
  double _speechConfidence = 0.0;
  String _currentRecognizedText = '';
  bool _isProcessingCommand = false;
  Timer? _speechTimeoutTimer;
  final List<String> _recognitionHistory = [];
  static const Duration _speechTimeout = Duration(seconds: 5);

  // Sistema de orientación para personas no videntes
  double? _currentHeading; // Dirección de la brújula (0-360°)
  String _currentDirection = 'Norte'; // Norte, Sur, Este, Oeste, etc.
  DateTime? _lastOrientationAnnouncement;
  
  // Control de volumen para activar micrófono
  int _volumeUpPressCount = 0;
  DateTime? _lastVolumeUpPress;
  Timer? _volumeResetTimer;

  // Trip state - solo mostrar información adicional cuando hay viaje activo
  bool _hasActiveTrip = false;

  // CAP-9: Confirmación de destino
  String? _pendingConfirmationDestination;
  Timer? _confirmationTimer;

  // CAP-12: Instrucciones de ruta
  List<String> _currentInstructions = [];
  int _currentInstructionStep = 0;
  int _instructionFocusIndex = 0;
  final bool _isCalculatingRoute = false;
  bool _showInstructionsPanel = false;

  // Lectura automática de instrucciones
  bool _autoReadInstructions = true; // Por defecto ON para no videntes

  // CAP-29: Confirmación de micro abordada
  bool _waitingBoardingConfirmation = false;

  // CAP-20 & CAP-30: Seguimiento en tiempo real
  bool _isTrackingRoute = false;

  // Simulación de caminata (modo debug)
  bool _isSimulatingWalk = false;
  Timer? _simulationTimer;
  double _simulationProgress = 0.0; // 0.0 a 1.0
  int _simulationStepIndex = 0;

  // Orientación del dispositivo (giroscopio/brújula)
  double _deviceHeading = 0.0; // 0-360 grados
  bool _useDeviceOrientation = true;
  StreamSubscription? _headingSubscription;

  // Gestos de volumen
  DateTime? _lastVolumeUpTime;
  int _volumeUpCount = 0;
  Timer? _volumeGestureTimer;

  // Detección NPU para badge IA
  bool _npuDetected = false;

  // Accessibility features
  Timer? _feedbackTimer;

  // Auto-center durante navegación
  bool _autoCenter = true; // Por defecto activado
  bool _userManuallyMoved = false; // Detecta si el usuario movió el mapa

  // Control de visualización de ruta de bus
  bool _busRouteShown =
      false; // Rastrea si ya se mostró la ruta del bus en wait_bus

  // Notification system
  final List<NotificationData> _activeNotifications = [];
  final int _maxNotifications = 3;
  final List<String> _messageHistory = [];

  // Map and location services
  final MapController _mapController = MapController();
  bool _isMapReady = false;
  double? _pendingRotation;
  LatLng? _pendingCenter;
  double? _pendingZoom;
  Position? _currentPosition;
  List<Marker> _markers = [];
  List<Polyline> _polylines = [];

  // Default location (Santiago, Chile)
  static const LatLng _initialPosition = LatLng(-33.4489, -70.6693);

  double _overlayBaseOffset(BuildContext context, {double min = 240}) {
    final media = MediaQuery.of(context);
    final double estimate = media.size.height * 0.28 + media.padding.bottom;
    return math.max(estimate, min);
  }

  double _overlayGap(BuildContext context) {
    final media = MediaQuery.of(context);
    return math.max(media.size.height * 0.035, 28);
  }

  @override
  void initState() {
    super.initState();
    unawaited(TtsService.instance.setActiveContext('map_navigation'));
    _detectNPU(); // Detectar NPU para badge IA
    // Usar post-frame callback para evitar bloquear la construcción del widget
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initServices();
      _setupTrackingCallbacks();
      _setupBoardingCallbacks();
      _setupOrientationTracking(); // Sistema de orientación
      _setupVolumeButtonListener(); // Listener de botón de volumen
    });
  }

  /// Detectar NPU/NNAPI para mostrar badge IA
  Future<void> _detectNPU() async {
    try {
      final capabilities = await NpuDetectorService.instance.detectCapabilities();
      if (!mounted) return;
      
      setState(() {
        _npuDetected = capabilities.hasNnapi;
      });
      
      _log('🤖 [NPU] Detección completada: ${_npuDetected ? "Disponible" : "No disponible"}');
    } catch (e) {
      _log('⚠️ [NPU] Error detectando: $e');
      setState(() {
        _npuDetected = false;
      });
    }
  }

  /// Sistema de orientación con brújula real (flutter_compass) + GPS
  void _setupOrientationTracking() {
    // 1. Escuchar brújula para orientación precisa
    _headingSubscription = FlutterCompass.events?.listen((CompassEvent event) {
      if (!mounted) return;
      
      final heading = event.heading;
      if (heading == null || heading < 0) return;

      setState(() {
        _deviceHeading = heading;
        _currentDirection = _getDirectionFromHeading(heading);
      });

      // Rotar mapa según orientación si está habilitado
      if (_useDeviceOrientation && _hasActiveTrip) {
        _mapController.rotate(-heading); // Negativo para que el norte quede arriba
      }

      _log('🧭 [COMPASS] Heading: ${heading.toStringAsFixed(1)}° - $_currentDirection');
    });

    // 2. Escuchar GPS para posición y velocidad
    // IMPORTANTE: Solo procesar GPS si NO hay simulación activa
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 2, // Actualizar cada 2 metros
      ),
    ).listen((Position position) {
      if (!mounted) return;
      
      // DESHABILITAR GPS durante simulación
      if (_isSimulatingWalk) {
        _log('🚫 [GPS] Ignorando GPS real - simulación activa');
        return;
      }

      setState(() {
        _currentPosition = position;
      });

      // Validar llegada a puntos de navegación
      _checkArrivalAtWaypoint(position);
      
      _updateCurrentLocationMarker();
    });
  }

  /// Validar llegada a puntos de navegación con GPS real o simulado
  /// Detecta si la persona llegó al destino o punto intermedio
  void _checkArrivalAtWaypoint(Position position) {
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    if (activeNav == null) return;

    final currentStep = activeNav.currentStep;
    if (currentStep == null || currentStep.location == null) return;

    // Calcular distancia al punto objetivo
    final distanceToTarget = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      currentStep.location!.latitude,
      currentStep.location!.longitude,
    );

    // Umbral de llegada: 15 metros
    const arrivalThreshold = 15.0;

    if (distanceToTarget <= arrivalThreshold) {
      _log('✅ [ARRIVAL] Llegada detectada - Distancia: ${distanceToTarget.toStringAsFixed(1)}m');
      _handleWaypointArrival(currentStep, activeNav);
    } else {
      // Generar instrucciones contextuales según distancia y dirección
      _provideContextualGuidance(position, currentStep, distanceToTarget);
    }
  }

  /// Manejar llegada a un punto de navegación
  void _handleWaypointArrival(NavigationStep step, ActiveNavigation nav) {
    Vibration.vibrate(duration: 300, amplitude: 255);

    if (step.type == 'walk') {
      // Llegó al paradero - Buscar el siguiente paso para anunciar el bus
      final nextStepIndex = nav.currentStepIndex + 1;
      String busRoute = '';
      
      if (nextStepIndex < nav.steps.length) {
        final nextStep = nav.steps[nextStepIndex];
        if (nextStep.type == 'wait_bus' || nextStep.type == 'ride_bus') {
          busRoute = nextStep.busRoute ?? '';
        }
      }
      
      if (busRoute.isNotEmpty) {
        TtsService.instance.speak(
          'Has llegado al paradero. Toma el bus $busRoute. Confirma cuando hayas subido al bus.'
        );
        _log('🚏 [PARADERO] Llegada al paradero - Esperar bus: $busRoute');
      } else {
        TtsService.instance.speak('Has llegado al paradero');
        _log('🚏 [PARADERO] Llegada al paradero');
      }
      
      // Avanzar al siguiente paso (wait_bus)
      _advanceToNextStep(nav);
    } else if (step.type == 'wait_bus') {
      // Ya está esperando, no hacer nada (espera confirmación manual)
      _log('⏳ [WAIT] Usuario esperando bus');
    } else if (step.type == 'arrival') {
      // Llegó al destino final
      TtsService.instance.speak('¡Felicidades! Has llegado a tu destino');
      Vibration.vibrate(duration: 500, amplitude: 255);
      _log('🎉 [DESTINATION] Llegada al destino final');
    }
  }

  /// Avanzar al siguiente paso de navegación
  void _advanceToNextStep(ActiveNavigation nav) {
    if (nav.currentStepIndex < nav.steps.length - 1) {
      setState(() {
        nav.currentStepIndex++;
      });
      
      final nextStep = nav.currentStep;
      if (nextStep != null) {
        TtsService.instance.speak(nextStep.instruction);
        _updateNavigationMarkers(nextStep, nav);
        
        // CRÍTICO: Actualizar geometría del mapa al nuevo paso
        if (IntegratedNavigationService.instance.onGeometryUpdated != null) {
          IntegratedNavigationService.instance.onGeometryUpdated!();
        }
        
        _log('➡️ [NAV] Avanzado al paso ${nav.currentStepIndex + 1}: ${nextStep.instruction}');
      }
    }
  }

  /// Proporcionar guía contextual según posición y orientación
  /// "Camina hacia X", "Gira a la derecha", "Sigue recto"
  void _provideContextualGuidance(Position position, NavigationStep step, double distance) {
    // Solo anunciar si han pasado más de 10 segundos desde el último anuncio
    if (_lastOrientationAnnouncement != null &&
        DateTime.now().difference(_lastOrientationAnnouncement!) < const Duration(seconds: 10)) {
      return;
    }

    if (step.location == null) return;

    // Calcular bearing (dirección) hacia el objetivo
    final bearingToTarget = Geolocator.bearingBetween(
      position.latitude,
      position.longitude,
      step.location!.latitude,
      step.location!.longitude,
    );

    // Calcular diferencia angular entre heading actual y dirección al objetivo
    final headingDifference = _normalizeAngle(bearingToTarget - _deviceHeading);

    // Generar instrucción contextual
    String instruction = '';

    if (distance > 100) {
      // Lejos del objetivo
      instruction = 'Continúa ${_getRelativeDirection(headingDifference)}. Faltan ${distance.toInt()} metros';
    } else if (distance > 50) {
      // Cerca del objetivo
      instruction = 'Estás cerca. ${_getRelativeDirection(headingDifference)}. Faltan ${distance.toInt()} metros';
    } else {
      // Muy cerca
      instruction = 'Casi llegas. ${_getRelativeDirection(headingDifference)}. ${distance.toInt()} metros';
    }

    TtsService.instance.speak(instruction);
    Vibration.vibrate(duration: 50);
    _lastOrientationAnnouncement = DateTime.now();
    _log('🧭 [GUIDANCE] $instruction (bearing: ${bearingToTarget.toStringAsFixed(1)}°, diff: ${headingDifference.toStringAsFixed(1)}°)');
  }

  /// Obtener dirección relativa (adelante, derecha, izquierda, atrás)
  String _getRelativeDirection(double angleDifference) {
    final absAngle = angleDifference.abs();

    if (absAngle < 30) {
      return 'sigue recto';
    } else if (absAngle < 80) {
      return angleDifference > 0 ? 'gira ligeramente a la derecha' : 'gira ligeramente a la izquierda';
    } else if (absAngle < 100) {
      return angleDifference > 0 ? 'gira a la derecha' : 'gira a la izquierda';
    } else if (absAngle < 150) {
      return angleDifference > 0 ? 'gira fuertemente a la derecha' : 'gira fuertemente a la izquierda';
    } else {
      return 'da la vuelta';
    }
  }

  /// Normalizar ángulo a rango -180 a 180
  double _normalizeAngle(double angle) {
    while (angle > 180) angle -= 360;
    while (angle < -180) angle += 360;
    return angle;
  }

  /// Convierte grados de brújula a dirección cardinal en español
  String _getDirectionFromHeading(double heading) {
    // Normalizar heading a 0-360
    final normalized = heading % 360;

    // Determinar dirección cardinal (8 puntos)
    if (normalized >= 337.5 || normalized < 22.5) return 'Norte';
    if (normalized >= 22.5 && normalized < 67.5) return 'Noreste';
    if (normalized >= 67.5 && normalized < 112.5) return 'Este';
    if (normalized >= 112.5 && normalized < 157.5) return 'Sureste';
    if (normalized >= 157.5 && normalized < 202.5) return 'Sur';
    if (normalized >= 202.5 && normalized < 247.5) return 'Suroeste';
    if (normalized >= 247.5 && normalized < 292.5) return 'Oeste';
    if (normalized >= 292.5 && normalized < 337.5) return 'Noroeste';

    return 'Norte'; // Fallback
  }

  /// Anuncia la orientación actual por voz
  void _announceCurrentOrientation() {
    if (_currentHeading == null) {
      TtsService.instance.speak('Orientación no disponible');
      return;
    }

    // Evitar anuncios muy frecuentes
    final now = DateTime.now();
    if (_lastOrientationAnnouncement != null &&
        now.difference(_lastOrientationAnnouncement!) < Duration(seconds: 2)) {
      return;
    }

    _lastOrientationAnnouncement = now;

    // Anunciar dirección cardinal
    TtsService.instance.speak(
      'Estás mirando hacia el $_currentDirection',
      priority: TtsPriority.high,
    );

    _log('🧭 [ORIENTACIÓN] $_currentDirection (${_currentHeading!.toStringAsFixed(0)}°)');
  }

  /// Configura el listener para el botón de volumen arriba (doble toque)
  void _setupVolumeButtonListener() {
    // En Android, necesitamos usar HardwareKeyboard y RawKeyEvent
    // Esto detecta cuando se presiona el botón físico de volumen
    
    // NOTA: Flutter no tiene API directa para botones de volumen
    // Necesitamos usar platform channels o un plugin dedicado
    
    // Por ahora, implementar lógica de detección de doble toque
    // que se activará cuando esté disponible el plugin
    
    _log('🔊 [VOLUMEN] Listener configurado - doble toque en volumen arriba para activar micrófono');
  }

  /// Maneja la presión del botón de volumen arriba
  /// Manejo de gestos con botones de volumen
  /// - 1 pulsación: Abrir micrófono
  /// - 2 pulsaciones rápidas (doble tap): Repetir última instrucción de ruta
  void _handleVolumeUpPress() {
    final now = DateTime.now();
    
    // Cancelar timer previo
    _volumeGestureTimer?.cancel();

    // Verificar si es doble pulsación (menos de 500ms entre toques)
    if (_lastVolumeUpTime != null &&
        now.difference(_lastVolumeUpTime!) < const Duration(milliseconds: 500)) {
      // DOBLE PULSACIÓN: Repetir última instrucción
      _volumeUpCount = 0;
      _lastVolumeUpTime = null;
      _repeatCurrentInstruction();
      return;
    }

    // Primera pulsación o pulsación simple
    _volumeUpCount = 1;
    _lastVolumeUpTime = now;

    // Esperar 500ms para verificar si hay segunda pulsación
    _volumeGestureTimer = Timer(const Duration(milliseconds: 500), () {
      if (_volumeUpCount == 1) {
        // PULSACIÓN SIMPLE: Abrir micrófono
        _openMicrophoneByVolume();
      }
      _volumeUpCount = 0;
      _lastVolumeUpTime = null;
    });
  }

  /// Abrir micrófono mediante botón de volumen
  void _openMicrophoneByVolume() {
    _log('🔊 [VOLUMEN] Pulsación simple - abriendo micrófono');
    Vibration.vibrate(duration: 100);
    
    if (!_isListening) {
      _startListening();
      TtsService.instance.speak('Micrófono activado');
    } else {
      _stopListening();
      TtsService.instance.speak('Micrófono desactivado');
    }
  }

  /// Repetir última instrucción de navegación
  void _repeatCurrentInstruction() {
    _log('🔊🔊 [VOLUMEN] Doble pulsación - repitiendo instrucción');
    Vibration.vibrate(duration: 200);

    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    if (activeNav == null) {
      TtsService.instance.speak('No hay navegación activa');
      return;
    }

    final currentStep = activeNav.currentStep;
    if (currentStep == null) {
      TtsService.instance.speak('No hay instrucción actual');
      return;
    }

    // Anunciar la instrucción actual con información adicional
    final instruction = currentStep.instruction;
    final remainingTime = activeNav.remainingTimeSeconds;
    
    String announcement = instruction;
    
    if (remainingTime != null && remainingTime > 0) {
      final minutes = (remainingTime / 60).ceil();
      announcement += '. Tiempo restante: $minutes minutos';
    }

    if (activeNav.distanceToNextPoint != null) {
      final distance = activeNav.distanceToNextPoint!;
      if (distance >= 1000) {
        announcement += '. Distancia: ${(distance / 1000).toStringAsFixed(1)} kilómetros';
      } else {
        announcement += '. Distancia: ${distance.toInt()} metros';
      }
    }

    TtsService.instance.speak(announcement);
    _log('📢 Repitiendo: $announcement');
  }

  /// CAP-30 & CAP-20: Configurar callbacks de seguimiento
  void _setupTrackingCallbacks() {
    RouteTrackingService.instance.onPositionUpdate = (position) {
      if (!mounted) return;
      setState(() {
        _currentPosition = position;
      });
      _updateCurrentLocationMarker();
    };

    RouteTrackingService
        .instance
        .onDeviationDetected = (distance, needsRecalc) {
      if (!mounted || !needsRecalc) return;
      // CAP-20: Recalcular ruta automáticamente
      _showWarningNotification('Desviación detectada. Recalculando ruta...');
      _recalculateRoute();
    };

    RouteTrackingService.instance.onDestinationReached = () {
      if (!mounted) return;
      setState(() {
        _hasActiveTrip = false;
        _isTrackingRoute = false;
      });
      _showSuccessNotification('¡Destino alcanzado!', withVibration: true);
    };
  }

  /// CAP-29: Configurar callbacks de abordaje
  void _setupBoardingCallbacks() {
    TransitBoardingService.instance.onBoardingConfirmed = (busRoute) {
      if (!mounted) return;
      setState(() {
        _waitingBoardingConfirmation = false;
      });
      _showSuccessNotification(
        'Abordaje confirmado en bus $busRoute',
        withVibration: true,
      );

      // Iniciar seguimiento si no está activo
      if (!_isTrackingRoute &&
          RouteTrackingService.instance.destination != null) {
        _startRouteTracking();
      }
    };

    TransitBoardingService.instance.onBoardingCancelled = () {
      if (!mounted) return;
      setState(() {
        _waitingBoardingConfirmation = false;
      });
      _showWarningNotification('Confirmación de abordaje cancelada');
    };
  }

  /// Inicia servicios de forma no bloqueante y escalonada para evitar ANR
  void _initServices() {
    // Iniciar reconocimiento de voz inmediatamente, pero no await para no bloquear UI
    _initSpeech().catchError((e, st) {
      _log('Error inicializando Speech: $e', error: e, stackTrace: st);
    });

    // Iniciar ubicación con pequeño retraso para dar tiempo al UI a estabilizarse
    Future.delayed(const Duration(milliseconds: 250), () {
      _initLocation().catchError((e, st) {
        _log('Error inicializando Location: $e', error: e, stackTrace: st);
      });
    });

    // Iniciar brújula un poco después
    Future.delayed(const Duration(milliseconds: 500), () {
      _initCompass().catchError((e, st) {
        _log('Error inicializando Compass: $e', error: e, stackTrace: st);
      });
    });
  }

  Future<void> _initSpeech() async {
    _speechEnabled = await _speech.initialize(
      onError: (errorNotification) {
        if (!mounted) return;
        setState(() {
          _isListening = false;
          _isProcessingCommand = false;
        });
        _speechTimeoutTimer?.cancel();

        String errorMessage = 'Error en reconocimiento de voz';
        if (errorNotification.errorMsg.contains('network')) {
          errorMessage = 'Error de conexión en reconocimiento de voz';
        } else if (errorNotification.errorMsg.contains('permission')) {
          errorMessage = 'Permiso de micrófono requerido';
        }

        _showErrorNotification(errorMessage);
        _triggerVibration();
      },
      onStatus: (status) {
        if (!mounted) return;

        if (status == 'notListening') {
          setState(() {
            _isListening = false;
            _currentRecognizedText = '';
          });
          _speechTimeoutTimer?.cancel();

          if (!_isProcessingCommand) {
            TtsService.instance.speak('Micrófono detenido');
          }
        } else if (status == 'listening') {
          setState(() {
            _isListening = true;
          });
        }
      },
    );
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _initCompass() async {
    // Brújula deshabilitada para mejorar rendimiento
    _log('🧭 Brújula deshabilitada para optimización de rendimiento');
  }

  String _statusMessage() {
    if (_isListening) {
      if (_currentRecognizedText.isNotEmpty) {
        return '"$_currentRecognizedText"';
      }
      return 'Escuchando... Di tu comando';
    }

    // CAP-9: Mostrar pendiente de confirmación
    if (_pendingConfirmationDestination != null) {
      return '¿Ir a $_pendingConfirmationDestination? (Sí/No)';
    }

    // CAP-28: Prioridad máxima - Navegación activa
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    if (activeNav != null && !activeNav.isComplete) {
      final currentStep = activeNav.currentStep;
      if (currentStep != null) {
        // Construir mensaje con estado y tiempo restante
        final statusDesc = activeNav.getStatusDescription();
        final distance = activeNav.distanceToNextPoint;
        final timeRemaining = activeNav.remainingTimeSeconds;

        String message = statusDesc;

        // Agregar distancia si está disponible
        if (distance != null && distance > 10) {
          if (distance < 1000) {
            message += ' - ${distance.round()}m';
          } else {
            message += ' - ${(distance / 1000).toStringAsFixed(1)}km';
          }
        }

        // Agregar tiempo restante si está disponible
        if (timeRemaining != null && timeRemaining > 0) {
          final minutes = (timeRemaining / 60).ceil();
          message += ' (${minutes}min)';
        }

        return message;
      }

      // Navegación activa pero sin paso actual
      return 'Navegando a ${activeNav.destination}';
    }

    // CAP-29: Mostrar estado de monitoreo de abordaje
    if (_waitingBoardingConfirmation) {
      return 'Monitoreando abordaje...';
    }

    // CAP-30: Mostrar seguimiento activo
    if (_isTrackingRoute) {
      return 'Seguimiento en tiempo real activo';
    }

    if (_pendingDestination != null) {
      return 'Destino pendiente: $_pendingDestination';
    }
    if (_lastWords.isNotEmpty) {
      return 'Último: $_lastWords';
    }
    return 'Pulsa para hablar';
  }

  /// Construye el panel de instrucciones detalladas de navegación
  Widget _buildInstructionsPanel() {
    // Panel deshabilitado - ocupa mucho espacio y no se usa en navegación por voz
    return const SizedBox.shrink();
  }
  
  // NOTA: Panel de instrucciones detalladas removido para ahorrar espacio
  // El usuario navega por voz, no necesita ver instrucciones giro por giro

  String _getMicrophonePromptText() {
    final hasNav = IntegratedNavigationService.instance.activeNavigation != null;
    if (hasNav) {
      return 'Navegando...';
    }
    if (_pendingDestination != null) {
      return 'Destino pendiente: $_pendingDestination';
    }
    if (_lastWords.isNotEmpty) {
      return 'Último: $_lastWords';
    }
    return 'Pulsa para hablar';
  }

  Widget _buildNavigationQuickActions(bool hasActiveNavigation) {
    // Widget deshabilitado - navegación por voz no necesita botones
    return const SizedBox.shrink();
  }

  // NOTA: Panel de acciones rápidas removido para UI minimalista
  // La navegación es completamente por voz

  Widget _buildSimulationFab() {
    final String label = _getSimulationButtonLabel();

    return Semantics(
      button: true,
      label: label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: label,
            child: GestureDetector(
              onTap: _simulateArrivalAtStop,
              child: Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [Color(0xFFFF8C42), Color(0xFFFF6B2C)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x66FF8C42),
                      blurRadius: 18,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF9A3412),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActionButton({
    required IconData icon,
    required String label,
    required String description,
    required VoidCallback? onTap,
    bool primary = false,
    double width = 160,
  }) {
    final bool enabled = onTap != null;
    final Gradient enabledGradient = primary
        ? const LinearGradient(
            colors: [Color(0xFF34D399), Color(0xFF059669)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          )
        : const LinearGradient(
            colors: [Color(0xFF1F2937), Color(0xFF111827)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );
    final Gradient disabledGradient = LinearGradient(
      colors: [Colors.grey.shade600, Colors.grey.shade500],
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
    );

    final gradient = enabled ? enabledGradient : disabledGradient;
    final Color shadowColor = primary
        ? const Color(0xFF059669)
        : const Color(0xFF0F172A);

    return Opacity(
      opacity: enabled ? 1.0 : 0.55,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          width: width,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: gradient,
            boxShadow: [
              BoxShadow(
                color: shadowColor.withValues(alpha: enabled ? 0.35 : 0.2),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 22),
              const SizedBox(height: 10),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 12,
                  height: 1.25,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMiniActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    return SizedBox(
      height: 40,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          foregroundColor: const Color(0xFF0F172A),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  // Timer para simular caminata
  Timer? _walkSimulationTimer;

  /// Devuelve el texto del botón de simulación según el paso actual
  String _getSimulationButtonLabel() {
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    if (activeNav == null) return 'TEST';

    final currentStep = activeNav.currentStep;
    if (currentStep == null) return 'TEST';

    switch (currentStep.type) {
      case 'walk':
        return 'Simular caminata';
      case 'wait_bus':
        return _busRouteShown ? 'Subir al bus' : 'Ver ruta del bus';
      case 'ride_bus':
        return 'Simular viaje';
      default:
        return 'Simular';
    }
  }

  /// TEST: Simula caminata al paradero con anuncios TTS de instrucciones
  void _simulateArrivalAtStop() {
    final activeNav = IntegratedNavigationService.instance.activeNavigation;

    if (activeNav == null) {
      TtsService.instance.speak('No hay navegación activa');
      _showWarningNotification(
        'Primero inicia navegación diciendo: ir a Costanera Center',
      );
      return;
    }

    final currentStep = activeNav.steps[activeNav.currentStepIndex];

    if (currentStep.type == 'walk') {
      // Iniciar simulación de caminata
      _startWalkSimulation(currentStep);
    } else if (currentStep.type == 'wait_bus') {
      if (!_busRouteShown) {
        // ⭐ PRIMER CLIC: CREAR Y MOSTRAR RUTA COMPLETA DEL BUS
        _log('🚌 [TEST] Mostrando ruta completa del bus');

        // NO crear visualización automática - solo al llegar al paradero
        // _createBusRouteVisualization(activeNav);

        setState(() {
          _busRouteShown = true;
        });

        // Obtener info del bus
        final busRoute = currentStep.busRoute ?? 'el bus';
        TtsService.instance.speak(
          'Llegarás al paradero del bus $busRoute. Continúa caminando.',
        );

        _showSuccessNotification('Sigue caminando hacia el paradero');
      } else {
        // ⭐ SEGUNDO CLIC: CONFIRMAR SUBIDA AL BUS
        _log('🚌 [CONFIRMAR] Usuario confirma que subió al bus');

        final busRoute = currentStep.busRoute ?? 'el bus';
        TtsService.instance.speak(
          'Confirmado. Has subido al bus $busRoute.',
        );

        // Resetear flag para próxima vez
        setState(() {
          _busRouteShown = false;
        });

        // Avanzar al paso de ride_bus
        Future.delayed(const Duration(seconds: 1), () {
          IntegratedNavigationService.instance.advanceToNextStep();
          
          setState(() {
            // CRÍTICO: Actualizar mapa para dibujar geometría del bus Y paraderos
            _updateNavigationMapState(activeNav);
          });

          // Anunciar inicio del viaje
          Future.delayed(const Duration(seconds: 1), () {
            final nextStep = IntegratedNavigationService.instance.activeNavigation?.currentStep;
            if (nextStep?.type == 'ride_bus') {
              final totalStops = nextStep?.totalStops ?? 0;
              TtsService.instance.speak(
                'Viaje iniciado en bus $busRoute. Pasarás por $totalStops paradas. Presiona el botón para simular.',
              );
            }
          });
        });
      }
    } else if (currentStep.type == 'ride_bus') {
      // Simular viaje en bus pasando por cada parada
      _log('🚌 [TEST] Simulando viaje en bus');

      final busRoute = currentStep.busRoute ?? 'el bus';
      TtsService.instance.speak(
        'Simulando viaje en $busRoute. Pasarás por todas las paradas.',
      );

      // Obtener geometría del paso de bus (coordenadas de paradas)
      final stepGeometry =
          IntegratedNavigationService.instance.currentStepGeometry;

      if (stepGeometry.isEmpty) {
        _log('⚠️ [BUS] No hay geometría de paradas disponible');
        return;
      }

      _log('🚌 [BUS] Simulando viaje por ${stepGeometry.length} paradas');

      // Simular movimiento por cada parada
      unawaited(_simulateBusJourney(stepGeometry, activeNav));
    } else {
      TtsService.instance.speak('Paso actual: ${currentStep.type}');
    }
  }

  /// Simula el viaje en bus pasando por cada parada utilizando el simulador global
  Future<void> _simulateBusJourney(
    List<LatLng> stops,
    ActiveNavigation activeNav,
  ) async {
    // Cancelar simulaciones previas
    _walkSimulationTimer?.cancel();
    _walkSimulationTimer = null;
    // TODO: Simulación de GPS eliminada - usar GPS real del dispositivo

    if (stops.length < 2) {
      _log('⚠️ [BUS_SIM] Ruta insuficiente (${stops.length} puntos)');
      TtsService.instance.speak('No hay ruta de bus disponible para simular');
      return;
    }

    _log('🚌 [BUS_SIM] Modo simulación deshabilitado - usar GPS real');
    
    // TODO(dev): Implementar seguimiento con GPS real del dispositivo
    // La navegación en bus debe usar Geolocator.getPositionStream() 
    // para obtener la ubicación real del usuario, no una simulación.
    
    TtsService.instance.speak('Navegación con GPS real no implementada aún.');
  }

  List<String>? _getActiveWalkInstructions() {
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    final step = activeNav?.currentStep;

    if (step != null &&
        step.type == 'walk' &&
        step.streetInstructions != null &&
        step.streetInstructions!.isNotEmpty) {
      return step.streetInstructions;
    }

    if (_currentInstructions.isNotEmpty) {
      return _currentInstructions;
    }

    return null;
  }

  void _focusOnInstruction(int index, {bool speak = true}) {
    final instructions = _getActiveWalkInstructions();
    if (instructions == null || instructions.isEmpty) {
      TtsService.instance.speak('No hay instrucciones activas');
      return;
    }

    int clampedIndex = index;
    if (clampedIndex < 0) {
      clampedIndex = 0;
    } else if (clampedIndex >= instructions.length) {
      clampedIndex = instructions.length - 1;
    }

    if (!mounted) return;

    setState(() {
      _instructionFocusIndex = clampedIndex;
    });

    if (speak) {
      final instruction = instructions[clampedIndex];
      TtsService.instance.speak('Paso ${clampedIndex + 1}: $instruction');
    }
  }

  void _speakFocusedInstruction() {
    final instructions = _getActiveWalkInstructions();
    if (instructions == null || instructions.isEmpty) {
      TtsService.instance.speak('No hay instrucciones activas');
      return;
    }

    int focusIndex = _instructionFocusIndex;
    if (focusIndex < 0) {
      focusIndex = 0;
    } else if (focusIndex >= instructions.length) {
      focusIndex = instructions.length - 1;
    }

    final instruction = instructions[focusIndex];
    TtsService.instance.speak('Paso ${focusIndex + 1}: $instruction');

    if (!mounted) return;

    setState(() {
      _instructionFocusIndex = focusIndex;
    });
  }

  void _moveInstructionFocus(int delta) {
    final instructions = _getActiveWalkInstructions();
    if (instructions == null || instructions.isEmpty) {
      TtsService.instance.speak('No hay instrucciones activas');
      return;
    }

    int focusIndex = _instructionFocusIndex;
    if (focusIndex < 0) {
      focusIndex = 0;
    } else if (focusIndex >= instructions.length) {
      focusIndex = instructions.length - 1;
    }

    final newIndex = (focusIndex + delta)
        .clamp(0, instructions.length - 1)
        .toInt();

    if (newIndex == focusIndex) {
      TtsService.instance.speak(
        delta > 0
            ? 'Ya estás en la última instrucción'
            : 'Ya estás en la primera instrucción',
      );
      return;
    }

    if (!mounted) return;

    setState(() {
      _instructionFocusIndex = newIndex;
    });

    final instruction = instructions[newIndex];
    TtsService.instance.speak('Paso ${newIndex + 1}: $instruction');
  }

  /// Simula caminata progresiva al paradero con instrucciones de GraphHopper
  void _startWalkSimulation(NavigationStep walkStep) async {
    // Cancelar simulación previa si existe
    _walkSimulationTimer?.cancel();
    // TODO: NavigationSimulator.instance.stop(); // Simulación deshabilitada

    if (walkStep.location == null || _currentPosition == null) {
      TtsService.instance.speak('Error: no se puede simular la caminata');
      return;
    }

    final stepGeometry =
        IntegratedNavigationService.instance.currentStepGeometry;

    if (stepGeometry.isEmpty) {
      _log('⚠️ No hay geometría disponible para simular');
      TtsService.instance.speak('No hay ruta disponible para simular');
      return;
    }

    // Obtener instrucciones detalladas de GraphHopper
    List<Instruction> ghInstructions = [];

    if (walkStep.streetInstructions != null &&
        walkStep.streetInstructions!.isNotEmpty) {
      // Convertir instrucciones textuales a objetos Instruction estructurados
      for (final text in walkStep.streetInstructions!) {
        ghInstructions.add(
          Instruction(
            text: text,
            distanceMeters: walkStep.realDistanceMeters != null
                ? walkStep.realDistanceMeters! /
                      walkStep.streetInstructions!.length
                : 100,
            durationSeconds: walkStep.realDurationSeconds != null
                ? walkStep.realDurationSeconds! ~/
                      walkStep.streetInstructions!.length
                : 30,
          ),
        );
      }
    } else {
      // Si no hay instrucciones detalladas, crear una genérica
      final destinationName = walkStep.stopName ?? "el destino";
      final simplifiedDestination = _simplifyStopNameForTTS(
        destinationName,
        isDestination: true,
      );

      ghInstructions.add(
        Instruction(
          text: 'Continúe hacia $simplifiedDestination',
          distanceMeters: walkStep.realDistanceMeters ?? 100,
          durationSeconds: walkStep.realDurationSeconds ?? 60,
        ),
      );
    }

    if (walkStep.streetInstructions != null &&
        walkStep.streetInstructions!.isNotEmpty) {
      if (mounted) {
        setState(() {
          _instructionFocusIndex = 0;
        });
      }
    }

    _log(
      '🚶 [SIMULATOR] Navegación peatonal con GPS real (no simulación)',
    );

    // TODO(dev): Implementar navegación peatonal con GPS real
    // Debe usar Geolocator.getPositionStream() para seguimiento en tiempo real
    
    TtsService.instance.speak('Comenzando navegación peatonal');
    _showSuccessNotification('Navegación peatonal iniciada - usar GPS real');
    
    return; // Deshabilitado hasta implementar GPS real
  }

  /// Crea y visualiza los paraderos del bus (sin mostrar la línea de ruta)
  void _createBusRouteVisualization(ActiveNavigation navigation) {
    _log('🗺️ [BUS_STOPS] Mostrando paraderos de la ruta del bus...');

    // Buscar el leg del bus en el itinerario original
    final busLeg = navigation.itinerary.legs.firstWhere(
      (leg) => leg.type == 'bus' && leg.isRedBus,
      orElse: () => throw Exception('No se encontró leg de bus'),
    );

    // Obtener la lista de paraderos del leg
    final stops = busLeg.stops;
    if (stops == null || stops.isEmpty) {
      _log('⚠️ [BUS_STOPS] No hay paraderos en el leg del bus');
      return;
    }

    _log('� [BUS_STOPS] ${stops.length} paraderos encontrados');

    // Crear marcadores para cada paradero
    final stopMarkers = <Marker>[];

    for (int i = 0; i < stops.length; i++) {
      final stop = stops[i];
      final isFirst = i == 0;
      final isLast = i == stops.length - 1;

      // FILTRO: Si hay muchas paradas intermedias, solo mostrar algunas clave
      if (!isFirst && !isLast && stops.length > 10) {
        // Mostrar solo paradas en posiciones estratégicas
        final shouldShow = _shouldShowIntermediateStop(i, stops.length);
        if (!shouldShow) {
          continue; // Saltar esta parada (no crear marcador visual)
        }
      }

      // Icono y color según posición
      Color markerColor;
      IconData markerIcon;
      double markerSize;

      if (isFirst) {
        // 🟢 PARADERO DE SUBIDA (verde brillante - punto de inicio del viaje en bus)
        markerColor = const Color(0xFF4CAF50);
        markerIcon = Icons.directions_bus; // Ícono de bus
        markerSize = 48;
      } else if (isLast) {
        // 🔴 PARADERO DE BAJADA (rojo - destino del viaje en bus)
        markerColor = const Color(0xFFE30613);
        markerIcon = Icons.directions_bus; // Ícono de bus
        markerSize = 48;
      } else {
        // 🔵 PARADEROS INTERMEDIOS (azul con ícono de parada)
        markerColor = const Color(0xFF2196F3);
        markerIcon = Icons.bus_alert; // Ícono de parada de bus
        markerSize = 32;
      }

      final marker = Marker(
        point: stop.location,
        width: markerSize + 24,
        height: markerSize + 60,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icono del marcador con diseño mejorado
            Stack(
              alignment: Alignment.center,
              children: [
                // Sombra externa
                Container(
                  width: markerSize + 4,
                  height: markerSize + 4,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                ),
                // Contenedor principal
                Container(
                  width: markerSize,
                  height: markerSize,
                  decoration: BoxDecoration(
                    color: markerColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                      BoxShadow(
                        color: markerColor.withValues(alpha: 0.6),
                        blurRadius: 16,
                        spreadRadius: 3,
                      ),
                    ],
                  ),
                  child: Icon(
                    markerIcon,
                    color: Colors.white,
                    size: markerSize * 0.55,
                  ),
                ),
              ],
            ),
            // Etiqueta con código/nombre de parada (MÁS VISIBLE)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.90),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: markerColor.withValues(alpha: 0.5),
                  width: 1.5,
                ),
              ),
              child: Text(
                stop.code ?? 'P$i',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ),
      );

      stopMarkers.add(marker);
    }

    // Actualizar marcadores en el mapa (NO agregar polyline)
    setState(() {
      _markers = [..._markers, ...stopMarkers];
    });

    // Ajustar zoom para mostrar todos los paraderos
    final allStopLocations = stops.map((s) => s.location).toList();
    _fitBoundsToRoute(allStopLocations);

    _log(
      '✅ [BUS_STOPS] ${stopMarkers.length} marcadores visibles de ${stops.length} paradas totales',
    );
    _showSuccessNotification(
      '${stopMarkers.length} paraderos mostrados de ${stops.length} en ruta ${busLeg.routeNumber ?? ""}',
    );
  }

  /// Determina si una parada intermedia debe mostrarse visualmente
  /// Cuando hay más de 10 paradas, solo muestra algunas estratégicas
  /// para evitar saturación visual en el mapa
  bool _shouldShowIntermediateStop(int index, int totalStops) {
    // Siempre mostrar si hay pocas paradas
    if (totalStops <= 10) return true;

    // Para más de 10 paradas, mostrar solo ~6-8 marcadores intermedios
    // Primeras 2 (índices 1, 2)
    if (index <= 2) return true;

    // Últimas 2 (antes de la última que ya se muestra)
    if (index >= totalStops - 3) return true;

    // Algunas intermedias estratégicas
    final quarter = (totalStops / 4).round();
    final half = (totalStops / 2).round();
    final threeQuarters = ((totalStops * 3) / 4).round();

    if (index == quarter || index == half || index == threeQuarters) {
      return true;
    }

    return false; // Ocultar el resto
  }

  /// Ajusta el zoom del mapa para mostrar toda la ruta proporcionada
  void _fitBoundsToRoute(List<LatLng> routePoints) {
    if (routePoints.isEmpty || !_isMapReady) return;

    // Calcular límites de la ruta
    double minLat = routePoints.first.latitude;
    double maxLat = routePoints.first.latitude;
    double minLng = routePoints.first.longitude;
    double maxLng = routePoints.first.longitude;

    for (final point in routePoints) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }

    // Calcular centro
    final centerLat = (minLat + maxLat) / 2;
    final centerLng = (minLng + maxLng) / 2;
    final center = LatLng(centerLat, centerLng);

    // Calcular zoom apropiado basado en la extensión
    final latDiff = maxLat - minLat;
    final lngDiff = maxLng - minLng;
    final maxDiff = math.max(latDiff, lngDiff);

    // Estimación simple de zoom (puede necesitar ajuste)
    double zoom = 14.0;
    if (maxDiff > 0.1) {
      zoom = 11.0;
    } else if (maxDiff > 0.05) {
      zoom = 12.0;
    } else if (maxDiff > 0.02) {
      zoom = 13.0;
    }

    _log('🗺️ [FIT_BOUNDS] Centro: $center, Zoom: $zoom, Extensión: $maxDiff');

    _moveMap(center, zoom);
  }

  void _centerOnUserLocation() {
    if (_currentPosition == null) {
      return;
    }

    final target = LatLng(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
    );

    _moveMap(target, 14.0);
    _showNavigationNotification('Centrando mapa en tu ubicación');

    // Reactivar auto-centrado cuando el usuario presiona el botón
    setState(() {
      _autoCenter = true;
      _userManuallyMoved = false;
    });
  }

  void _moveMap(LatLng target, double zoom) {
    if (_isMapReady) {
      _mapController.move(target, zoom);
    } else {
      _pendingCenter = target;
      _pendingZoom = zoom;
    }
  }

  void _triggerVibration() async {
    try {
      bool? hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator == true) {
        Vibration.vibrate(duration: 200);
      }
    } catch (e) {
      // Vibración no soportada
    }
  }

  // Sobrescribir método para guardar último anuncio
  Future<void> _initLocation() async {
    try {
      // Check location permissions
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever) {
        _showLocationPermissionDialog();
        return;
      }

      if (permission == LocationPermission.denied) {
        return;
      }

      // Get current location
      _currentPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      if (!mounted) return;

      // Solo mostrar ubicación actual inicialmente (no cargar paradas automáticamente)
      _updateCurrentLocationMarker();

      // Move camera to current location if map is ready
      if (_currentPosition != null) {
        _moveMap(
          LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
          14.0,
        );
      }
    } catch (e) {
      if (!mounted) return;
      TtsService.instance.speak('Error obteniendo ubicación');
    }
  }

  void _updateCurrentLocationMarker() {
    if (_currentPosition == null || !mounted) return;

    final currentMarker = Marker(
      point: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
      width: 56,
      height: 56,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Pulso animado de fondo
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.blue.withValues(alpha: 0.2),
            ),
          ),
          // Círculo principal con icono "Tú estás aquí"
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.blue.shade700,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
                BoxShadow(
                  color: Colors.blue.withValues(alpha: 0.5),
                  blurRadius: 16,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: const Icon(
              Icons.person_pin_circle_rounded, // Icono de persona con pin
              color: Colors.white,
              size: 28,
            ),
          ),
        ],
      ),
    );

    setState(() {
      _markers = [currentMarker]; // Solo mostrar ubicación actual
    });
  }

  void _showLocationPermissionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permisos de ubicación'),
        content: const Text(
          'La aplicación necesita acceso a tu ubicación para mostrar paradas de transporte cercanas.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Geolocator.openAppSettings();
            },
            child: const Text('Configuración'),
          ),
        ],
      ),
    );
  }

  void _startListening() async {
    // IMPORTANTE: Detener TTS antes de habilitar el micrófono
    await TtsService.instance.stop();

    // Verificar permisos de micrófono
    var status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      _showPermissionDialog();
      TtsService.instance.speak('Permiso de micrófono denegado');
      return;
    }

    // Configurar timeout personalizado
    _speechTimeoutTimer?.cancel();
    _speechTimeoutTimer = Timer(_speechTimeout, () {
      if (_isListening) {
        _speech.stop();
        _showWarningNotification('Tiempo de escucha agotado');
      }
    });

    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;

        // Actualizar texto y confianza en tiempo real
        setState(() {
          _currentRecognizedText = result.recognizedWords;
          _speechConfidence = result.confidence;
        });

        // Procesar solo si hay alta confianza y texto final
        if (result.finalResult) {
          _speechTimeoutTimer?.cancel();
          _processRecognizedText(result.recognizedWords, result.confidence);
        } else {
          // Debounce para resultados parciales
          _pendingWords = result.recognizedWords;
          if (_resultDebounce?.isActive ?? false) _resultDebounce?.cancel();
          _resultDebounce = Timer(const Duration(milliseconds: 300), () {
            if (!mounted) return;
            setState(() {
              _lastWords = _pendingWords;
            });
          });
        }
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 2), // Reducido para mayor responsividad
      localeId: 'es_ES', // Español de España (mejor reconocimiento)
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.confirmation,
        sampleRate: 16000, // Frecuencia optimizada para voz
        enableHapticFeedback: true, // Vibración al reconocer
      ),
    );
    if (!mounted) return;
    setState(() {
      _isListening = true;
    });
    TtsService.instance.speak('Escuchando');
  }

  void _stopListening() async {
    await _speech.stop();
    if (!mounted) return;
    setState(() {
      _isListening = false;
    });

    // Procesar el comando de voz
    if (_lastWords.isNotEmpty) {
      _processVoiceCommand(_lastWords);
    }
  }

  void _processVoiceCommand(String command) {
    if (!mounted) return;
    final normalized = command.toLowerCase().trim();
    if (normalized.isEmpty) return;

    if (_handleNavigationCommand(normalized)) {
      setState(() {
        _lastWords = command;
        _pendingDestination = null;
      });
      return;
    }

    final destination = _extractDestination(normalized);
    if (destination != null) {
      final pretty = _toTitleCase(destination);
      setState(() {
        _pendingDestination = pretty;
        _lastWords = command;
      });

      // CAP-9: Solicitar confirmación antes de buscar ruta
      _requestDestinationConfirmation(destination);
      return;
    }

    setState(() {
      _pendingDestination = null;
      _lastWords = command;
    });
    _announce('Comando "$command" aún no está soportado');
    TtsService.instance.speak('Ese comando no está disponible.');
  }

  /// Modo DEBUG: Simular caminata realista para demostración
  void _toggleSimulation() {
    if (_isSimulatingWalk) {
      // Detener simulación
      _simulationTimer?.cancel();
      _simulationTimer = null;
      setState(() {
        _isSimulatingWalk = false;
        _simulationProgress = 0.0;
        _simulationStepIndex = 0;
      });
      TtsService.instance.speak('Simulación detenida');
      Vibration.vibrate(duration: 100);
      _log('🛑 Simulación de caminata detenida');
      return;
    }

    // Iniciar simulación
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    if (activeNav == null) {
      TtsService.instance.speak('No hay navegación activa para simular');
      return;
    }

    final currentStep = activeNav.currentStep;
    if (currentStep == null) {
      TtsService.instance.speak('No hay paso activo para simular');
      return;
    }

    // Obtener geometría del paso actual
    final stepGeometry = IntegratedNavigationService.instance.currentStepGeometry;
    if (stepGeometry.isEmpty) {
      TtsService.instance.speak('No hay ruta para simular');
      return;
    }

    setState(() {
      _isSimulatingWalk = true;
      _simulationProgress = 0.0;
      _simulationStepIndex = 0;
    });

    TtsService.instance.speak('Iniciando simulación de caminata. La posición se actualizará automáticamente.');
    Vibration.vibrate(duration: 150);
    _log('▶️ Simulación de caminata iniciada - ${stepGeometry.length} puntos en ruta');

    // Simulación REALISTA: movimiento cada 1 segundo con interpolación suave
    _simulationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_isSimulatingWalk || !mounted) {
        timer.cancel();
        setState(() {
          _isSimulatingWalk = false;
        });
        return;
      }

      // Avanzar al siguiente punto en la geometría
      _simulationStepIndex++;
      
      if (_simulationStepIndex >= stepGeometry.length) {
        // Llegamos al final del paso
        timer.cancel();
        setState(() {
          _isSimulatingWalk = false;
          _simulationProgress = 1.0;
        });
        
        TtsService.instance.speak('Has llegado al punto de destino');
        Vibration.vibrate(duration: 200, amplitude: 128);
        _log('✅ Simulación completada');
        
        // Avanzar al siguiente paso automáticamente si hay más pasos
        Future.delayed(const Duration(seconds: 1), () {
          if (activeNav.currentStepIndex < activeNav.steps.length - 1) {
            _log('📍 Llegada al punto simulado - avanzando al siguiente paso');
          }
        });
        return;
      }

      // Actualizar posición simulada con interpolación suave
      final nextPoint = stepGeometry[_simulationStepIndex];
      _simulationProgress = _simulationStepIndex / stepGeometry.length;
      
      // Calcular velocidad realista (1-1.5 m/s caminata normal)
      final walkSpeed = 1.2 + (0.3 * (DateTime.now().millisecondsSinceEpoch % 1000) / 1000);
      
      // Calcular bearing hacia el siguiente punto
      double bearing = 0.0;
      if (_currentPosition != null) {
        bearing = Geolocator.bearingBetween(
          _currentPosition!.latitude,
          _currentPosition!.longitude,
          nextPoint.latitude,
          nextPoint.longitude,
        );
      }
      
      if (!mounted) return;
      setState(() {
        _currentPosition = Position(
          latitude: nextPoint.latitude,
          longitude: nextPoint.longitude,
          timestamp: DateTime.now(),
          accuracy: 3.0, // Precisión simulada alta
          altitude: 0.0,
          heading: bearing, // Dirección real hacia siguiente punto
          speed: walkSpeed, // Velocidad variable realista
          speedAccuracy: 0.5,
          altitudeAccuracy: 0.0,
          headingAccuracy: 5.0,
        );
      });

      // AUTO-CENTRAR el mapa durante simulación si está habilitado
      if (_autoCenter && !_userManuallyMoved) {
        _mapController.move(nextPoint, _mapController.camera.zoom);
      }

      // VALIDAR LLEGADA usando el sistema de navegación GPS
      if (_currentPosition != null) {
        _checkArrivalAtWaypoint(_currentPosition!);
      }

      // Anuncio periódico de progreso (cada 25%)
      final progressPercent = (_simulationProgress * 100).toInt();
      if (progressPercent % 25 == 0 && progressPercent > 0 && progressPercent < 100) {
        final remaining = stepGeometry.length - _simulationStepIndex;
        TtsService.instance.speak('Avanzando. $remaining metros restantes');
        Vibration.vibrate(duration: 30);
      }

      _log('� [SIM] Punto $_simulationStepIndex/${stepGeometry.length} - ${progressPercent}% - ${walkSpeed.toStringAsFixed(1)} m/s');
    });
  }

  bool _handleNavigationCommand(String command) {
    // ============================================================================
    // COMANDOS DE VOZ SIMPLIFICADOS
    // ============================================================================
    // 1. "ir a [destino]" - Iniciar navegación a un destino
    // 2. "cancelar ruta" - Cancelar navegación activa
    // ============================================================================

    // CONFIRMACIÓN: Sí (después de "ir a X")
    if (command.contains('sí') || command.contains('si')) {
      if (_pendingConfirmationDestination != null) {
        _confirmDestination();
        return true;
      }
    }

    // CONFIRMACIÓN: No (cancelar "ir a X")
    if (command.contains('no')) {
      if (_pendingConfirmationDestination != null) {
        _cancelDestinationConfirmation();
        return true;
      }
    }

    // CANCELAR RUTA ACTIVA
    if (command.contains('cancelar')) {
      if (IntegratedNavigationService.instance.hasActiveNavigation) {
        IntegratedNavigationService.instance.stopNavigation();
        setState(() {
          _polylines.clear();
          _currentInstructions.clear();
          _showInstructionsPanel = false;
        });
        TtsService.instance.speak('Ruta cancelada', urgent: true);
        return true;
      } else {
        TtsService.instance.speak('No hay ruta activa');
        return true;
      }
    }

    // COMANDO: Orientación / ¿Hacia dónde miro?
    if (command.contains('orientación') ||
        command.contains('hacia donde') ||
        command.contains('hacia dónde') ||
        command.contains('donde miro') ||
        command.contains('dónde miro') ||
        command.contains('qué dirección') ||
        command.contains('brújula')) {
      _announceCurrentOrientation();
      return true;
    }

    // CONFIRMACIÓN de abordaje (durante navegación activa)
    if (_waitingBoardingConfirmation) {
      TransitBoardingService.instance.confirmBoardingManually(command);
      return true;
    }

    return false;
  }

  String? _extractDestination(String command) {
    // PATRÓN SIMPLIFICADO: Solo "ir a [destino]"
    final pattern = r'ir\s+a(?:l)?\s+(.+)';

    final match = RegExp(pattern, caseSensitive: false).firstMatch(command);
    if (match != null) {
      final destination = match.group(1)?.trim();
      if (destination != null && destination.isNotEmpty) {
        // Limpiar palabras innecesarias
        String cleaned = destination
            .replaceAll(
              RegExp(
                r'\s+(por\s+favor|porfavor|gracias)$',
                caseSensitive: false,
              ),
              '',
            )
            .trim();

        if (cleaned.isNotEmpty) {
          return cleaned;
        }
      }
    }

    return null;
  }

  /// CAP-9: Solicitar confirmación del destino reconocido
  void _requestDestinationConfirmation(String destination) {
    setState(() {
      _pendingConfirmationDestination = destination;
    });

    _confirmationTimer?.cancel();
    _confirmationTimer = Timer(const Duration(seconds: 15), () {
      if (_pendingConfirmationDestination != null) {
        _cancelDestinationConfirmation();
      }
    });

    final pretty = _toTitleCase(destination);
    TtsService.instance.speak(
      'Entendí que quieres ir a $pretty. ¿Es correcto? '
      'Di sí para confirmar o no para cancelar.',
    );

    _showNotification(
      NotificationData(
        message: 'Confirma destino: $pretty',
        type: NotificationType.warning,
        duration: const Duration(seconds: 15),
      ),
    );
  }

  /// CAP-9: Confirmar destino y buscar ruta
  void _confirmDestination() {
    if (_pendingConfirmationDestination == null) return;

    final destination = _pendingConfirmationDestination!;
    _confirmationTimer?.cancel();

    setState(() {
      _pendingDestination = null;
      _pendingConfirmationDestination = null;
    });

    _showSuccessNotification('Destino confirmado', withVibration: true);
    TtsService.instance.speak('Perfecto, buscando ruta a $destination');

    _searchRouteToDestination(destination);
  }

  /// CAP-9: Cancelar confirmación de destino
  void _cancelDestinationConfirmation() {
    _confirmationTimer?.cancel();

    setState(() {
      _pendingConfirmationDestination = null;
      _pendingDestination = null;
    });

    TtsService.instance.speak(
      'Destino cancelado. Puedes decir un nuevo destino cuando quieras.',
    );

    _showWarningNotification('Confirmación cancelada');
  }

  /// CAP-12: Leer siguiente instrucción
  void _readNextInstruction() {
    if (_currentInstructions.isEmpty) {
      TtsService.instance.speak('No hay instrucciones disponibles');
      return;
    }

    if (_currentInstructionStep >= _currentInstructions.length) {
      TtsService.instance.speak('Has completado todas las instrucciones');
      return;
    }

    final currentIndex = _currentInstructionStep;
    final instruction = _currentInstructions[currentIndex];
    _focusOnInstruction(currentIndex, speak: false);
    TtsService.instance.speak('Paso ${currentIndex + 1}: $instruction');
    setState(() {
      _currentInstructionStep++;
    });
  }

  /// CAP-12: Repetir instrucción actual
  /// CAP-30: Iniciar seguimiento en tiempo real
  void _startRouteTracking() {
    if (_polylines.isEmpty ||
        RouteTrackingService.instance.destination == null) {
      TtsService.instance.speak('No hay una ruta activa para seguir');
      return;
    }

    setState(() {
      _isTrackingRoute = true;
    });

    final destination = RouteTrackingService.instance.destination!;
    final destinationName =
        RouteTrackingService.instance.destinationName ?? 'destino';

    // Extraer puntos de la ruta
    final routePoints = _polylines.isNotEmpty
        ? _polylines.first.points
        : <LatLng>[];

    RouteTrackingService.instance.startTracking(
      plannedRoute: routePoints,
      destination: destination,
      destinationName: destinationName,
    );

    _showSuccessNotification(
      'Seguimiento en tiempo real activado',
      withVibration: true,
    );
  }

  /// CAP-20: Recalcular ruta desde posición actual
  Future<void> _recalculateRoute() async {
    if (_currentPosition == null ||
        RouteTrackingService.instance.destination == null) {
      return;
    }

    final dest = RouteTrackingService.instance.destination!;
    final destName = RouteTrackingService.instance.destinationName ?? 'destino';

    TtsService.instance.speak('Recalculando ruta a $destName');

    try {
      await _calculateRoute(
        destLat: dest.latitude,
        destLon: dest.longitude,
        destName: destName,
      );

      _showSuccessNotification('Ruta recalculada exitosamente');

      // Reiniciar seguimiento con nueva ruta
      if (_isTrackingRoute) {
        _startRouteTracking();
      }
    } catch (e) {
      _showErrorNotification('Error recalculando ruta');
    }
  }

  String _toTitleCase(String input) {
    return input
        .split(' ')
        .map((word) {
          if (word.isEmpty) return word;
          final lower = word.toLowerCase();
          return lower[0].toUpperCase() + lower.substring(1);
        })
        .join(' ');
  }

  void _announce(String message) {
    _showNotification(
      NotificationData(message: message, type: NotificationType.info),
    );
  }

  void _showNotification(NotificationData notification) {
    setState(() {
      // Limitar número de notificaciones activas
      if (_activeNotifications.length >= _maxNotifications) {
        _activeNotifications.removeAt(0);
      }
      _activeNotifications.add(notification);

      _messageHistory.add(notification.message);
      if (_messageHistory.length > 1) {
        _messageHistory.removeAt(0);
      }
    });
  }

  void _showSuccessNotification(String message, {bool withVibration = false}) {
    _showNotification(
      NotificationData(
        message: message,
        type: NotificationType.success,
        withVibration: withVibration,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showErrorNotification(String message, {bool withVibration = true}) {
    _showNotification(
      NotificationData(
        message: message,
        type: NotificationType.error,
        withVibration: withVibration,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _showNavigationNotification(String message) {
    _showNotification(
      NotificationData(
        message: message,
        type: NotificationType.navigation,
        icon: Icons.navigation,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showWarningNotification(String message) {
    _showNotification(
      NotificationData(
        message: message,
        type: NotificationType.warning,
        withVibration: true,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _dismissNotification(NotificationData notification) {
    setState(() {
      _activeNotifications.remove(notification);
    });
  }

  // Método para procesar texto reconocido con filtros mejorados
  void _processRecognizedText(String recognizedText, double confidence) {
    if (!mounted || _isProcessingCommand) return;

    // Filtrar confianza mínima
    if (confidence < 0.7) {
      _showWarningNotification(
        'Comando no reconocido con suficiente claridad (${(confidence * 100).toInt()}%)',
      );
      return;
    }

    setState(() {
      _isProcessingCommand = true;
    });

    // Agregar a historial
    _recognitionHistory.add(recognizedText);
    if (_recognitionHistory.length > 10) {
      _recognitionHistory.removeAt(0);
    }

    // Procesar tanto el texto original como normalizado para máxima flexibilidad
    bool commandProcessed = _processVoiceCommandEnhanced(recognizedText);

    // Si no se procesó, intentar con texto normalizado como fallback
    if (!commandProcessed) {
      String normalizedText = _normalizeText(recognizedText);
      commandProcessed = _processVoiceCommandEnhanced(normalizedText);
    }

    if (commandProcessed) {
      _showSuccessNotification(
        'Comando ejecutado: "$recognizedText" (${(confidence * 100).toInt()}%)',
        withVibration: true,
      );
    } else {
      _showWarningNotification(
        'Comando no reconocido: "$recognizedText". Di "ayuda" para ver ejemplos.',
      );
    }

    setState(() {
      _isProcessingCommand = false;
      _lastWords = recognizedText;
    });
  }

  // Método simplificado para normalizar texto
  String _normalizeText(String text) {
    String normalized = text.toLowerCase().trim();

    // Remover acentos
    normalized = normalized
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ü', 'u')
        .replaceAll('ñ', 'n');

    // Limpiar palabras innecesarias
    normalized = normalized
        .replaceAll(RegExp(r'\s+(por favor|porfavor|gracias)\s*'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return normalized;
  }

  // Versión mejorada del procesador de comandos que retorna bool
  bool _processVoiceCommandEnhanced(String command) {
    if (!mounted) return false;
    final normalized = command.toLowerCase().trim();
    if (normalized.isEmpty) return false;

    // Primero probar comandos de navegación específicos (ayuda, orientación, etc.)
    if (_handleNavigationCommand(normalized)) {
      setState(() {
        _lastWords = command;
        _pendingDestination = null;
      });
      return true;
    }

    // 🚌 Comando para navegación integrada con Moovit (buses Red)
    if (normalized.contains('navegación red') ||
        normalized.contains('ruta red') ||
        normalized.contains('bus red')) {
      final destination = _extractDestination(command);
      if (destination != null && destination.isNotEmpty) {
        final pretty = _toTitleCase(destination);
        setState(() {
          _pendingDestination = pretty;
          _lastWords = command;
        });

        // Llamar a navegación integrada con Moovit en vez de ruta normal
        _onIntegratedNavigationVoiceCommand(command);
        return true;
      }
    }

    // Intentar extraer destino del comando original (sin normalizar demasiado)
    final destination = _extractDestination(command);
    if (destination != null && destination.isNotEmpty) {
      final pretty = _toTitleCase(destination);
      setState(() {
        _pendingDestination = pretty;
        _lastWords = command;
      });

      // Feedback más natural
      _showSuccessNotification('Buscando ruta a: $pretty');
      TtsService.instance.speak('Perfecto, buscando la ruta a $pretty');
      _searchRouteToDestination(destination);
      return true;
    }

    // Si contiene palabras clave de navegación pero no se pudo extraer destino
    if (_containsNavigationIntent(normalized)) {
      _showWarningNotification(
        'No pude entender el destino. Intenta decir: "ir a [nombre del lugar]"',
      );
      TtsService.instance.speak(
        'No pude entender el destino. Puedes decir por ejemplo: ir a mall vivo los trapenses',
      );
      return true; // Se reconoció la intención aunque no el destino
    }

    // Si no se reconoce ningún comando específico
    setState(() {
      _pendingDestination = null;
      _lastWords = command;
    });

    return false; // Comando no reconocido
  }

  // Método para detectar si hay intención de navegación
  bool _containsNavigationIntent(String command) {
    final navigationKeywords = [
      'ir',
      'voy',
      'quiero',
      'necesito',
      'tengo que',
      'llevar',
      'dirigir',
      'navegar',
      'buscar',
      'como llego',
      'ruta',
      'camino',
      'mall',
      'centro',
      'universidad',
      'hospital',
      'aeropuerto',
      'estacion',
      'metro',
    ];

    return navigationKeywords.any((keyword) => command.contains(keyword));
  }

  void _searchRouteToDestination(String destination) async {
    _log('🔍 [SEARCH] Iniciando búsqueda de ruta a: $destination');
    
    if (_currentPosition == null) {
      _log('❌ [SEARCH] Sin ubicación GPS');
      _showErrorNotification('No se puede calcular ruta sin ubicación actual');
      TtsService.instance.speak(
        'No se puede calcular ruta sin ubicación actual',
      );
      return;
    }

    _log('📍 [SEARCH] Posición actual: ${_currentPosition!.latitude}, ${_currentPosition!.longitude}');

    // Anunciar que se está calculando
    TtsService.instance.speak(
      'Buscando ruta a $destination. Por favor espera.',
    );

    try {
      _log('🌍 [GEOCODE] Iniciando geocodificación de: $destination');
      
      // 1. Geocodificar destino usando el servicio de validación de direcciones
      final suggestions = await AddressValidationService.instance
          .suggestAddresses(destination, limit: 1);

      _log('🌍 [GEOCODE] Resultados: ${suggestions.length}');

      if (suggestions.isEmpty) {
        _log('❌ [GEOCODE] No se encontró el destino');
        _showErrorNotification('No se encontró el destino: $destination');
        TtsService.instance.speak('No se encontró el destino $destination');
        return;
      }

      final firstResult = suggestions.first;
      final destLat = (firstResult['lat'] as num).toDouble();
      final destLon = (firstResult['lon'] as num).toDouble();
      final destName = firstResult['display_name'] as String? ?? destination;

      _log('✅ [GEOCODE] Destino encontrado: $destName');
      _log('📍 [GEOCODE] Coordenadas: ($destLat, $destLon)');

      // 2. Calcular distancia para decidir tipo de navegación
      final distance = _calculateDistance(
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
        LatLng(destLat, destLon),
      );

      _log('� [DISTANCE] Distancia al destino: ${distance.toStringAsFixed(0)}m');

      // 3. Si la distancia es corta (< 2km), usar navegación peatonal simple
      if (distance < 2000) {
        _log('� [ROUTE] Distancia < 2km, usando navegación peatonal simple');
        await _startSimplePedestrianNavigation(
          destination: destName,
          destLat: destLat,
          destLon: destLon,
        );
      } else {
        // Para distancias largas, usar navegación multi-modal
        _log('� [ROUTE] Distancia >= 2km, usando navegación multi-modal');
        await _startIntegratedMoovitNavigation(destination, destLat, destLon);
      }
    } catch (e, stackTrace) {
      _log('❌ [SEARCH] ERROR: $e');
      _log('❌ [SEARCH] StackTrace: $stackTrace');
      _showErrorNotification('Error calculando ruta: ${e.toString()}');
      TtsService.instance.speak(
        'Error al calcular la ruta. Por favor intenta nuevamente.',
      );
    }
  }

  /// Navegación peatonal simple para distancias cortas
  Future<void> _startSimplePedestrianNavigation({
    required String destination,
    required double destLat,
    required double destLon,
  }) async {
    try {
      _log('🚶 [PEDESTRIAN] Obteniendo ruta peatonal desde backend...');

      // Obtener geometría de ruta peatonal desde backend
      final geometry = await GeometryService.instance.getWalkingGeometry(
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
        LatLng(destLat, destLon),
      );

      if (geometry == null) {
        throw Exception('No se pudo obtener la ruta peatonal');
      }

      _log('🚶 [PEDESTRIAN] Geometría obtenida: ${geometry.geometry.length} puntos');
      _log('🚶 [PEDESTRIAN] Distancia: ${geometry.distanceMeters}m');
      _log('🚶 [PEDESTRIAN] Duración: ${geometry.durationSeconds}s');
      _log('🚶 [PEDESTRIAN] Instrucciones: ${geometry.instructions.length}');

      // Convertir instrucciones a texto
      final instructionTexts = geometry.instructions
          .map((inst) => inst.text)
          .toList();

      // Actualizar UI con la ruta
      setState(() {
        _hasActiveTrip = true;
        _polylines = [
          Polyline(
            points: geometry.geometry,
            color: Colors.blue,
            strokeWidth: 4.0,
          ),
        ];

        // Guardar instrucciones
        _currentInstructions = instructionTexts;
        _currentInstructionStep = 0;
        _instructionFocusIndex = 0;

        // Agregar marcador de destino
        _markers = [
          ..._markers,
          Marker(
            point: LatLng(destLat, destLon),
            width: 40,
            height: 40,
            child: const Icon(
              Icons.place,
              color: Colors.red,
              size: 40,
            ),
          ),
        ];
      });

      // Centrar mapa en la ruta
      final bounds = LatLngBounds.fromPoints([
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
        LatLng(destLat, destLon),
      ]);
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: const EdgeInsets.all(50),
        ),
      );

      // Anunciar resultado
      final durationMinutes = (geometry.durationSeconds / 60).round();
      final distanceKm = (geometry.distanceMeters / 1000).toStringAsFixed(1);

      String message = 'Ruta peatonal a $destination encontrada. '
          'Distancia: $distanceKm kilómetros, '
          'tiempo estimado: $durationMinutes minutos. ';

      if (instructionTexts.isNotEmpty) {
        message += 'Primera instrucción: ${instructionTexts[0]}';
        _currentInstructionStep = 1;
      }

      TtsService.instance.speak(message);
      _showSuccessNotification('Ruta peatonal calculada', withVibration: true);

      _log('✅ [PEDESTRIAN] Navegación peatonal iniciada exitosamente');
    } catch (e) {
      _log('❌ [PEDESTRIAN] Error: $e');
      rethrow;
    }
  }

  /// Calcula distancia en metros entre dos puntos
  double _calculateDistance(LatLng point1, LatLng point2) {
    const Distance distance = Distance();
    return distance.as(LengthUnit.Meter, point1, point2);
  }

  /// 🚌 NAVEGACIÓN INTEGRADA CON MOOVIT 🚌
  /// Inicia navegación completa usando scraping de Moovit + GTFS + GPS
  /// Inicia navegación integrada usando Moovit + IntegratedNavigationService
  /// Este método configura toda la navegación paso a paso con actualización
  /// automática del mapa según el progreso del usuario
  Future<void> _startIntegratedMoovitNavigation(
    String destination,
    double destLat,
    double destLon,
  ) async {
    _log('🚌 [MOOVIT] Iniciando navegación multi-modal a: $destination');
    
    if (_currentPosition == null) {
      _log('❌ [MOOVIT] Sin ubicación GPS');
      _showErrorNotification('No se puede calcular ruta sin ubicación actual');
      TtsService.instance.speak('No se puede obtener tu ubicación actual');
      return;
    }

    _log('📍 [MOOVIT] Origen: ${_currentPosition!.latitude}, ${_currentPosition!.longitude}');
    _log('📍 [MOOVIT] Destino: $destLat, $destLon');

    try {
      // Anunciar inicio de búsqueda
      TtsService.instance.speak('Buscando ruta con transporte público hacia $destination');

      // Iniciar navegación integrada
      // Este servicio maneja: scraping Moovit, construcción de pasos,
      // geometrías separadas por paso, y anuncios TTS
      _log('🌐 [MOOVIT] Llamando IntegratedNavigationService.startNavigation...');
      
      final startTime = DateTime.now();

      final navigation = await IntegratedNavigationService.instance
          .startNavigation(
            originLat: _currentPosition!.latitude,
            originLon: _currentPosition!.longitude,
            destLat: destLat,
            destLon: destLon,
            destinationName: destination,
          );

      final elapsed = DateTime.now().difference(startTime);
      _log('✅ [MOOVIT] startNavigation completó en ${elapsed.inSeconds}s');
      _log('� [MOOVIT] Navegación tiene ${navigation.steps.length} pasos');
      
      for (var i = 0; i < navigation.steps.length; i++) {
        final step = navigation.steps[i];
        if (step.type == 'bus') {
          _log('   Paso ${i + 1}: ${step.type} - Ruta ${step.busRoute ?? "N/A"} (${step.totalStops ?? 0} paradas)');
        } else {
          _log('   Paso ${i + 1}: ${step.type} - ${step.instruction}');
        }
      }

      // ══════════════════════════════════════════════════════════════
      // DIBUJAR RUTA COMPLETA EN EL MAPA (TODAS LAS ETAPAS)
      // ══════════════════════════════════════════════════════════════
      
      _log('🗺️ [MAP] Dibujando ruta completa con todos los legs...');
      _log('🗺️ [MAP] Número de legs en itinerario: ${navigation.itinerary.legs.length}');
      
      setState(() {
        _polylines.clear();
        _markers.clear();
        
        // Recorrer todos los legs del itinerario
        int legIndex = 0;
        for (var leg in navigation.itinerary.legs) {
          legIndex++;
          _log('🗺️ [MAP] ═══════════════════════════════════════');
          _log('🗺️ [MAP] Procesando leg $legIndex/${navigation.itinerary.legs.length}');
          _log('🗺️ [MAP]   type: ${leg.type}');
          _log('🗺️ [MAP]   isRedBus: ${leg.isRedBus}');
          _log('🗺️ [MAP]   instruction: ${leg.instruction}');
          _log('🗺️ [MAP]   geometry points: ${leg.geometry?.length ?? 0}');
          _log('🗺️ [MAP]   stops: ${leg.stops?.length ?? 0}');
          
          if (leg.geometry != null && leg.geometry!.isNotEmpty) {
            // Determinar estilo según el tipo de leg
            if (leg.type == 'walk') {
              // ⚫⚪⚫⚪ LÍNEA PUNTEADA PARA CAMINATA
              // Crear segmentos más largos para efecto punteado visible
              final points = leg.geometry!;
              if (points.length >= 2) {
                // Crear segmentos de 3-4 puntos, luego saltar 2 puntos para el "hueco"
                for (int i = 0; i < points.length - 1;) {
                  final segmentEnd = (i + 3 < points.length) ? i + 3 : points.length;
                  _polylines.add(Polyline(
                    points: points.sublist(i, segmentEnd),
                    color: Colors.black,
                    strokeWidth: 5.0,
                  ));
                  i += 5; // Avanzar 5 puntos (3 dibujados + 2 de hueco)
                }
              }
              _log('  ⚫⚪ Leg walk (punteada): ${leg.geometry!.length} puntos → Dibujados ~${(leg.geometry!.length / 5).ceil()} segmentos');
            } else if (leg.isRedBus) {
              // 🚌 LÍNEA CYAN CONTINUA PARA BUS
              _polylines.add(Polyline(
                points: leg.geometry!,
                color: const Color(0xFF00BCD4),
                strokeWidth: 5.0,
              ));
              _log('  🚌 Leg bus (CYAN continua): ${leg.geometry!.length} puntos');
            } else {
              // Otros tipos - línea roja continua
              _polylines.add(Polyline(
                points: leg.geometry!,
                color: const Color(0xFFE30613),
                strokeWidth: 4.0,
              ));
              _log('  ❓ Leg OTRO tipo (ROJA continua): ${leg.geometry!.length} puntos');
            }
          } else {
            _log('  ⚠️ Leg sin geometría - SALTADO');
          }
          
          // Agregar marcadores para paradas de bus
          if (leg.isRedBus && leg.stops != null && leg.stops!.isNotEmpty) {
            for (int i = 0; i < leg.stops!.length; i++) {
              final stop = leg.stops![i];
              final isFirstStop = i == 0; // Parada para SUBIR al bus
              final isLastStop = i == leg.stops!.length - 1; // Parada para BAJAR del bus
              
              if (isFirstStop) {
                // � ICONO DE BUS AZUL - PARADA PARA SUBIR (primera parada)
                _markers.add(Marker(
                  point: LatLng(stop.latitude, stop.longitude),
                  width: 40,
                  height: 40,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF2196F3), // Azul como en las imágenes
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF2196F3).withValues(alpha: 0.4),
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.directions_bus, // Icono de bus
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ));
                _log('  🚌 Parada SUBIR al bus: ${stop.name} → (${stop.latitude}, ${stop.longitude})');
              } else if (isLastStop) {
                // 🚌 ICONO DE BUS AZUL - PARADA PARA BAJAR (última parada)
                _markers.add(Marker(
                  point: LatLng(stop.latitude, stop.longitude),
                  width: 40,
                  height: 40,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF2196F3), // Azul como en las imágenes
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF2196F3).withValues(alpha: 0.4),
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.directions_bus, // Icono de bus
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ));
                _log('  🚌 Parada BAJAR del bus: ${stop.name} → (${stop.latitude}, ${stop.longitude})');
              } else {
                // ⚪ Paradas intermedias - Círculos BLANCOS con borde (como en las imágenes)
                _markers.add(Marker(
                  point: LatLng(stop.latitude, stop.longitude),
                  width: 14,
                  height: 14,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFF00BCD4), // Borde cyan
                        width: 2.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 3,
                        ),
                      ],
                    ),
                  ),
                ));
              }
            }
            _log('  🚏 Agregados ${leg.stops!.length} marcadores: 1 subir + ${leg.stops!.length - 2} intermedias + 1 bajar');
          }
        }
        
        // Agregar marcadores de origen y destino
        // 📍 MARCADOR DE ORIGEN (donde estás ahora)
        _log('📍 Marcador ORIGEN: lat=${_currentPosition!.latitude}, lon=${_currentPosition!.longitude}');
        _markers.add(Marker(
          point: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
          width: 48,
          height: 48,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.blue,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 4),
              boxShadow: [
                BoxShadow(
                  color: Colors.blue.withValues(alpha: 0.5),
                  blurRadius: 10,
                  spreadRadius: 3,
                ),
              ],
            ),
            child: const Icon(Icons.my_location, color: Colors.white, size: 24),
          ),
        ));
        
        // 🎯 MARCADOR DE DESTINO (donde quieres llegar)
        _log('🎯 Marcador DESTINO: lat=$destLat, lon=$destLon');
        _markers.add(Marker(
          point: LatLng(destLat, destLon),
          width: 48,
          height: 48,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.red,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 4),
              boxShadow: [
                BoxShadow(
                  color: Colors.red.withValues(alpha: 0.5),
                  blurRadius: 10,
                  spreadRadius: 3,
                ),
              ],
            ),
            child: const Icon(Icons.place, color: Colors.white, size: 28),
          ),
        ));
        
        _log('🗺️ Total polylines: ${_polylines.length}');
        _log('🗺️ Total markers: ${_markers.length}');
      });

      // ══════════════════════════════════════════════════════════════
      // CONFIGURAR CALLBACKS PARA ACTUALIZAR UI CUANDO CAMBIA EL PASO
      // ══════════════════════════════════════════════════════════════

      _log('� [MOOVIT] Configurando callbacks del servicio...');

      IntegratedNavigationService.instance.onStepChanged = (step) {
        if (!mounted) return;

        setState(() {
          _hasActiveTrip = true;

          // ⚠️ NO BORRAMOS LAS POLYLINES - LA RUTA COMPLETA YA ESTÁ DIBUJADA
          // Solo actualizamos los marcadores para mostrar la posición actual
          
          _log('� Paso actual: ${step.type} - ${step.instruction}');

          // Actualizar marcadores: mantener toda la ruta visible
          final activeNav =
              IntegratedNavigationService.instance.activeNavigation;
          if (activeNav != null) {
            _updateNavigationMarkers(step, activeNav);
          }

          // Actualizar instrucciones: usar instrucciones detalladas de GraphHopper si están disponibles
          if (step.streetInstructions != null &&
              step.streetInstructions!.isNotEmpty) {
            _currentInstructions = [
              step.instruction, // Instrucción principal
              '', // Línea en blanco
              'Sigue estos pasos:', // Encabezado
              ...step.streetInstructions!, // Instrucciones detalladas por calle
            ];
            _currentInstructionStep = 0;
            _instructionFocusIndex = 0;
            _log(
              '📝 Instrucciones detalladas actualizadas: ${step.streetInstructions!.length} pasos',
            );
          } else {
            // Fallback: solo instrucción principal
            _currentInstructions = [step.instruction];
            _currentInstructionStep = 0;
            _instructionFocusIndex = 0;
          }
        });

        // Anunciar nuevo paso y mostrar notificación
        _showNavigationNotification(step.instruction);
        _log('📍 Paso actual: ${step.instruction}');

        // Si hay instrucciones detalladas, anunciar la primera
        if (step.streetInstructions != null &&
            step.streetInstructions!.isNotEmpty) {
          _log('🗣️ Primera instrucción: ${step.streetInstructions!.first}');
        }
      };

      // Callback cuando llega a un paradero
      IntegratedNavigationService.instance.onArrivalAtStop = (stopId) {
        if (!mounted) return;
        _log('✅ Llegaste al paradero: $stopId');

        // Vibración de confirmación
        Vibration.vibrate(duration: 500);
        _showSuccessNotification(
          'Has llegado al paradero',
          withVibration: true,
        );
      };

      IntegratedNavigationService.instance.onDestinationReached = () {
        if (!mounted) return;
        _log('🎉 ¡Destino alcanzado!');

        setState(() {
          _hasActiveTrip = false;
          _isTrackingRoute = false;
        });

        _showSuccessNotification(
          '¡Felicitaciones! Has llegado a tu destino',
          withVibration: true,
        );

        Vibration.vibrate(duration: 1000);
      };

      // Callback cuando la geometría se actualiza (posición del usuario cambia)
      IntegratedNavigationService.instance.onGeometryUpdated = () {
        if (!mounted) return;

        setState(() {
          // Actualizar panel de estado con distancia/tiempo restante
          // Esto se hace automáticamente con setState que redibuja _statusMessage()

          // Actualizar polyline con geometría recortada según posición actual
          // NOTA: NO dibujar polyline para pasos de bus (ride_bus)
          final activeNav =
              IntegratedNavigationService.instance.activeNavigation;
          final currentStep = activeNav?.currentStep;
          final stepGeometry =
              IntegratedNavigationService.instance.currentStepGeometry;

          if (currentStep?.type == 'ride_bus') {
            // Para buses: NO dibujar línea, solo mantener paraderos como marcadores
            _polylines = [];
            _log(
              '🚌 [BUS] Geometría actualizada - No se dibuja polyline para ride_bus',
            );
          } else if (stepGeometry.isNotEmpty) {
            _polylines = [
              Polyline(
                points: stepGeometry,
                color: const Color(0xFFE30613), // Color Red
                strokeWidth: 5.0,
              ),
            ];
            _log(
              '🗺️ [GEOMETRY] Polyline actualizada: ${stepGeometry.length} puntos',
            );
          }

          // Actualizar posición del usuario
          final position = IntegratedNavigationService.instance.lastPosition;
          if (position != null) {
            _currentPosition = position;

            // Actualizar marcadores sin cambiar el paso
            final activeNav =
                IntegratedNavigationService.instance.activeNavigation;
            if (activeNav != null && activeNav.currentStep != null) {
              _updateNavigationMarkers(activeNav.currentStep!, activeNav);
            }

            // AUTO-CENTRAR el mapa si está en simulación y no se ha desactivado manualmente
            if (_autoCenter && !_userManuallyMoved) {
              final target = LatLng(position.latitude, position.longitude);
              _moveMap(target, _mapController.camera.zoom);
              _log('🗺️ [AUTO-CENTER] Centrando en posición simulada');
            }
          }
        });
      };

      // Dibujar mapa inicial con geometría del primer paso
      setState(() {
        _hasActiveTrip = true;

        _log('🗺️ [MAP] Llamando _updateNavigationMapState...');

        // Configurar polyline y marcadores iniciales
        _updateNavigationMapState(navigation);

        _log('🗺️ [MAP] Polylines después de actualizar: ${_polylines.length}');
        _log('🗺️ [MAP] Markers después de actualizar: ${_markers.length}');
      });

      _showSuccessNotification(
        'Navegación iniciada. Duración estimada: ${navigation.estimatedDuration} minutos',
        withVibration: true,
      );
    } catch (e, stackTrace) {
      _log('❌ [MOOVIT] ERROR en navegación integrada: $e');
      _log('❌ [MOOVIT] Tipo de error: ${e.runtimeType}');
      _log('❌ [MOOVIT] Stack trace: $stackTrace');
      _showErrorNotification('Error al calcular la ruta: $e');
      TtsService.instance.speak('Error al calcular la ruta. Intenta de nuevo.');
    }
  }

  /// Actualiza el estado del mapa (polylines y marcadores) para la navegación activa
  void _updateNavigationMapState(ActiveNavigation navigation) {
    // Usar la geometría DEL PASO ACTUAL, no la ruta completa
    final stepGeometry = IntegratedNavigationService.instance.currentStepGeometry;

    _log(
      '🗺️ [MAP] Actualizando mapa - Geometría del paso actual: ${stepGeometry.length} puntos',
    );
    _log('🗺️ [MAP] Paso actual: ${navigation.currentStep?.type} - ${navigation.currentStep?.instruction}');

    // Dibujar polyline del PASO ACTUAL solamente
    // NOTA: NO dibujar polyline para pasos de bus (ride_bus)
    if (navigation.currentStep?.type == 'ride_bus') {
      _polylines = [];
      _log('🚌 [BUS] No se dibuja polyline para ride_bus');
    } else if (stepGeometry.isNotEmpty) {
      _polylines = [
        Polyline(
          points: stepGeometry,
          color: const Color(0xFFE30613), // Color Red
          strokeWidth: 5.0,
        ),
      ];
      _log('✅ [MAP] Polyline dibujada con ${stepGeometry.length} puntos');
    } else {
      _polylines = [];
      _log('⚠️ [MAP] No hay geometría para dibujar');
    }

    // Actualizar marcadores
    _updateNavigationMarkers(navigation.currentStep, navigation);
  }

  /// Actualiza los marcadores del mapa durante la navegación
  /// Muestra: (1) marcador del paso actual, (2) bandera del destino final, (3) ubicación del usuario
  /// NOTA: Preserva marcadores de paradas de bus si existen
  void _updateNavigationMarkers(
    NavigationStep? currentStep,
    ActiveNavigation navigation,
  ) {
    // ⚠️ NO BORRAMOS TODOS LOS MARCADORES
    // Los marcadores de paradas de bus y la ruta completa ya fueron dibujados
    // Solo agregamos el marcador de posición actual SIN BORRAR los existentes
    
    // Buscar si ya existe un marcador de posición actual y eliminarlo
    _markers.removeWhere((m) => 
      m.point.latitude == _currentPosition?.latitude &&
      m.point.longitude == _currentPosition?.longitude
    );

    // Marcador de la ubicación del usuario (azul, siempre visible)
    if (_currentPosition != null) {
      _markers.add(
        Marker(
          point: LatLng(
            _currentPosition!.latitude,
            _currentPosition!.longitude,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.blue,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: [
                BoxShadow(
                  color: Colors.blue.withValues(alpha: 0.5),
                  blurRadius: 8,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(Icons.navigation, color: Colors.white, size: 20),
          ),
        ),
      );
    }

    // ⚠️ COMENTADO: No re-crear marcadores de paradas porque ya existen
    // Los marcadores de paradas fueron creados al inicio junto con la ruta completa
    
    _log('🗺️ [MARKERS] Manteniendo ${_markers.length} marcadores existentes');
  }

  /// Retorna el icono y color apropiado para cada tipo de paso
  /// Comando de voz para controlar navegación integrada
  void _onIntegratedNavigationVoiceCommand(String command) async {
    final normalized = command.toLowerCase();

    // Comandos para leer instrucciones
    if (normalized.contains('dónde estoy') ||
        normalized.contains('dónde me encuentro') ||
        normalized.contains('ubicación actual')) {
      _repeatCurrentInstruction();
      return;
    }

    if (normalized.contains('todas las instrucciones') ||
        normalized.contains('resumen de ruta') ||
        normalized.contains('leer ruta completa')) {
      _readAllInstructions();
      return;
    }

    if (normalized.contains('siguiente paso') ||
        normalized.contains('próximo paso') ||
        normalized.contains('siguiente instrucción')) {
      _readNextInstruction();
      return;
    }

    if (normalized.contains('repetir') ||
        normalized.contains('otra vez') ||
        normalized.contains('qué debo hacer')) {
      _repeatCurrentInstruction();
      return;
    }

    // Comando para ocultar/mostrar panel visual (para acompañantes)
    if (normalized.contains('mostrar instrucciones') ||
        normalized.contains('ver instrucciones')) {
      setState(() {
        _showInstructionsPanel = true;
        _autoReadInstructions = false;
      });
      TtsService.instance.speak('Mostrando panel de instrucciones');
      return;
    }

    if (normalized.contains('ocultar instrucciones') ||
        normalized.contains('cerrar panel')) {
      setState(() {
        _showInstructionsPanel = false;
        _autoReadInstructions = true;
      });
      TtsService.instance.speak('Panel ocultado, usando modo audio');
      return;
    }

    if (normalized.contains('cancelar navegación') ||
        normalized.contains('detener navegación')) {
      IntegratedNavigationService.instance.cancelNavigation();
      setState(() {
        _hasActiveTrip = false;
        _isTrackingRoute = false;
        _polylines.clear();
        _markers.clear();
        _currentInstructions.clear();
        _showInstructionsPanel = false;
      });
      _showWarningNotification('Navegación cancelada');
      TtsService.instance.speak('Navegación cancelada');
      return;
    }

    // Si no es un comando de control, buscar destino y comenzar navegación
    final destination = _extractDestination(command);
    if (destination != null && destination.isNotEmpty) {
      // Buscar dirección usando el servicio de validación
      try {
        final suggestions = await AddressValidationService.instance
            .suggestAddresses(destination, limit: 1);

        if (suggestions.isEmpty) {
          _showWarningNotification('No se encontró la dirección: $destination');
          TtsService.instance.speak('No se encontró la dirección $destination');
          return;
        }

        final selected = suggestions.first;
        final destLat = (selected['lat'] as num).toDouble();
        final destLon = (selected['lon'] as num).toDouble();
        final selectedName = selected['display_name'] as String;

        // Iniciar navegación integrada con Moovit
        await _startIntegratedMoovitNavigation(selectedName, destLat, destLon);
      } catch (e) {
        _showErrorNotification('Error buscando dirección: $e');
      }
    }
  }

  Future<void> _calculateRoute({
    required double destLat,
    required double destLon,
    required String destName,
  }) async {
    if (_currentPosition == null) return;

    try {
      final apiClient = ApiClient();
      final route = await apiClient.getPublicTransitRoute(
        originLat: _currentPosition!.latitude,
        originLon: _currentPosition!.longitude,
        destLat: destLat,
        destLon: destLon,
        departureTime: DateTime.now(),
        includeGeometry: true,
      );

      _displayRoute(route);

      // CAP-12: Guardar instrucciones para lectura posterior
      final instructions =
          (route['instructions'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [];

      setState(() {
        _currentInstructions = instructions;
        _currentInstructionStep = 0;
        _instructionFocusIndex = 0;
        _hasActiveTrip = true;
      });

      final durationMinutes = ((route['duration_seconds'] as num?) ?? 0) / 60;
      final distanceMeters = (route['distance_meters'] as num?) ?? 0;

      // CAP-12: Leer primera instrucción automáticamente
      String message =
          'Ruta a $destName encontrada. '
          'Duración: ${durationMinutes.round()} minutos, '
          'distancia: ${(distanceMeters / 1000).toStringAsFixed(1)} kilómetros. ';

      if (instructions.isNotEmpty) {
        message += 'Primera instrucción: ${instructions[0]}';
        _currentInstructionStep = 1;
        _instructionFocusIndex = 0;
      }

      TtsService.instance.speak(message);
      _announce('Ruta calculada exitosamente');
    } catch (e) {
      if (e is ApiException && e.isNetworkError) {
        _showWarningNotification(
          'Servidor no disponible, usando ruta de demostración',
        );
        _displayFallbackRoute(
          destLat: destLat,
          destLon: destLon,
          destName: destName,
        );
        return;
      }

      TtsService.instance.speak(
        'Error calculando ruta. Verifique la conexión con el servidor',
      );
      _showErrorNotification('No se pudo calcular la ruta: ${e.toString()}');
    }
  }

  void _displayFallbackRoute({
    required double destLat,
    required double destLon,
    required String destName,
  }) {
    if (_currentPosition == null) {
      return;
    }

    final origin = LatLng(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
    );
    final destination = LatLng(destLat, destLon);

    setState(() {
      _polylines = [
        Polyline(
          points: [origin, destination],
          color: Colors.blueGrey,
          strokeWidth: 4,
        ),
      ];
      _markers = [
        Marker(
          point: origin,
          child: const Icon(Icons.my_location, color: Colors.blue, size: 30),
        ),
        Marker(
          point: destination,
          child: const Icon(Icons.location_on, color: Colors.orange, size: 30),
        ),
      ];
    });

    final distanceMeters = Geolocator.distanceBetween(
      origin.latitude,
      origin.longitude,
      destination.latitude,
      destination.longitude,
    );

    TtsService.instance.speak(
      'Ruta de demostración hacia $destName. Distancia aproximada ${(distanceMeters / 1000).toStringAsFixed(1)} kilómetros. '
      'Conéctate al servidor para obtener instrucciones detalladas.',
    );
  }

  /// Muestra un diálogo con rutas alternativas y permite seleccionar una
  /// Muestra la ruta calculada con detalles de itinerario estilo Moovit
  /// Display route from GraphHopper (fallback, ya no se usa porque ahora
  /// todo viene de IntegratedNavigationService que usa Moovit)
  void _displayRoute(Map<String, dynamic> route) {
    _polylines.clear();

    final geometry = route['geometry'] as List<dynamic>?;
    if (geometry != null && geometry.isNotEmpty) {
      final points = geometry.map((point) {
        final coords = point as List<dynamic>;
        // GraphHopper geometry is [lon, lat], convert to LatLng(lat, lon)
        return LatLng(coords[1] as double, coords[0] as double);
      }).toList();

      _polylines.add(
        Polyline(points: points, color: Colors.blue, strokeWidth: 4.0),
      );

      // Add destination marker
      final lastPoint = points.last;
      _markers.add(
        Marker(
          point: lastPoint,
          child: const Icon(Icons.location_on, color: Colors.green, size: 30),
        ),
      );
    }

    if (mounted) setState(() {});
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permiso Requerido'),
        content: const Text(
          'Esta aplicación necesita acceso al micrófono para el reconocimiento de voz.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
            child: const Text('Configuración'),
          ),
        ],
      ),
    );
  }

  void _toggleMicrophone() {
    if (!_speechEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Reconocimiento de voz no disponible'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (_isListening) {
      _stopListening();
    } else {
      _startListening();
    }
  }

  void _showWalkingInstructions() {
    if (_currentInstructions.isEmpty) {
      TtsService.instance.speak('No hay instrucciones de caminata disponibles');
      return;
    }

    // Para usuarios no videntes: leer resumen en lugar de mostrar panel
    if (_autoReadInstructions) {
      _readAllInstructions();
    } else {
      // Solo para acompañantes videntes
      setState(() {
        _showInstructionsPanel = !_showInstructionsPanel;
      });

      if (_showInstructionsPanel) {
        TtsService.instance.speak(
          'Mostrando ${_currentInstructions.length} instrucciones de caminata',
        );
      } else {
        TtsService.instance.speak('Ocultando instrucciones');
      }
    }
  }

  void _readAllInstructions() {
    final total = _currentInstructions.length;
    TtsService.instance.speak(
      'Tienes $total pasos en tu ruta. Voy a leerlos.',
      urgent: true,
    );

    Future.delayed(const Duration(seconds: 2), () {
      for (int i = 0; i < _currentInstructions.length; i++) {
        Future.delayed(Duration(seconds: i * 4), () {
          TtsService.instance.speak(
            'Paso ${i + 1} de $total: ${_currentInstructions[i]}',
            urgent: false,
          );
        });
      }
    });
  }

  Widget _buildMicrophoneContent() {
    // UI SIMPLIFICADA: Solo mostrar estado del micrófono y brújula
    if (_isCalculatingRoute) {
      return const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
          SizedBox(height: 8),
          Text(
            'Calculando...',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // SOLO: Ícono del micrófono (grande y claro)
        Icon(
          _isListening ? Icons.mic : Icons.mic_none,
          color: Colors.white,
          size: 40,
        ),

        // Brújula (orientación) si está disponible - siempre visible
        if (_currentPosition?.heading != null) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Transform.rotate(
                angle: _currentPosition!.heading * 3.14159 / 180,
                child: const Icon(
                  Icons.navigation,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${_currentPosition!.heading.toStringAsFixed(0)}°',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
  @override
  @override
  void dispose() {
    _resultDebounce?.cancel();
    _feedbackTimer?.cancel();
    _confirmationTimer?.cancel();
    _walkSimulationTimer?.cancel(); // Cancelar simulación de caminata
    _simulationTimer?.cancel(); // Cancelar simulación debug
    _headingSubscription?.cancel(); // Cancelar suscripción de brújula
    _volumeGestureTimer?.cancel(); // Cancelar timer de gestos

    unawaited(TtsService.instance.releaseContext('map_navigation'));

    // Liberar servicios de tracking
    RouteTrackingService.instance.dispose();
    TransitBoardingService.instance.dispose();

    // Garantiza liberar el reconocimiento si la vista se destruye
    if (_isListening) {
      _speech.stop();
    }
    // Intenta cancelar cualquier operación pendiente
    _speech.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FF),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final double overlayBase = math.max(
            _overlayBaseOffset(context, min: 260),
            constraints.maxHeight * 0.26,
          );
          final double gap = _overlayGap(context);
          final double floatingPrimary = overlayBase + gap * 2;
          // floatingSecondary eliminado - botón de configuración removido
          final double instructionsBottom = overlayBase + gap * 0.85;
          final bool hasActiveNavigation =
              IntegratedNavigationService.instance.activeNavigation != null;

          return Stack(
            children: [
              // Área del mapa con esquinas suavizadas
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(32),
                  ),
                  child: FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _currentPosition != null
                          ? LatLng(
                              _currentPosition!.latitude,
                              _currentPosition!.longitude,
                            )
                          : _initialPosition,
                      initialZoom: 17.0, // Zoom más cercano para ver calles
                      minZoom: 10.0,
                      maxZoom: 19.0,
                      initialRotation: 0.0,
                      
                      // ═══════════════════════════════════════════════════════════
                      // 🌎 OPCIÓN FUTURA: MAPA 3D CON INCLINACIÓN
                      // ═══════════════════════════════════════════════════════════
                      // FlutterMap (OSM) NO soporta verdadero 3D/tilt/perspectiva
                      // Solo puede rotar el mapa (rotation: 0-360°)
                      //
                      // PARA VERDADERO 3D con inclinación de cámara:
                      //
                      // OPCIÓN 1: Google Maps (recomendado para Android)
                      //   dependencies:
                      //     google_maps_flutter: ^2.5.0
                      //   
                      //   GoogleMap(
                      //     tilt: 45.0,  // Inclinación 0-90° (perspectiva 3D)
                      //     bearing: 0.0, // Rotación de brújula
                      //   )
                      //
                      // OPCIÓN 2: Mapbox (multiplataforma, requiere API key)
                      //   dependencies:
                      //     mapbox_maps_flutter: ^1.0.0
                      //   
                      //   MapboxMap(
                      //     styleUri: MapboxStyles.STREETS,
                      //     cameraOptions: CameraOptions(
                      //       pitch: 60.0, // Inclinación 3D
                      //     ),
                      //   )
                      //
                      // OPCIÓN 3: Apple Maps (solo iOS)
                      //   dependencies:
                      //     apple_maps_flutter: ^1.0.0
                      //
                      // Por ahora: FlutterMap con rotation para navegación básica
                      // ═══════════════════════════════════════════════════════════
                      
                      onMapReady: () {
                        _isMapReady = true;
                        
                        // Auto-centrar en usuario al abrir la app
                        if (_currentPosition != null) {
                          _log('🎯 [AUTO-CENTRO] Centrando en usuario al iniciar');
                          _mapController.move(
                            LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
                            17.0,
                          );
                          setState(() {
                            _autoCenter = true;
                          });
                        }

                        if (_pendingCenter != null) {
                          final zoom =
                              _pendingZoom ?? _mapController.camera.zoom;
                          _mapController.move(_pendingCenter!, zoom);
                          _pendingCenter = null;
                          _pendingZoom = null;
                        }

                        if (_pendingRotation != null) {
                          _mapController.rotate(_pendingRotation!);
                          _pendingRotation = null;
                        }
                      },
                      onPositionChanged: (position, hasGesture) {
                        // Solo desactivar auto-centrado si es un gesto MANUAL del usuario
                        // Y NO estamos en simulación automática
                        if (hasGesture && _autoCenter && !_isSimulatingWalk) {
                          setState(() {
                            _userManuallyMoved = true;
                            _autoCenter = false;
                          });
                          _log(
                            '🗺️ [MANUAL] Auto-centrado desactivado por gesto manual del usuario',
                          );
                          TtsService.instance.speak('Auto-centrado desactivado. Presiona el botón de ubicación para reactivarlo');
                        }
                      },
                      keepAlive: true,
                    ),
                    children: [
                      TileLayer(
                        // CAMBIO: Usar OpenStreetMap estándar (más confiable)
                        // OpenStreetMap tiene diferentes "capas" de tiles:
                        // - Standard: https://tile.openstreetmap.org/{z}/{x}/{y}.png (recomendado)
                        // - Transport Thunderforest: requiere API key
                        // - Public Transport MemoMaps: puede tener timeouts
                        // - OpenPTMap: tiene problemas de conexión frecuentes ❌
                        //
                        // Usaremos OpenStreetMap estándar que es más estable y confiable
                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.wayfindcl',
                        maxZoom: 19,
                        maxNativeZoom: 19,
                        retinaMode: false,
                        // Configurar timeouts para evitar bloqueos
                        tileProvider: NetworkTileProvider(),
                      ),
                      if (_polylines.isNotEmpty)
                        PolylineLayer(polylines: _polylines),
                      if (_markers.isNotEmpty) MarkerLayer(markers: _markers),
                    ],
                  ),
                ),
              ),

              // Encabezado con título e indicador IA
              Positioned(
                top: MediaQuery.of(context).padding.top + 12,
                left: 16,
                right: 16,
                child: Center(child: _buildHeaderChips(context)),
              ),

              // Acciones rápidas de simulación y guía paso a paso
              Positioned(
                left: 16,
                bottom: floatingPrimary,
                child: _buildNavigationQuickActions(hasActiveNavigation),
              ),

              // Botón naranja de simulación ELIMINADO (no necesario en navegación por voz)

              // Botón de centrar ubicación
              Positioned(
                right: 20,
                bottom: floatingPrimary,
                child: GestureDetector(
                  onTap: _centerOnUserLocation,
                  child: Container(
                    width: 58,
                    height: 58,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFF00BCD4), Color(0xFF0097A7)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Color(0x6600BCD4),
                          blurRadius: 18,
                          offset: Offset(0, 10),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.my_location,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ),

              // Botón de configuración ELIMINADO (no necesario en navegación por voz)
              // El usuario navega completamente por comandos de voz

              // Panel de instrucciones detalladas (GraphHopper)
              if (_hasActiveTrip)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: instructionsBottom,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: _buildInstructionsPanel(),
                    ),
                  ),
                ),

              // Panel inferior modernizado
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildBottomPanel(context),
              ),

              // Sistema de notificaciones
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: _activeNotifications.map((notification) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 480),
                            child: AccessibleNotification(
                              key: ValueKey(notification.hashCode),
                              notification: notification,
                              onDismiss: () =>
                                  _dismissNotification(notification),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeaderChips(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Logo de Red Movilidad (IZQUIERDA)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset(
              'assets/icons.webp',
              width: 32,
              height: 32,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE30613).withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.navigation_outlined,
                    color: Color(0xFFE30613),
                    size: 18,
                  ),
                );
              },
            ),
          ),
          
          const SizedBox(width: 12),
          
          // Texto WayFindCL (CENTRO)
          const Text(
            'WayFindCL',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Color(0xFFE30613),
              letterSpacing: 0.5,
            ),
          ),
          
          // Badge IA si NPU detectado (DERECHA)
          if (_npuDetected) ...[
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF7C3AED), Color(0xFFA855F7)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF7C3AED).withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  const Text(
                    'IA',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Panel minimalista durante navegación - píldora con micrófono y tiempo
  Widget _buildMinimizedNavigationPanel(bool isListening, bool isCalculating) {
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    final remainingTime = activeNav?.remainingTimeSeconds;
    final remainingDistance = activeNav?.distanceToNextPoint;
    
    // Formatear tiempo de llegada
    String etaText = '--:--';
    if (remainingTime != null && remainingTime > 0) {
      final duration = Duration(seconds: remainingTime);
      final minutes = duration.inMinutes;
      final hours = duration.inHours;
      
      if (hours > 0) {
        etaText = '${hours}h ${minutes % 60}min';
      } else {
        etaText = '${minutes}min';
      }
    }
    
    // Formatear distancia
    String distanceText = '--';
    if (remainingDistance != null && remainingDistance > 0) {
      if (remainingDistance >= 1000) {
        distanceText = '${(remainingDistance / 1000).toStringAsFixed(1)} km';
      } else {
        distanceText = '${remainingDistance.toInt()} m';
      }
    }

    final List<Color> micGradient = isCalculating
        ? const [Color(0xFF2563EB), Color(0xFF1D4ED8)]
        : isListening
        ? const [Color(0xFFE53935), Color(0xFFB71C1C)]
        : const [Color(0xFF00BCD4), Color(0xFF0097A7)];

    final Color micShadowColor = isCalculating
        ? const Color(0xFF1D4ED8)
        : isListening
        ? const Color(0xFFB71C1C)
        : const Color(0xFF00BCD4);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Píldora mejorada con información
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.white,
                    Colors.white.withValues(alpha: 0.95),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(32),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                  BoxShadow(
                    color: micShadowColor.withValues(alpha: 0.1),
                    blurRadius: 48,
                    spreadRadius: -8,
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Botón de micrófono
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: micGradient,
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: micShadowColor.withValues(alpha: 0.4),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: isCalculating
                            ? null
                            : () {
                                if (_isListening) {
                                  _stopListening();
                                } else {
                                  _startListening();
                                  // Vibración para confirmar activación
                                  Vibration.vibrate(duration: 50);
                                }
                              },
                        onLongPress: () {
                          // Vibración larga al mantener presionado
                          Vibration.vibrate(duration: 200, amplitude: 128);
                          TtsService.instance.speak('Micrófono activado para comandos de voz');
                        },
                        customBorder: const CircleBorder(),
                        child: Center(
                          child: Icon(
                            isCalculating
                                ? Icons.hourglass_empty
                                : isListening
                                ? Icons.mic
                                : Icons.mic_none,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                      ),
                    ),
                  ),
                  
                  const SizedBox(width: 16),
                  
                  // Información de tiempo y distancia
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Tiempo estimado
                      Row(
                        children: [
                          Icon(
                            Icons.access_time_rounded,
                            size: 18,
                            color: const Color(0xFF0F172A).withValues(alpha: 0.6),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            etaText,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF0F172A),
                              letterSpacing: -0.5,
                            ),
                          ),
                        ],
                      ),
                      
                      const SizedBox(height: 4),
                      
                      // Distancia restante
                      Row(
                        children: [
                          Icon(
                            Icons.straighten,
                            size: 16,
                            color: const Color(0xFF0F172A).withValues(alpha: 0.4),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            distanceText,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF0F172A).withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  
                  // Indicador de estado de voz
                  if (isListening || isCalculating) ...[
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: isCalculating
                            ? const Color(0xFF2563EB).withValues(alpha: 0.1)
                            : const Color(0xFFE53935).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isCalculating
                                  ? const Color(0xFF2563EB)
                                  : const Color(0xFFE53935),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isCalculating ? 'Procesando...' : 'Escuchando',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isCalculating
                                  ? const Color(0xFF2563EB)
                                  : const Color(0xFFE53935),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            
            // Botón de simulación DEBUG (solo visible si no hay navegación real activa)
            if (!_isTrackingRoute) ...[
              const SizedBox(height: 12),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _toggleSimulation,
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: _isSimulatingWalk
                          ? const Color(0xFFFF9800)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFFFF9800),
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _isSimulatingWalk ? Icons.pause : Icons.play_arrow,
                          color: _isSimulatingWalk
                              ? Colors.white
                              : const Color(0xFFFF9800),
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _isSimulatingWalk ? 'Detener Simulación' : '🐛 Simular Caminata',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: _isSimulatingWalk
                                ? Colors.white
                                : const Color(0xFFFF9800),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBottomPanel(BuildContext context) {
    final bool isListening = _isListening;
    final bool isCalculating = _isCalculatingRoute;
    final bool hasActiveNav = IntegratedNavigationService.instance.activeNavigation != null;

    // MODO MINIMIZADO: Durante navegación, solo mostrar micrófono
    if (hasActiveNav) {
      return _buildMinimizedNavigationPanel(isListening, isCalculating);
    }

    // MODO COMPLETO: Sin navegación, mostrar panel normal
    final List<Color> micGradient = isCalculating
        ? const [Color(0xFF2563EB), Color(0xFF1D4ED8)]
        : isListening
        ? const [Color(0xFFE53935), Color(0xFFB71C1C)]
        : const [Color(0xFF111827), Color(0xFF1F2937)];

    final Color micShadowColor = isCalculating
        ? const Color(0xFF1D4ED8)
        : isListening
        ? const Color(0xFFB71C1C)
        : Colors.black;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Colors.white, Color(0xFFF2F4F8)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.center,
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _statusMessage(),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isListening
                            ? const Color(0xFF00BCD4)
                            : const Color(0xFF111827),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (isListening && _speechConfidence > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Confianza: ${(_speechConfidence * 100).toInt()}%',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: _speechConfidence > 0.7
                                    ? const Color(0xFF22C55E)
                                    : _speechConfidence > 0.5
                                    ? const Color(0xFFF59E0B)
                                    : const Color(0xFFEF4444),
                              ),
                            ),
                            const SizedBox(height: 6),
                            SizedBox(
                              width: 180,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: LinearProgressIndicator(
                                  value: _speechConfidence,
                                  minHeight: 6,
                                  backgroundColor: const Color(0xFFE5E7EB),
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    _speechConfidence > 0.7
                                        ? const Color(0xFF22C55E)
                                        : _speechConfidence > 0.5
                                        ? const Color(0xFFF59E0B)
                                        : const Color(0xFFEF4444),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (_isProcessingCommand)
                      const Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Procesando comando...',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF2563EB),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 18),
                    Semantics(
                      label: isListening
                          ? 'Botón micrófono, escuchando'
                          : 'Botón micrófono, no escuchando',
                      hint: isListening
                          ? 'Toca para detener'
                          : 'Toca para iniciar',
                      button: true,
                      enabled: true,
                      child: GestureDetector(
                        onTap: _toggleMicrophone,
                        onLongPress: _showWalkingInstructions,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 320),
                          curve: Curves.easeInOut,
                          width: double.infinity,
                          height: 85,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: micGradient,
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: micShadowColor.withValues(alpha: 0.25),
                                blurRadius: 16,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: _buildMicrophoneContent(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildMessageHistoryPanel(),
                          _buildNavigationControlsPanel(),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    BottomNavBar(
                      currentIndex: 0,
                      onTap: (index) {
                        switch (index) {
                          case 0:
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Explorar')),
                            );
                            break;
                          case 1:
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Guardados (no implementado)'),
                              ),
                            );
                            break;
                          // Eliminado case 2: ContributeScreen (pantalla eliminada)
                          case 2:
                            Navigator.pushNamed(
                              context,
                              SettingsScreen.routeName,
                            );
                            break;
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMessageHistoryPanel() {
    if (_messageHistory.isEmpty) {
      return const SizedBox.shrink();
    }

    final List<String> entries = List<String>.from(_messageHistory.reversed);

    return Semantics(
      container: true,
      label: 'Mensajes recientes',
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(
          maxHeight: 90, // Limitar altura máxima para no cubrir el mapa
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF111827),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (int i = 0; i < entries.length; i++) ...[
                      Text(
                        entries[i],
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          height: 1.3,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (i != entries.length - 1) const SizedBox(height: 6),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavigationControlsPanel() {
    // Widget removed per user request to save screen space
    return const SizedBox.shrink();
  }

  /// Simplifica nombres de paraderos para TTS
  /// Convierte "PA1234 / Av. Providencia" en "Paradero" cuando es destino
  /// o simplemente remueve el código manteniendo la calle
  String _simplifyStopNameForTTS(
    String stopName, {
    bool isDestination = false,
  }) {
    // Si es el destino final, solo decir "Paradero"
    if (isDestination) {
      if (stopName.toLowerCase().contains('paradero') ||
          stopName.toLowerCase().contains('parada')) {
        return 'Paradero';
      }
    }

    // Para paraderos intermedios, remover códigos pero mantener la calle
    String cleaned = stopName;

    // Remover código de paradero (PA seguido de números)
    cleaned = cleaned.replaceAll(RegExp(r'PA\d+\s*[/\-]\s*'), '');

    // Remover "Paradero" o "Parada" seguido de números
    cleaned = cleaned.replaceAll(RegExp(r'Paradero\s+\d+\s*[/\-]\s*'), '');
    cleaned = cleaned.replaceAll(RegExp(r'Parada\s+\d+\s*[/\-]\s*'), '');

    // Limpiar espacios extra
    cleaned = cleaned.trim();

    // Si después de limpiar está vacío, retornar "Paradero"
    if (cleaned.isEmpty) {
      return 'Paradero';
    }

    return cleaned;
  }
}
