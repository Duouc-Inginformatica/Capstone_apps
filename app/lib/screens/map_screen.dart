import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:speech_to_text/speech_to_text.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:vibration/vibration.dart';
import '../services/tts_service.dart';
import '../services/api_client.dart';
import '../services/combined_routes_service.dart';
import '../services/route_recommendation_service.dart';
import '../services/address_validation_service.dart';
import '../services/route_tracking_service.dart';
import '../services/transit_boarding_service.dart';
import '../services/red_cl_scraper_service.dart';
import '../services/integrated_navigation_service.dart';
import '../widgets/itinerary_details.dart';
import 'settings_screen.dart';
import '../widgets/bottom_nav.dart';
import 'contribute_screen.dart';

enum NotificationType { success, error, warning, info, navigation, orientation }

class NotificationData {
  final String message;
  final NotificationType type;
  final IconData? icon;
  final Duration duration;
  final bool withSound;
  final bool withVibration;

  NotificationData({
    required this.message,
    required this.type,
    this.icon,
    this.duration = const Duration(seconds: 3),
    this.withSound = true,
    this.withVibration = false,
  });
}

class AccessibleNotification extends StatefulWidget {
  final NotificationData notification;
  final VoidCallback onDismiss;

  const AccessibleNotification({
    super.key,
    required this.notification,
    required this.onDismiss,
  });

  @override
  State<AccessibleNotification> createState() => _AccessibleNotificationState();
}

class _AccessibleNotificationState extends State<AccessibleNotification>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));

    _fadeAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _controller.forward();

    // Auto-dismiss después de la duración especificada
    Timer(widget.notification.duration, () {
      if (mounted) _dismiss();
    });

    // Reproducir sonido y vibración si están habilitados
    if (widget.notification.withSound) {
      TtsService.instance.speak(widget.notification.message);
    }
    if (widget.notification.withVibration) {
      Vibration.vibrate(duration: 100);
    }
  }

  void _dismiss() async {
    await _controller.reverse();
    widget.onDismiss();
  }

  Color _getBackgroundColor() {
    switch (widget.notification.type) {
      case NotificationType.success:
        return Colors.green.shade700;
      case NotificationType.error:
        return Colors.red.shade700;
      case NotificationType.warning:
        return Colors.orange.shade700;
      case NotificationType.info:
        return Colors.blue.shade700;
      case NotificationType.navigation:
        return Colors.purple.shade700;
      case NotificationType.orientation:
        return Colors.teal.shade700;
    }
  }

  IconData _getIcon() {
    if (widget.notification.icon != null) {
      return widget.notification.icon!;
    }

    switch (widget.notification.type) {
      case NotificationType.success:
        return Icons.check_circle;
      case NotificationType.error:
        return Icons.error;
      case NotificationType.warning:
        return Icons.warning;
      case NotificationType.info:
        return Icons.info;
      case NotificationType.navigation:
        return Icons.navigation;
      case NotificationType.orientation:
        return Icons.explore;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _getBackgroundColor(),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(
                _getIcon(),
                color: Colors.white,
                size: 24,
                semanticLabel: widget.notification.type.name,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.notification.message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                  semanticsLabel: widget.notification.message,
                ),
              ),
              GestureDetector(
                onTap: _dismiss,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  child: const Icon(
                    Icons.close,
                    color: Colors.white70,
                    size: 20,
                    semanticLabel: 'Cerrar notificación',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  static const routeName = '/map';

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
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

  // Trip state - solo mostrar paradas cuando hay un viaje activo
  bool _hasActiveTrip = false;
  bool _showStops = false;

  // CAP-9: Confirmación de destino
  String? _pendingConfirmationDestination;
  Timer? _confirmationTimer;

  // CAP-12: Instrucciones de ruta
  List<String> _currentInstructions = [];
  int _currentInstructionStep = 0;
  bool _isCalculatingRoute = false;
  bool _showInstructionsPanel = false;

  // Lectura automática de instrucciones
  bool _autoReadInstructions = true; // Por defecto ON para no videntes
  Timer? _instructionReadTimer;
  int _lastAnnouncedInstruction = -1;

  // CAP-29: Confirmación de micro abordada
  bool _waitingBoardingConfirmation = false;

  // CAP-20 & CAP-30: Seguimiento en tiempo real
  bool _isTrackingRoute = false;

  // Ruta seleccionada recientemente (para tarjeta persistente)
  CombinedRoute? _selectedCombinedRoute;
  List<LatLng> _selectedPlannedRoute = [];
  String? _selectedDestinationName;

  // Accessibility features
  final bool _isAccessibilityMode = true;
  Timer? _feedbackTimer;

  // Auto-center durante simulación
  bool _autoCenter = true; // Por defecto activado
  bool _userManuallyMoved = false; // Detecta si el usuario movió el mapa

  // Velocidad de simulación - rápida para que "vuele" hasta el paradero
  double _simulationSpeed = 20.0; // Velocidad rápida (20x)

  // Control de visualización de ruta de bus
  bool _busRouteShown =
      false; // Rastrea si ya se mostró la ruta del bus en wait_bus
  int _currentBusStopIndex =
      -1; // Índice de la parada actual durante simulación
  ActiveNavigation?
  _currentSimulationNav; // Navegación activa durante simulación

  // Notification system
  final List<NotificationData> _activeNotifications = [];
  final int _maxNotifications = 3;

  // Map and location services
  final MapController _mapController = MapController();
  bool _isMapReady = false;
  double? _pendingRotation;
  LatLng? _pendingCenter;
  double? _pendingZoom;
  Position? _currentPosition;
  List<Marker> _markers = [];
  List<Polyline> _polylines = [];
  List<dynamic> _nearbyStops = [];
  bool _isLoadingLocation = true;
  bool _isLoadingStops = false;

  // Default location (Santiago, Chile)
  static const LatLng _initialPosition = LatLng(-33.4489, -70.6693);

  @override
  void initState() {
    super.initState();
    // Usar post-frame callback para evitar bloquear la construcción del widget
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initServices();
      _setupTrackingCallbacks();
      _setupBoardingCallbacks();
    });
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
      print('Error inicializando Speech: $e');
    });

    // Iniciar ubicación con pequeño retraso para dar tiempo al UI a estabilizarse
    Future.delayed(const Duration(milliseconds: 250), () {
      _initLocation().catchError((e, st) {
        print('Error inicializando Location: $e');
      });
    });

    // Iniciar brújula un poco después
    Future.delayed(const Duration(milliseconds: 500), () {
      _initCompass().catchError((e, st) {
        print('Error inicializando Compass: $e');
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
    print('🧭 Brújula deshabilitada para optimización de rendimiento');
  }

  void _provideOrientationFeedback() {
    // Brújula deshabilitada para mejorar rendimiento
  }

  void _describeNearbyElements() {
    // Brújula deshabilitada - función no utilizada
  }

  void _announceCurrentLocation() {
    if (_currentPosition == null) {
      TtsService.instance.speak('Ubicación no disponible');
      return;
    }

    final lat = _currentPosition!.latitude;
    final lon = _currentPosition!.longitude;

    TtsService.instance.speak(
      'Te encuentras en latitud ${lat.toStringAsFixed(4)}, '
      'longitud ${lon.toStringAsFixed(4)}.',
    );

    if (_nearbyStops.isNotEmpty && _showStops) {
      TtsService.instance.speak('Hay ${_nearbyStops.length} paradas cercanas');
    }
  }

  void _announceAvailableCommands() {
    final commands = [
      'Comandos disponibles:',
      'Para navegación puedes decir de forma natural:',
      'Quiero ir a mall vivo los trapenses',
      'Llévame al hospital clínico',
      'Necesito ir a la universidad católica',
      'Como llego al aeropuerto',
      'Para confirmación: Sí, No, Confirmar, Cancelar',
      'Para instrucciones: Leer instrucciones, Siguiente paso, Repetir paso',
      'Para monitoreo: Monitorear abordaje, Iniciar seguimiento, Detener seguimiento',
      'Buscar paradas - para transporte público',
      'Orientación - saber hacia dónde miras',
      'Donde estoy - obtener ubicación actual',
      'Actualizar - refrescar ubicación',
      'Vibrar - activar vibración',
      'Configuración - abrir ajustes',
    ];

    TtsService.instance.speak(commands.join('. '));
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

    // CAP-29: Mostrar estado de monitoreo de abordaje
    if (_waitingBoardingConfirmation) {
      return 'Monitoreando abordaje...';
    }

    // CAP-30: Mostrar seguimiento activo
    if (_isTrackingRoute) {
      return 'Seguimiento en tiempo real activo';
    }

    if (_isLoadingStops) {
      return 'Cargando paradas...';
    }
    if (_pendingDestination != null) {
      return 'Destino pendiente: $_pendingDestination';
    }
    if (_hasActiveTrip && _nearbyStops.isNotEmpty) {
      return '${_nearbyStops.length} paradas cercanas';
    }
    if (_lastWords.isNotEmpty) {
      return 'Último: $_lastWords';
    }
    return 'Pulsa para hablar';
  }

  /// Construye el panel de instrucciones detalladas de navegación
  Widget _buildInstructionsPanel() {
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    if (activeNav == null) return const SizedBox.shrink();

    final currentStep = activeNav.currentStep;
    if (currentStep == null) return const SizedBox.shrink();

    // Solo mostrar para pasos de caminata con instrucciones
    if (currentStep.type != 'walk' ||
        currentStep.streetInstructions == null ||
        currentStep.streetInstructions!.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 250),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.blue[700]!, Colors.blue[900]!],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Encabezado
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  const Icon(
                    Icons.directions_walk,
                    color: Colors.white,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Instrucciones de Caminata',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        if (currentStep.realDistanceMeters != null)
                          Text(
                            '${(currentStep.realDistanceMeters! / 1000).toStringAsFixed(2)} km • ${(currentStep.realDurationSeconds! / 60).toStringAsFixed(0)} min',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.volume_up, color: Colors.white),
                    onPressed: () {
                      // Leer todas las instrucciones
                      TtsService.instance.speak(
                        'Instrucciones de caminata: ${currentStep.streetInstructions!.join(". ")}',
                      );
                    },
                    tooltip: 'Escuchar instrucciones',
                  ),
                ],
              ),
            ),

            const Divider(color: Colors.white30, height: 1),

            // Lista de instrucciones
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: currentStep.streetInstructions!.length,
                itemBuilder: (context, index) {
                  final instruction = currentStep.streetInstructions![index];
                  final isFirst = index == 0;

                  return InkWell(
                    onTap: () {
                      // Leer instrucción individual
                      TtsService.instance.speak(instruction);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: isFirst
                            ? Colors.white.withOpacity(0.2)
                            : Colors.transparent,
                        border: Border(
                          left: BorderSide(
                            color: isFirst ? Colors.yellow : Colors.white30,
                            width: 4,
                          ),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: isFirst ? Colors.yellow : Colors.white24,
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(
                                '${index + 1}',
                                style: TextStyle(
                                  color: isFirst ? Colors.black : Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              instruction,
                              style: TextStyle(
                                color: isFirst
                                    ? Colors.white
                                    : Colors.white.withOpacity(0.87),
                                fontSize: 15,
                                height: 1.4,
                                fontWeight: isFirst
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                          if (isFirst)
                            const Icon(
                              Icons.arrow_forward,
                              color: Colors.yellow,
                              size: 20,
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _announceCurrentOrientation() {
    final message = 'Toca para activar comando de voz.';
    TtsService.instance.speak(message);
    _announce(message);
  }

  // Timer para simular caminata
  Timer? _walkSimulationTimer;
  int _currentWalkInstructionIndex = 0;

  /// Devuelve el texto del botón de test según el paso actual
  String _getTestButtonLabel() {
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    if (activeNav == null) return 'TEST';

    final currentStep = activeNav.currentStep;
    if (currentStep == null) return 'TEST';

    switch (currentStep.type) {
      case 'walk':
        return 'Caminar';
      case 'wait_bus':
        return _busRouteShown ? 'Subir' : 'Ver Ruta';
      case 'ride_bus':
        return 'Viajar';
      default:
        return 'TEST';
    }
  }

  /// TEST: Simula caminata al paradero con anuncios TTS de instrucciones
  void _simulateArrivalAtStop() {
    final activeNav = IntegratedNavigationService.instance.activeNavigation;

    if (activeNav == null) {
      TtsService.instance.speak('No hay navegación activa');
      _showWarningNotification(
        'Primero inicia una navegación diciendo "ir a costanera center"',
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
        print('🚌 [TEST] Mostrando ruta completa del bus');

        // Crear visualización de la ruta del bus
        _createBusRouteVisualization(activeNav);

        setState(() {
          _busRouteShown = true;
        });

        // Obtener info del bus
        final busRoute = currentStep.busRoute ?? 'el bus';
        TtsService.instance.speak(
          'Se muestra la ruta completa del bus $busRoute hacia tu destino. Presiona nuevamente para simular que el bus ha llegado.',
        );

        _showSuccessNotification('Ruta del bus $busRoute mostrada');
      } else {
        // ⭐ SEGUNDO CLIC: SIMULAR LLEGADA DEL BUS Y AVANZAR
        print('🚌 [TEST] Simulando llegada del bus');

        final busRoute = currentStep.busRoute ?? 'el bus';
        TtsService.instance.speak(
          'Ha llegado el bus $busRoute. Subiendo al bus.',
        );

        // Resetear flag para próxima vez
        setState(() {
          _busRouteShown = false;
        });

        // Avanzar al paso de viaje en bus
        Future.delayed(const Duration(seconds: 2), () {
          IntegratedNavigationService.instance.advanceToNextStep();
          setState(() {
            _updateNavigationMapState(activeNav);
          });

          // Anunciar que estamos en el bus
          Future.delayed(const Duration(seconds: 1), () {
            TtsService.instance.speak(
              'Ahora estás en el bus $busRoute. Presiona el botón para simular el viaje.',
            );
          });
        });
      }
    } else if (currentStep.type == 'ride_bus') {
      // Simular viaje en bus pasando por cada parada
      print('🚌 [TEST] Simulando viaje en bus');

      final busRoute = currentStep.busRoute ?? 'el bus';
      TtsService.instance.speak(
        'Simulando viaje en $busRoute. Pasarás por todas las paradas.',
      );

      // Obtener geometría del paso de bus (coordenadas de paradas)
      final stepGeometry =
          IntegratedNavigationService.instance.currentStepGeometry;

      if (stepGeometry.isEmpty) {
        print('⚠️ [BUS] No hay geometría de paradas disponible');
        return;
      }

      print('🚌 [BUS] Simulando viaje por ${stepGeometry.length} paradas');

      // Simular movimiento por cada parada
      _simulateBusJourney(stepGeometry, activeNav);
    } else {
      TtsService.instance.speak('Paso actual: ${currentStep.type}');
    }
  }

  /// Simula el viaje en bus pasando por cada parada
  void _simulateBusJourney(List<LatLng> stops, ActiveNavigation activeNav) {
    // Cancelar simulación previa si existe
    _walkSimulationTimer?.cancel();

    int currentStopIndex = 0;
    final totalStops = stops.length;

    print('🚌 [BUS_SIM] Iniciando simulación de $totalStops paradas');

    // Guardar navegación actual para animación
    _currentSimulationNav = activeNav;

    // Obtener información de las paradas del itinerario
    final busLegs = activeNav.itinerary.legs
        .where((leg) => leg.type == 'bus')
        .toList();
    final stopDetails = busLegs.isNotEmpty ? busLegs.first.stops : null;

    // Intervalo entre paradas - muy rápido (20x = ~100ms por parada)
    final intervalMs = (2000 / _simulationSpeed)
        .round(); // Con velocidad 20x = 100ms por parada

    _walkSimulationTimer = Timer.periodic(Duration(milliseconds: intervalMs), (
      timer,
    ) {
      if (currentStopIndex >= totalStops) {
        timer.cancel();
        print('🚌 [BUS_SIM] Simulación de bus completada');

        // Limpiar estado de simulación
        setState(() {
          _currentBusStopIndex = -1;
          _currentSimulationNav = null;
        });

        // Avanzar al siguiente paso (arrival o walk final)
        Future.delayed(const Duration(milliseconds: 500), () {
          IntegratedNavigationService.instance.advanceToNextStep();
          setState(() {
            _updateNavigationMapState(activeNav);
          });
        });
        return;
      }

      // Actualizar índice de parada actual y redibujar marcadores
      setState(() {
        _currentBusStopIndex = currentStopIndex;
        _updateBusStopMarkersWithAnimation(activeNav);
      });

      // Inyectar posición en la parada actual
      final currentStop = stops[currentStopIndex];
      final position = Position(
        latitude: currentStop.latitude,
        longitude: currentStop.longitude,
        timestamp: DateTime.now(),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );

      // Obtener detalles de la parada si están disponibles
      String stopInfo = 'Parada ${currentStopIndex + 1}/$totalStops';
      if (stopDetails != null && currentStopIndex < stopDetails.length) {
        final stop = stopDetails[currentStopIndex];
        final code = stop.code != null && stop.code!.isNotEmpty
            ? ' [${stop.code}]'
            : '';
        stopInfo = '$stopInfo$code: ${stop.name}';
      }

      print('🚌 $stopInfo (${currentStop.latitude}, ${currentStop.longitude})');

      IntegratedNavigationService.instance.simulatePosition(position);

      // Centrar mapa en la parada actual
      if (_autoCenter && !_userManuallyMoved) {
        _moveMap(currentStop, 16.0);
      }

      currentStopIndex++;
    });
  }

  /// Simula caminata progresiva al paradero con instrucciones OSRM
  void _startWalkSimulation(NavigationStep walkStep) {
    // Cancelar simulación previa si existe
    _walkSimulationTimer?.cancel();

    if (walkStep.location == null || _currentPosition == null) {
      TtsService.instance.speak('Error: no se puede simular la caminata');
      return;
    }

    final stepGeometry =
        IntegratedNavigationService.instance.currentStepGeometry;

    if (stepGeometry.isEmpty) {
      print('⚠️ No hay geometría disponible para simular');
      TtsService.instance.speak('No hay ruta disponible para simular');
      return;
    }

    print(
      '🚶 Iniciando simulación de caminata con ${stepGeometry.length} puntos',
    );

    // Anunciar inicio
    TtsService.instance.speak('Comenzando navegación.');
    _showSuccessNotification('Simulación de caminata iniciada');

    // Esperar 2 segundos y leer primera instrucción de calle
    Timer(const Duration(seconds: 2), () {
      if (walkStep.streetInstructions != null &&
          walkStep.streetInstructions!.isNotEmpty) {
        final firstInstruction = walkStep.streetInstructions!.first;
        print('🗣️ Primera instrucción: $firstInstruction');
        TtsService.instance.speak(firstInstruction, urgent: true);
        _currentWalkInstructionIndex = 1;
      }
    });

    // Calcular puntos por instrucción para distribuir anuncios
    final pointsPerInstruction = walkStep.streetInstructions != null
        ? (stepGeometry.length / walkStep.streetInstructions!.length).ceil()
        : stepGeometry.length;

    print('📊 Puntos por instrucción: $pointsPerInstruction');

    // Simular movimiento a lo largo de la geometría
    int currentPointIndex = 0;
    final totalPoints = stepGeometry.length;
    int pointsSinceLastAnnouncement = 0;

    // Velocidad optimizada: para desarrollo/demostración
    // Si hay más de 20 puntos, completar en ~1 segundo
    int baseIntervalMs;
    if (totalPoints > 20) {
      // Distribuir 1000ms entre todos los puntos
      baseIntervalMs = (1000 / totalPoints).ceil();
      // Mínimo 20ms para evitar lag
      if (baseIntervalMs < 20) baseIntervalMs = 20;
    } else {
      // Para rutas cortas, 100ms por punto (más visible)
      baseIntervalMs = 100;
    }

    // Aplicar multiplicador de velocidad rápida (20x)
    int currentIntervalMs = (baseIntervalMs / _simulationSpeed).ceil();
    if (currentIntervalMs < 10) currentIntervalMs = 10; // Mínimo 10ms

    print(
      '⚡ Simulación rápida: ${currentIntervalMs}ms por punto (${totalPoints} puntos)',
    );

    void scheduleNextStep() {
      if (currentPointIndex >= totalPoints) {
        // Llegó al final
        _onWalkSimulationComplete(walkStep);
        return;
      }

      // Actualizar posición simulada
      final currentPoint = stepGeometry[currentPointIndex];

      // Velocidad constante y rápida para demostración
      currentIntervalMs = baseIntervalMs;

      final simulatedPosition = Position(
        latitude: currentPoint.latitude,
        longitude: currentPoint.longitude,
        timestamp: DateTime.now(),
        accuracy: 5.0,
        altitude: 0.0,
        altitudeAccuracy: 0.0,
        heading: currentPointIndex > 0
            ? _calculateBearing(
                stepGeometry[currentPointIndex - 1],
                currentPoint,
              )
            : 0.0,
        headingAccuracy: 0.0,
        speed: 1.4, // ~5 km/h velocidad de caminata
        speedAccuracy: 0.0,
      );

      // Inyectar posición
      IntegratedNavigationService.instance.simulatePosition(simulatedPosition);

      setState(() {
        _currentPosition = simulatedPosition;
      });

      final progress = ((currentPointIndex / totalPoints) * 100)
          .toStringAsFixed(0);
      print(
        '🚶 Punto $currentPointIndex/$totalPoints ($progress%) - Intervalo: ${currentIntervalMs}ms',
      );

      pointsSinceLastAnnouncement++;

      // Anunciar siguiente instrucción de calle progresivamente
      if (walkStep.streetInstructions != null &&
          _currentWalkInstructionIndex < walkStep.streetInstructions!.length &&
          pointsSinceLastAnnouncement >= pointsPerInstruction) {
        final nextInstruction =
            walkStep.streetInstructions![_currentWalkInstructionIndex];
        print(
          '🗣️ Anunciando instrucción ${_currentWalkInstructionIndex + 1}/${walkStep.streetInstructions!.length}: $nextInstruction',
        );
        TtsService.instance.speak(nextInstruction, urgent: true);
        _currentWalkInstructionIndex++;
        pointsSinceLastAnnouncement = 0;
      }

      // Programar siguiente paso
      currentPointIndex++;
      _walkSimulationTimer = Timer(
        Duration(milliseconds: currentIntervalMs),
        scheduleNextStep,
      );
    }

    // Iniciar simulación
    scheduleNextStep();
  }

  /// Calcula el ángulo de dirección entre dos puntos (bearing)
  double _calculateBearing(LatLng from, LatLng to) {
    final lat1 = from.latitude * math.pi / 180;
    final lat2 = to.latitude * math.pi / 180;
    final dLon = (to.longitude - from.longitude) * math.pi / 180;

    final y = math.sin(dLon) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);

    final bearing = math.atan2(y, x) * 180 / math.pi;
    return (bearing + 360) % 360; // Normalizar a 0-360
  }

  /// Finaliza la simulación de caminata
  void _onWalkSimulationComplete(NavigationStep walkStep) {
    print('✅ Simulación de caminata completada');

    // Forzar posición final en el paradero
    if (walkStep.location != null) {
      final finalPosition = Position(
        latitude: walkStep.location!.latitude,
        longitude: walkStep.location!.longitude,
        timestamp: DateTime.now(),
        accuracy: 3.0,
        altitude: 0.0,
        altitudeAccuracy: 0.0,
        heading: 0.0,
        headingAccuracy: 0.0,
        speed: 0.0,
        speedAccuracy: 0.0,
      );

      print(
        '🚌 [ARRIVAL] Forzando posición en paradero: ${walkStep.location!.latitude}, ${walkStep.location!.longitude}',
      );

      IntegratedNavigationService.instance.simulatePosition(finalPosition);

      setState(() {
        _currentPosition = finalPosition;
      });

      // Centrar mapa en el paradero
      _moveMap(
        LatLng(finalPosition.latitude, finalPosition.longitude),
        16.0, // Zoom cercano para ver el paradero
      );
      print('🗺️ [ARRIVAL] Mapa centrado en paradero');
    }

    // Esperar 1 segundo antes de anunciar para evitar interrupciones
    Future.delayed(const Duration(seconds: 1), () {
      // Anunciar llegada al paradero + información de la micro
      String arrivalMessage = 'Has llegado al paradero';

      // Buscar el siguiente paso para ver qué micro tomar
      final activeNav = IntegratedNavigationService.instance.activeNavigation;
      print('🚌 [ARRIVAL] activeNavigation: ${activeNav != null}');

      if (activeNav != null) {
        final currentStepIndex = activeNav.currentStepIndex;
        print('🚌 [ARRIVAL] currentStepIndex: $currentStepIndex');
        print('🚌 [ARRIVAL] total steps: ${activeNav.steps.length}');

        if (currentStepIndex + 1 < activeNav.steps.length) {
          final nextStep = activeNav.steps[currentStepIndex + 1];
          print('🚌 [ARRIVAL] nextStep.type: ${nextStep.type}');
          print('🚌 [ARRIVAL] nextStep.busRoute: ${nextStep.busRoute}');

          if (nextStep.type == 'wait_bus' && nextStep.busRoute != null) {
            // Tiempo estimado de llegada de la micro (entre 5-10 minutos)
            final estimatedArrivalMinutes = 7; // Promedio
            arrivalMessage += '. Debes tomar el bus ${nextStep.busRoute}. ';
            arrivalMessage +=
                'Tiempo estimado de llegada: $estimatedArrivalMinutes minutos';

            print('🚌 [ARRIVAL] Mensaje completo: $arrivalMessage');

            // Mostrar notificación con la información
            _showSuccessNotification(
              'Bus ${nextStep.busRoute} en $estimatedArrivalMinutes min',
            );

            // ⭐ CREAR RUTA COMPLETA DEL BUS (origen-destino)
            _createBusRouteVisualization(activeNav);

            // ⭐ AVANZAR AL SIGUIENTE PASO (wait_bus)
            print('🚌 [ARRIVAL] Avanzando al paso wait_bus');
            IntegratedNavigationService.instance.advanceToNextStep();

            // Actualizar mapa con el nuevo estado y marcar que la ruta ya se mostró
            setState(() {
              final updatedNav =
                  IntegratedNavigationService.instance.activeNavigation;
              if (updatedNav != null) {
                _updateNavigationMapState(updatedNav);
              }
              // Marcar que la ruta del bus ya se mostró automáticamente
              _busRouteShown = true;
            });
          } else {
            print('🚌 [ARRIVAL] No es wait_bus o no tiene busRoute');
          }
        } else {
          print('🚌 [ARRIVAL] No hay siguiente paso');
        }
      } else {
        print('🚌 [ARRIVAL] activeNavigation es NULL');
      }

      print('🚌 [ARRIVAL] Anunciando: $arrivalMessage');
      TtsService.instance.speak(arrivalMessage, urgent: true);
      _currentWalkInstructionIndex = 0;
    });
  }

  /// Crea y visualiza los paraderos del bus (sin mostrar la línea de ruta)
  void _createBusRouteVisualization(ActiveNavigation navigation) {
    print('🗺️ [BUS_STOPS] Mostrando paraderos de la ruta del bus...');

    // Buscar el leg del bus en el itinerario original
    final busLeg = navigation.itinerary.legs.firstWhere(
      (leg) => leg.type == 'bus' && leg.isRedBus,
      orElse: () => throw Exception('No se encontró leg de bus'),
    );

    // Obtener la lista de paraderos del leg
    final stops = busLeg.stops;
    if (stops == null || stops.isEmpty) {
      print('⚠️ [BUS_STOPS] No hay paraderos en el leg del bus');
      return;
    }

    print('� [BUS_STOPS] ${stops.length} paraderos encontrados');

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
      String label = '';

      if (isFirst) {
        // � PARADERO DE SUBIDA (verde brillante - punto de inicio del viaje en bus)
        markerColor = Colors.green.shade600;
        markerIcon = Icons.location_on_rounded; // Pin de ubicación
        markerSize = 52;
        label = 'SUBIDA';
      } else if (isLast) {
        // � PARADERO DE BAJADA (rojo - destino del viaje en bus)
        markerColor = Colors.red.shade600;
        markerIcon = Icons.flag_rounded; // Bandera de meta
        markerSize = 52;
        label = 'BAJADA';
      } else {
        // 🔵 PARADEROS INTERMEDIOS (azul con número de secuencia)
        markerColor = Colors.blue.shade600;
        markerIcon = Icons.circle;
        markerSize = 28;
        label = '${i}'; // Número de secuencia
      }

      final marker = Marker(
        point: stop.location,
        width: markerSize + 24,
        height: markerSize + 40,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icono del marcador con sombra mejorada
            Container(
              width: markerSize,
              height: markerSize,
              decoration: BoxDecoration(
                color: markerColor,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                  BoxShadow(
                    color: markerColor.withOpacity(0.5),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Center(
                child: isFirst || isLast
                    ? Icon(
                        markerIcon,
                        color: Colors.white,
                        size: markerSize * 0.65,
                      )
                    : Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
              ),
            ),
            // Etiqueta con código de parada (más visible)
            if (stop.code != null && stop.code!.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 3),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: markerColor.withOpacity(0.5),
                    width: 1,
                  ),
                ),
                child: Text(
                  stop.code!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
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

    print(
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

  /// Actualiza marcadores de paradas de bus con animación de progreso
  /// Muestra visualmente qué parada estás visitando actualmente
  void _updateBusStopMarkersWithAnimation(ActiveNavigation navigation) {
    print(
      '🎬 [ANIMATION] Actualizando marcadores - parada actual: $_currentBusStopIndex',
    );

    // Buscar el leg del bus
    final busLeg = navigation.itinerary.legs.firstWhere(
      (leg) => leg.type == 'bus' && leg.isRedBus,
      orElse: () => throw Exception('No se encontró leg de bus'),
    );

    final stops = busLeg.stops;
    if (stops == null || stops.isEmpty) return;

    // Crear marcadores con estados diferentes según progreso
    final stopMarkers = <Marker>[];

    for (int i = 0; i < stops.length; i++) {
      final stop = stops[i];
      final isFirst = i == 0;
      final isLast = i == stops.length - 1;
      final isCurrent = i == _currentBusStopIndex; // Parada actual
      final isVisited = i < _currentBusStopIndex; // Ya visitada

      // FILTRO DE VISUALIZACIÓN: Si hay muchas paradas, mostrar solo algunas clave
      // SIEMPRE mostrar: primera, última, y parada actual
      // Para el resto, aplicar filtro estratégico
      if (!isFirst && !isLast && stops.length > 10) {
        // La parada actual SIEMPRE se muestra
        if (!isCurrent) {
          final shouldShow = _shouldShowIntermediateStop(i, stops.length);
          if (!shouldShow) continue; // Saltar esta parada (no crear marcador)
        }
      }

      // Determinar color y estilo según estado
      Color markerColor;
      IconData markerIcon;
      double markerSize;
      String label = '';
      double opacity = 1.0;

      if (isFirst) {
        // 🟢 SUBIDA (siempre verde)
        markerColor = Colors.green.shade600;
        markerIcon = Icons.location_on_rounded;
        markerSize = 52;
        opacity = isVisited ? 0.5 : 1.0; // Más tenue si ya pasamos
      } else if (isLast) {
        // 🔴 BAJADA (siempre rojo)
        markerColor = Colors.red.shade600;
        markerIcon = Icons.flag_rounded;
        markerSize = 52;
      } else if (isCurrent) {
        // 🟡 PARADA ACTUAL (amarillo brillante con pulso)
        markerColor = Colors.amber.shade600;
        markerIcon = Icons.circle;
        markerSize = 36; // Más grande
        label = '${i}';
      } else if (isVisited) {
        // ⚪ YA VISITADA (gris tenue)
        markerColor = Colors.grey.shade400;
        markerIcon = Icons.circle;
        markerSize = 24;
        label = '${i}';
        opacity = 0.4;
      } else {
        // 🔵 POR VISITAR (azul normal)
        markerColor = Colors.blue.shade600;
        markerIcon = Icons.circle;
        markerSize = 28;
        label = '${i}';
        opacity = 0.7;
      }

      final marker = Marker(
        point: stop.location,
        width: (markerSize + 24) * (isCurrent ? 1.2 : 1.0),
        height: (markerSize + 40) * (isCurrent ? 1.2 : 1.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icono con animación de pulso para parada actual
            Stack(
              alignment: Alignment.center,
              children: [
                // Efecto de pulso para parada actual
                if (isCurrent)
                  Container(
                    width: markerSize * 1.5,
                    height: markerSize * 1.5,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: markerColor.withOpacity(0.3),
                    ),
                  ),
                // Marcador principal
                Container(
                  width: markerSize,
                  height: markerSize,
                  decoration: BoxDecoration(
                    color: markerColor.withOpacity(opacity),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white,
                      width: isCurrent ? 4 : 3,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: isCurrent ? 10 : 6,
                        offset: const Offset(0, 2),
                      ),
                      if (isCurrent)
                        BoxShadow(
                          color: markerColor.withOpacity(0.8),
                          blurRadius: 16,
                          spreadRadius: 4,
                        ),
                    ],
                  ),
                  child: Center(
                    child: isFirst || isLast
                        ? Icon(
                            markerIcon,
                            color: Colors.white,
                            size: markerSize * 0.65,
                          )
                        : Text(
                            label,
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: isCurrent ? 15 : 13,
                            ),
                          ),
                  ),
                ),
              ],
            ),
            // Código de parada
            if (stop.code != null && stop.code!.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 3),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(isCurrent ? 0.9 : 0.7),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: markerColor.withOpacity(0.5),
                    width: isCurrent ? 2 : 1,
                  ),
                ),
                child: Text(
                  stop.code!,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: isCurrent ? 10 : 9,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
          ],
        ),
      );

      stopMarkers.add(marker);
    }

    print(
      '🎬 [ANIMATION] ${stopMarkers.length} marcadores visibles de ${stops.length} paradas totales (parada actual: $_currentBusStopIndex)',
    );

    // Actualizar marcadores manteniendo ubicación actual
    final currentLocationMarker = _markers.firstWhere(
      (m) =>
          m.point.latitude == _currentPosition?.latitude &&
          m.point.longitude == _currentPosition?.longitude,
      orElse: () => _markers.first,
    );

    setState(() {
      _markers = [currentLocationMarker, ...stopMarkers];
    });
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

    print('🗺️ [FIT_BOUNDS] Centro: $center, Zoom: $zoom, Extensión: $maxDiff');

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

  String _lastAnnouncement = '';

  void _repeatLastAnnouncement() {
    if (_lastAnnouncement.isNotEmpty) {
      TtsService.instance.speak(_lastAnnouncement);
    } else {
      TtsService.instance.speak('No hay anuncios anteriores para repetir');
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
        setState(() => _isLoadingLocation = false);
        return;
      }

      // Get current location
      _currentPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      if (!mounted) return;

      setState(() {
        _isLoadingLocation = false;
      });

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
      setState(() => _isLoadingLocation = false);
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
              color: Colors.blue.withOpacity(0.2),
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
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
                BoxShadow(
                  color: Colors.blue.withOpacity(0.5),
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

  void _loadNearbyStops() async {
    if (_currentPosition == null || !_showStops) return;

    setState(() => _isLoadingStops = true);

    try {
      final apiClient = ApiClient();
      final stops = await apiClient.getNearbyStops(
        lat: _currentPosition!.latitude,
        lon: _currentPosition!.longitude,
        radius: 600, // Reducido a 600 metros para mejor rendimiento
        limit: 20, // Reducido a 20 paradas máximo
      );

      if (!mounted) return;

      setState(() {
        _nearbyStops = stops;
        _isLoadingStops = false;
      });

      _updateStopMarkers();

      _showSuccessNotification('${stops.length} paradas encontradas cerca');
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingStops = false);
      TtsService.instance.speak('Error cargando paradas de transporte');
    }
  }

  void _updateStopMarkers() {
    // Usar post-frame callback para evitar bloquear el UI durante la construcción
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final newMarkers = <Marker>[];

      // Siempre mostrar ubicación actual con icono mejorado
      if (_currentPosition != null) {
        newMarkers.add(
          Marker(
            point: LatLng(
              _currentPosition!.latitude,
              _currentPosition!.longitude,
            ),
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
                    color: Colors.blue.withOpacity(0.2),
                  ),
                ),
                // Círculo principal
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.blue.shade700,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                      BoxShadow(
                        color: Colors.blue.withOpacity(0.5),
                        blurRadius: 16,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.person_pin_circle_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
              ],
            ),
          ),
        );
      }

      // Solo mostrar paradas si están activas (_showStops = true)
      if (_showStops && _nearbyStops.isNotEmpty) {
        // Limitar a máximo 15 paradas para mejor rendimiento
        final stopsToShow = _nearbyStops.take(15);
        for (int i = 0; i < stopsToShow.length; i++) {
          final stop = stopsToShow.elementAt(i);
          final lat = stop['latitude'] as double?;
          final lon = stop['longitude'] as double?;
          final name = stop['name'] as String?;

          if (lat != null && lon != null && name != null) {
            newMarkers.add(
              Marker(
                point: LatLng(lat, lon),
                width: 36,
                height: 36,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.red.shade600,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.25),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.directions_bus_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            );
          }
        }
      }

      if (mounted) {
        setState(() {
          _markers = newMarkers;
        });
      }
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
    TtsService.instance.speak('Por ahora no puedo ejecutar ese comando.');
  }

  bool _handleNavigationCommand(String command) {
    // CAP-9: Confirmación de destino
    if (command.contains('sí') ||
        command.contains('si') ||
        command.contains('confirmar') ||
        command.contains('correcto')) {
      if (_pendingConfirmationDestination != null) {
        _confirmDestination();
        return true;
      }
    }

    if (command.contains('no') ||
        command.contains('cancelar') ||
        command.contains('incorrecto')) {
      if (_pendingConfirmationDestination != null) {
        _cancelDestinationConfirmation();
        return true;
      }
    }

    // CAP-29: Confirmación de abordaje de micro
    if (_waitingBoardingConfirmation) {
      TransitBoardingService.instance.confirmBoardingManually(command);
      return true;
    }

    // CAP-12: Leer instrucciones de ruta
    if (command.contains('leer instrucciones') ||
        command.contains('instrucciones') ||
        command.contains('pasos')) {
      _readCurrentInstructions();
      return true;
    }

    if (command.contains('siguiente paso') ||
        command.contains('próximo paso') ||
        command.contains('próxima instrucción')) {
      _readNextInstruction();
      return true;
    }

    if (command.contains('repetir paso') ||
        command.contains('repetir instrucción')) {
      _repeatCurrentInstruction();
      return true;
    }

    // CAP-30: Control de seguimiento
    if (command.contains('detener seguimiento') ||
        command.contains('parar seguimiento')) {
      _stopRouteTracking();
      return true;
    }

    if (command.contains('iniciar seguimiento') ||
        command.contains('empezar seguimiento')) {
      if (RouteTrackingService.instance.destination != null) {
        _startRouteTracking();
        return true;
      }
    }

    // CAP-29: Monitoreo de abordaje
    if (command.contains('monitorear abordaje') ||
        command.contains('activar monitoreo') ||
        (command.contains('sí') &&
            !_waitingBoardingConfirmation &&
            _hasActiveTrip)) {
      // Extraer número de bus si está disponible
      final busMatch = RegExp(
        r'bus\s*(\w+)',
        caseSensitive: false,
      ).firstMatch(command);
      final busRoute = busMatch?.group(1) ?? '506'; // Default para demo
      _startBoardingMonitoring(busRoute);
      return true;
    }

    if (command.contains('configuración') ||
        command.contains('configuracion')) {
      TtsService.instance.speak('Abriendo configuración');
      Navigator.of(context).pushNamed(SettingsScreen.routeName);
      return true;
    }
    if (command.contains('abrir ajustes') ||
        command.contains('abrir configuración')) {
      TtsService.instance.speak('Mostrando ajustes');
      Navigator.of(context).pushNamed(SettingsScreen.routeName);
      return true;
    }
    if (command.contains('paradas') || command.contains('transporte')) {
      setState(() => _showStops = true);
      TtsService.instance.speak('Buscando paradas de transporte cercanas');
      _loadNearbyStops();
      return true;
    }
    if (command.contains('actualizar') || command.contains('refrescar')) {
      TtsService.instance.speak('Actualizando ubicación');
      _initLocation(); // Solo actualiza ubicación, no paradas automáticamente
      return true;
    }
    if (command.contains('mostrar paradas') ||
        command.contains('ver paradas')) {
      setState(() => _showStops = true);
      if (_nearbyStops.isNotEmpty) {
        TtsService.instance.speak(
          '${_nearbyStops.length} paradas de transporte cerca de tu ubicación',
        );
        _updateStopMarkers(); // Actualizar marcadores existentes
      } else {
        TtsService.instance.speak('Buscando paradas cercanas');
        _loadNearbyStops();
      }
      return true;
    }
    if (command.contains('ocultar paradas') ||
        command.contains('limpiar mapa')) {
      setState(() {
        _showStops = false;
        _nearbyStops.clear();
      });
      _updateCurrentLocationMarker(); // Solo mostrar ubicación actual
      TtsService.instance.speak('Paradas ocultadas');
      return true;
    }
    if (command.contains('orientación') || command.contains('dirección')) {
      _announceCurrentOrientation();
      _describeNearbyElements();
      return true;
    }
    if (command.contains('donde estoy') || command.contains('ubicación')) {
      _announceCurrentLocation();
      return true;
    }
    if (command.contains('ayuda') || command.contains('comandos')) {
      _announceAvailableCommands();
      return true;
    }
    if (command.contains('vibrar') || command.contains('vibración')) {
      _triggerVibration();
      TtsService.instance.speak('Vibración activada');
      return true;
    }
    if (command.contains('repetir') || command.contains('otra vez')) {
      _repeatLastAnnouncement();
      return true;
    }
    return false;
  }

  String? _extractDestination(String command) {
    // Patrones más naturales y flexibles para extraer destinos
    final patterns = [
      // Patrones explícitos con "ir a"
      r'(?:quiero\s+)?(?:ir|dirigirme|llevarme|navegar|viajar)\s+a(?:l)?\s+(.+)',
      r'(?:me\s+)?(?:lleva|dirije|guia|navega)\s+a(?:l)?\s+(.+)',
      r'(?:como\s+)?(?:llego|voy)\s+a(?:l)?\s+(.+)',

      // Patrones con "hacia"
      r'(?:ir|dirigirme|navegar)\s+hacia\s+(?:el|la)?\s*(.+)',

      // Patrones con "buscar"
      r'busca(?:r|me)?\s+(?:el\s+)?(?:camino|ruta)\s+a(?:l)?\s+(.+)',
      r'encontrar\s+(?:el\s+)?(?:camino|ruta)\s+a(?:l)?\s+(.+)',

      // Patrones casuales y naturales
      r'quiero\s+(?:ir\s+)?a(?:l)?\s+(.+)',
      r'necesito\s+(?:ir\s+)?a(?:l)?\s+(.+)',
      r'voy\s+(?:para|al?)\s+(.+)',
      r'tengo\s+que\s+ir\s+a(?:l)?\s+(.+)',

      // Patrones específicos para lugares comunes
      r'(?:al\s+)?mall\s+(.+)',
      r'(?:al\s+)?centro\s+comercial\s+(.+)',
      r'(?:a\s+la\s+)?universidad\s+(.+)',
      r'(?:al\s+)?hospital\s+(.+)',
      r'(?:al\s+)?aeropuerto\s+(.+)',
      r'(?:a\s+la\s+)?estacion\s+(.+)',

      // Fallback: cualquier cosa después de preposiciones
      r'(?:para|hacia|en|al?|del?)\s+(.+)',
    ];

    for (final pattern in patterns) {
      final match = RegExp(pattern, caseSensitive: false).firstMatch(command);
      if (match != null) {
        final destination = match.group(1)?.trim();
        if (destination != null && destination.isNotEmpty) {
          // Limpiar palabras innecesarias al final
          String cleaned = destination
              .replaceAll(
                RegExp(
                  r'\s+(por\s+favor|porfavor|gracias)$',
                  caseSensitive: false,
                ),
                '',
              )
              .replaceAll(RegExp(r'\s+ahora$', caseSensitive: false), '')
              .trim();

          if (cleaned.isNotEmpty) {
            return cleaned;
          }
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

  /// CAP-12: Leer todas las instrucciones actuales
  void _readCurrentInstructions() {
    if (_currentInstructions.isEmpty) {
      TtsService.instance.speak('No hay instrucciones disponibles aún');
      return;
    }

    RouteTrackingService.instance.readAllInstructions(_currentInstructions);
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

    final instruction = _currentInstructions[_currentInstructionStep];
    TtsService.instance.speak(
      'Paso ${_currentInstructionStep + 1}: $instruction',
    );

    setState(() {
      _currentInstructionStep++;
    });
  }

  /// CAP-12: Repetir instrucción actual
  void _repeatCurrentInstruction() {
    if (_currentInstructions.isEmpty) {
      TtsService.instance.speak('No hay instrucciones disponibles');
      return;
    }

    final step = _currentInstructionStep > 0 ? _currentInstructionStep - 1 : 0;

    if (step < _currentInstructions.length) {
      final instruction = _currentInstructions[step];
      TtsService.instance.speak('Repitiendo paso ${step + 1}: $instruction');
    }
  }

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

  /// CAP-30: Detener seguimiento
  void _stopRouteTracking() {
    setState(() {
      _isTrackingRoute = false;
    });

    RouteTrackingService.instance.stopTracking();
    _showWarningNotification('Seguimiento detenido');
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
    _lastAnnouncement = message;
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

  void _showOrientationNotification(String message) {
    _showNotification(
      NotificationData(
        message: message,
        type: NotificationType.orientation,
        icon: Icons.explore,
        duration: const Duration(seconds: 2),
        withSound: false, // No sound for frequent orientation updates
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

  // Método para normalizar texto de entrada
  String _normalizeText(String text) {
    String normalized = text.toLowerCase().trim();

    // Remover acentos y caracteres especiales
    normalized = normalized
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ü', 'u')
        .replaceAll('ñ', 'n');

    // Normalizar variaciones de frases comunes
    final phraseNormalizations = {
      // Variaciones de "querer ir"
      r'quiero\s+ir\s+a(?:l)?\s+': 'ir a ',
      r'necesito\s+ir\s+a(?:l)?\s+': 'ir a ',
      r'tengo\s+que\s+ir\s+a(?:l)?\s+': 'ir a ',
      r'voy\s+a(?:l)?\s+': 'ir a ',
      r'voy\s+para\s+': 'ir a ',

      // Variaciones de lugares
      r'centro\s+comercial\s+': 'mall ',
      r'shopping\s+': 'mall ',
      r'plaza\s+': 'mall ',

      // Normalizar artículos
      r'\s+el\s+': ' ',
      r'\s+la\s+': ' ',
      r'\s+los\s+': ' ',
      r'\s+las\s+': ' ',
    };

    // Aplicar normalizaciones de frases
    for (var entry in phraseNormalizations.entries) {
      normalized = normalized.replaceAll(RegExp(entry.key), entry.value);
    }

    // Sinónimos y variaciones comunes para mejorar reconocimiento
    final synonyms = {
      'bus': ['autobus', 'micro', 'colectivo', 'omnibus'],
      'paradas': ['parada', 'paradero', 'estacion', 'terminal'],
      'orientacion': ['direccion', 'rumbo', 'hacia donde'],
      'ubicacion': ['posicion', 'lugar', 'donde estoy'],
      'ir a': [
        've a',
        'vamos a',
        'dirigete a',
        'navegar a',
        'llevarme a',
        'dirigirme a',
      ],
      'ayuda': ['auxilio', 'comandos', 'que puedo decir'],
      'repetir': ['repite', 'otra vez', 'de nuevo'],
      'actualizar': ['refrescar', 'recargar', 'renovar'],

      // Lugares comunes con sinónimos
      'mall': ['centro comercial', 'shopping', 'plaza'],
      'universidad': ['u', 'uni', 'universidad'],
      'hospital': ['clinica', 'centro medico'],
      'aeropuerto': ['terminal aereo'],
      'estacion': ['paradero', 'terminal', 'estacion de metro'],
    };

    // Aplicar sinónimos
    for (var entry in synonyms.entries) {
      for (var synonym in entry.value) {
        if (normalized.contains(synonym)) {
          normalized = normalized.replaceAll(synonym, entry.key);
        }
      }
    }

    // Limpiar espacios múltiples y palabras de relleno
    normalized = normalized
        .replaceAll(RegExp(r'\s+(por favor|porfavor|gracias|ahora|ya)\s*'), ' ')
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
    if (_currentPosition == null) {
      _showErrorNotification('No se puede calcular ruta sin ubicación actual');
      TtsService.instance.speak(
        'No se puede calcular ruta sin ubicación actual',
      );
      return;
    }

    // Activar viaje pero NO mostrar paradas automaticamente
    // (solo mostrar la ruta del bus en el mapa)
    setState(() {
      _hasActiveTrip = true;
      // NO activar _showStops - solo mostrar la ruta del bus
    });

    // Anunciar que se está calculando
    TtsService.instance.speak(
      'Buscando mejor ruta hacia $destination. Por favor espera.',
    );

    try {
      // Geocodificar destino usando el servicio de validación de direcciones
      final suggestions = await AddressValidationService.instance
          .suggestAddresses(destination, limit: 1);

      if (suggestions.isEmpty) {
        _showErrorNotification('No se encontró el destino: $destination');
        TtsService.instance.speak('No se encontró el destino $destination');
        return;
      }

      final firstResult = suggestions.first;
      final destLat = (firstResult['lat'] as num).toDouble();
      final destLon = (firstResult['lon'] as num).toDouble();

      // Calcular ruta usando Moovit
      final origin = LatLng(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
      );
      final destinationPoint = LatLng(destLat, destLon);

      final combinedRoute = await CombinedRoutesService.instance
          .calculatePublicTransitRoute(
            origin: origin,
            destination: destinationPoint,
          );

      // ACCESIBILIDAD: Anunciar ruta automáticamente e iniciar navegación
      await _announceAndStartNavigation(combinedRoute, destination);
    } catch (e) {
      _showErrorNotification('Error calculando ruta: ${e.toString()}');
      TtsService.instance.speak(
        'Error al calcular la ruta. Por favor intenta nuevamente.',
      );
    }
  }

  // Versión síncrona para usar con await
  Future<void> _loadNearbyStopsSync() async {
    if (_currentPosition == null) return;

    setState(() => _isLoadingStops = true);

    try {
      final apiClient = ApiClient();
      final stops = await apiClient.getNearbyStops(
        lat: _currentPosition!.latitude,
        lon: _currentPosition!.longitude,
        radius: 600,
        limit: 20,
      );

      if (!mounted) return;

      setState(() {
        _nearbyStops = stops;
        _isLoadingStops = false;
      });

      _updateStopMarkers();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingStops = false);
      rethrow; // Re-throw para que el método llamador pueda manejar el error
    }
  }

  /// Encuentra el paradero más cercano a una ubicación específica
  Future<Map<String, dynamic>?> _findNearestStopToLocation(
    double lat,
    double lon,
  ) async {
    try {
      final apiClient = ApiClient();

      // Buscar paradas cerca de la ubicación específica (mayor radio para encontrar más opciones)
      final stopsNearDestination = await apiClient.getNearbyStops(
        lat: lat,
        lon: lon,
        radius: 1500, // Radio más grande para encontrar más opciones
        limit: 50, // Más paradas para tener mejor selección
      );

      if (stopsNearDestination.isEmpty) {
        return null;
      }

      // Calcular distancias y encontrar el más cercano
      double minDistance = double.infinity;
      Map<String, dynamic>? nearestStop;

      for (var stop in stopsNearDestination) {
        final stopLat = stop['latitude'] as double?;
        final stopLon = stop['longitude'] as double?;

        if (stopLat == null || stopLon == null) continue;

        // Calcular distancia usando fórmula haversine
        final distance = _calculateDistance(lat, lon, stopLat, stopLon);

        if (distance < minDistance) {
          minDistance = distance;
          nearestStop = stop;
        }
      }

      return nearestStop;
    } catch (e) {
      print('Error buscando paradero más cercano: $e');
      return null;
    }
  }

  /// Calcula la distancia entre dos puntos usando la fórmula haversine (en metros)
  double _calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const double earthRadius = 6371000; // Radio de la Tierra en metros

    final double dLat = _toRadians(lat2 - lat1);
    final double dLon = _toRadians(lon2 - lon1);

    final double a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);

    final double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));

    return earthRadius * c;
  }

  /// Convierte grados a radianes
  double _toRadians(double degrees) {
    return degrees * (math.pi / 180);
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
    if (_currentPosition == null) {
      _showErrorNotification('No se puede calcular ruta sin ubicación actual');
      TtsService.instance.speak('No se puede obtener tu ubicación actual');
      return;
    }

    try {
      // Anunciar inicio de búsqueda
      TtsService.instance.speak('Buscando ruta hacia $destination');

      // Iniciar navegación integrada
      // Este servicio maneja: scraping Moovit, construcción de pasos,
      // geometrías separadas por paso, y anuncios TTS
      print('🗺️ [MAP] Antes de llamar startNavigation...');

      final navigation = await IntegratedNavigationService.instance
          .startNavigation(
            originLat: _currentPosition!.latitude,
            originLon: _currentPosition!.longitude,
            destLat: destLat,
            destLon: destLon,
            destinationName: destination,
          );

      print('🗺️ [MAP] startNavigation completado exitosamente');
      print('🗺️ [MAP] Navigation tiene ${navigation.steps.length} pasos');

      // ══════════════════════════════════════════════════════════════
      // CONFIGURAR CALLBACKS PARA ACTUALIZAR UI CUANDO CAMBIA EL PASO
      // ══════════════════════════════════════════════════════════════

      print('🗺️ [MAP] Configurando callbacks...');

      IntegratedNavigationService.instance.onStepChanged = (step) {
        if (!mounted) return;

        setState(() {
          _hasActiveTrip = true;

          // Actualizar polyline con geometría del paso ACTUAL únicamente
          // NOTA: NO dibujar polyline para pasos de bus (ride_bus), solo mostrar paraderos
          final stepGeometry =
              IntegratedNavigationService.instance.currentStepGeometry;

          if (step.type == 'ride_bus') {
            // Para buses: NO dibujar línea, solo mostrar paraderos como marcadores
            _polylines = [];
            print(
              '🚌 [BUS] No se dibuja polyline para ride_bus (solo paraderos)',
            );
          } else {
            // Para walk, wait_bus, etc: dibujar polyline normal
            _polylines = stepGeometry.isNotEmpty
                ? [
                    Polyline(
                      points: stepGeometry,
                      color: const Color(0xFFE30613), // Color Red
                      strokeWidth: 5.0,
                    ),
                  ]
                : [];
          }

          // Actualizar marcadores: solo paso actual + destino final
          final activeNav =
              IntegratedNavigationService.instance.activeNavigation;
          if (activeNav != null) {
            _updateNavigationMarkers(step, activeNav);
          }

          // Actualizar instrucciones: usar instrucciones detalladas de OSRM si están disponibles
          if (step.streetInstructions != null &&
              step.streetInstructions!.isNotEmpty) {
            _currentInstructions = [
              step.instruction, // Instrucción principal
              '', // Línea en blanco
              'Sigue estos pasos:', // Encabezado
              ...step.streetInstructions!, // Instrucciones detalladas por calle
            ];
            _currentInstructionStep = 0;
            print(
              '📝 Instrucciones detalladas actualizadas: ${step.streetInstructions!.length} pasos',
            );
          } else {
            // Fallback: solo instrucción principal
            _currentInstructions = [step.instruction];
            _currentInstructionStep = 0;
          }
        });

        // Anunciar nuevo paso y mostrar notificación
        _showNavigationNotification(step.instruction);
        print('📍 Paso actual: ${step.instruction}');

        // Si hay instrucciones detalladas, anunciar la primera
        if (step.streetInstructions != null &&
            step.streetInstructions!.isNotEmpty) {
          print('🗣️ Primera instrucción: ${step.streetInstructions!.first}');
        }
      };

      // Callback cuando llega a un paradero
      IntegratedNavigationService.instance.onArrivalAtStop = (stopId) {
        if (!mounted) return;
        print('✅ Llegaste al paradero: $stopId');

        // Vibración de confirmación
        Vibration.vibrate(duration: 500);
        _showSuccessNotification(
          'Has llegado al paradero',
          withVibration: true,
        );
      };

      IntegratedNavigationService.instance.onDestinationReached = () {
        if (!mounted) return;
        print('🎉 ¡Destino alcanzado!');

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
            print(
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
            print(
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
              print('🗺️ [AUTO-CENTER] Centrando en posición simulada');
            }
          }
        });
      };

      // Dibujar mapa inicial con geometría del primer paso
      setState(() {
        _hasActiveTrip = true;
        _selectedDestinationName = destination;

        print('🗺️ [MAP] Llamando _updateNavigationMapState...');

        // Configurar polyline y marcadores iniciales
        _updateNavigationMapState(navigation);

        print(
          '🗺️ [MAP] Polylines después de actualizar: ${_polylines.length}',
        );
        print('🗺️ [MAP] Markers después de actualizar: ${_markers.length}');
      });

      _showSuccessNotification(
        'Navegación iniciada. Duración estimada: ${navigation.estimatedDuration} minutos',
        withVibration: true,
      );
    } catch (e) {
      _showErrorNotification('Error al calcular la ruta: $e');
      TtsService.instance.speak('Error al calcular la ruta. Intenta de nuevo.');
      print('❌ Error en navegación integrada: $e');
    }
  }

  /// Actualiza el estado del mapa (polylines y marcadores) para la navegación activa
  void _updateNavigationMapState(ActiveNavigation navigation) {
    final stepGeometry =
        IntegratedNavigationService.instance.currentStepGeometry;

    print(
      '🗺️ [MAP] Actualizando mapa - Geometría: ${stepGeometry.length} puntos, Tipo: ${navigation.currentStep?.type}',
    );

    // Actualizar polyline del paso actual
    // NOTA: NO dibujar polyline para pasos de bus (ride_bus), solo mostrar paraderos
    if (navigation.currentStep?.type == 'ride_bus') {
      _polylines = [];
      print('🚌 [BUS] No se dibuja polyline para ride_bus (solo paraderos)');
    } else {
      _polylines = stepGeometry.isNotEmpty
          ? [
              Polyline(
                points: stepGeometry,
                color: const Color(0xFFE30613), // Color Red
                strokeWidth: 5.0,
              ),
            ]
          : [];
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
    final newMarkers = <Marker>[];

    // Marcador de la ubicación del usuario (azul, siempre visible)
    if (_currentPosition != null) {
      newMarkers.add(
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
                  color: Colors.blue.withOpacity(0.5),
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

    // Si estamos en wait_bus o ride_bus, re-crear marcadores de paradas
    if (currentStep?.type == 'wait_bus' || currentStep?.type == 'ride_bus') {
      try {
        final busLeg = navigation.itinerary.legs.firstWhere(
          (leg) => leg.type == 'bus' && leg.isRedBus,
          orElse: () => throw Exception('No bus leg found'),
        );

        final stops = busLeg.stops;
        if (stops != null && stops.isNotEmpty) {
          for (int i = 0; i < stops.length; i++) {
            final stop = stops[i];
            final isFirst = i == 0;
            final isLast = i == stops.length - 1;

            Color markerColor;
            IconData markerIcon;
            if (isFirst) {
              markerColor = Colors.green;
              markerIcon = Icons.location_on;
            } else if (isLast) {
              markerColor = Colors.red;
              markerIcon = Icons.flag;
            } else {
              markerColor = Colors.blue;
              markerIcon = Icons.circle;
            }

            newMarkers.add(
              Marker(
                point: stop.location,
                width: isFirst || isLast ? 40 : 24,
                height: isFirst || isLast ? 40 : 24,
                child: Container(
                  decoration: BoxDecoration(
                    color: markerColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: markerColor.withOpacity(0.5),
                        blurRadius: 6,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Icon(
                    markerIcon,
                    color: Colors.white,
                    size: isFirst || isLast ? 24 : 12,
                  ),
                ),
              ),
            );
          }
          print(
            '🗺️ [MARKERS] Re-creados ${stops.length} marcadores de paradas de bus',
          );
        }
      } catch (e) {
        print('⚠️ [MARKERS] Error obteniendo paradas de bus: $e');
      }
    }

    // Marcador del paso actual (paradero o punto de acción)
    // SOLO si NO es ride_bus (porque ya están los marcadores de paradas)
    if (currentStep?.location != null && currentStep!.type != 'ride_bus') {
      final Widget markerWidget;

      if (currentStep.type == 'walk' || currentStep.type == 'wait_bus') {
        // Icono de paradero de bus
        markerWidget = Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.orange,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.orange.withOpacity(0.5),
                blurRadius: 8,
                spreadRadius: 2,
              ),
            ],
          ),
          child: const Icon(
            Icons.directions_bus,
            color: Colors.white,
            size: 24,
          ),
        );
      } else {
        final (icon, color) = _getStepMarkerStyle(currentStep.type);
        markerWidget = Icon(icon, color: color, size: 30);
      }

      newMarkers.add(Marker(point: currentStep.location!, child: markerWidget));
    }

    // Marcador del destino final (siempre visible)
    final lastStep = navigation.steps.last;
    if (lastStep.location != null) {
      newMarkers.add(
        Marker(
          point: lastStep.location!,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.green,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: [
                BoxShadow(
                  color: Colors.green.withOpacity(0.5),
                  blurRadius: 8,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(Icons.flag, color: Colors.white, size: 24),
          ),
        ),
      );
    }

    // Actualizar marcadores
    _markers = newMarkers;
  }

  /// Retorna el icono y color apropiado para cada tipo de paso
  (IconData, Color) _getStepMarkerStyle(String stepType) {
    return switch (stepType) {
      'walk' => (Icons.directions_walk, Colors.blue),
      'wait_bus' => (Icons.directions_bus, Colors.orange),
      'ride_bus' => (Icons.drive_eta, Colors.red),
      'transfer' => (Icons.swap_horiz, Colors.purple),
      'arrival' => (Icons.flag, Colors.green),
      _ => (Icons.navigation, Colors.grey),
    };
  }

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

  /// Muestra información detallada del paradero con buses disponibles
  Future<void> _showStopDetailsWithBuses(
    Map<String, dynamic> stop,
    String destinationName,
  ) async {
    final stopId = stop['stop_id']?.toString() ?? stop['id']?.toString() ?? '';
    final stopName = stop['name'] as String? ?? 'Paradero sin nombre';

    // Obtener información de buses en tiempo real
    TtsService.instance.speak('Obteniendo información de buses para $stopName');

    try {
      final buses = await RedClScraperService.instance.getBusInfoForStop(
        stopId,
      );

      if (!mounted) return;

      await _showBusSelectionModal(stop, buses, destinationName);
    } catch (e) {
      _showErrorNotification('Error obteniendo información de buses');
    }
  }

  /// Muestra modal para seleccionar bus
  Future<void> _showBusSelectionModal(
    Map<String, dynamic> stop,
    List<BusInfo> buses,
    String destinationName,
  ) async {
    final stopName = stop['name'] as String? ?? 'Paradero';
    final stopId = stop['stop_id']?.toString() ?? stop['id']?.toString() ?? '';

    final selectedBus = await showModalBottomSheet<BusInfo?>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header simple como el de sugerencias
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.directions_bus,
                          color: Colors.blue,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            stopName,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close, size: 20),
                        ),
                      ],
                    ),
                    if (stopId.isNotEmpty)
                      Text(
                        'ID: $stopId',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                  ],
                ),
              ),

              // Información del destino
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Text(
                  'Buses disponibles hacia $destinationName',
                  style: const TextStyle(fontSize: 14, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ),

              const SizedBox(height: 8),

              // Lista de buses con el mismo estilo que sugerencias
              Flexible(
                child: buses.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(40),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 48,
                              color: Colors.grey,
                            ),
                            SizedBox(height: 12),
                            Text(
                              'No hay buses disponibles',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: buses.length,
                        separatorBuilder: (_, __) => const Divider(),
                        itemBuilder: (context, index) {
                          final bus = buses[index];
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: Theme.of(context).primaryColor,
                              radius: 16,
                              child: Text(
                                bus.route,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            title: Text(
                              'Bus ${bus.route}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 2),
                                Text(
                                  'Llega en ${bus.arrivalTimeMinutes} min',
                                  style: const TextStyle(
                                    color: Colors.green,
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  bus.destination,
                                  style: const TextStyle(
                                    color: Colors.blue,
                                    fontSize: 12,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                            trailing: const Icon(
                              Icons.arrow_forward_ios,
                              size: 16,
                            ),
                            onTap: () => Navigator.of(context).pop(bus),
                          );
                        },
                      ),
              ),

              // Botón cancelar como en sugerencias
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: const Text('Cancelar'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (selectedBus != null) {
      await _navigateToStopAndTrackBus(stop, selectedBus, destinationName);
    }
  }

  /// Navegar al paradero y hacer seguimiento del bus seleccionado
  Future<void> _navigateToStopAndTrackBus(
    Map<String, dynamic> stop,
    BusInfo selectedBus,
    String destinationName,
  ) async {
    final stopName = stop['name'] as String? ?? 'Paradero';
    final stopLat = stop['latitude'] as double;
    final stopLon = stop['longitude'] as double;

    TtsService.instance.speak(
      'Perfecto, te guiaré al $stopName para tomar el bus ${selectedBus.route} '
      'que llega en ${selectedBus.arrivalTimeMinutes} minutos hacia ${selectedBus.destination}',
    );

    // Calcular ruta al paradero
    try {
      await _calculateRoute(
        destLat: stopLat,
        destLon: stopLon,
        destName: stopName,
      );

      // Programar seguimiento del bus cuando llegue al paradero
      _scheduleArrivaltAtStop(stop, selectedBus, destinationName);
    } catch (e) {
      _showErrorNotification('Error calculando ruta al paradero');
    }
  }

  /// Programa acciones cuando llegue al paradero
  void _scheduleArrivaltAtStop(
    Map<String, dynamic> stop,
    BusInfo selectedBus,
    String destinationName,
  ) {
    // Aquí implementarías la lógica para detectar cuando el usuario llega al paradero
    // y comenzar el seguimiento del bus hacia el destino final

    Timer.periodic(const Duration(seconds: 10), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      // Verificar si el usuario está cerca del paradero (dentro de 50 metros)
      if (_currentPosition != null) {
        final stopLat = stop['latitude'] as double;
        final stopLon = stop['longitude'] as double;
        final distance = _calculateDistance(
          _currentPosition!.latitude,
          _currentPosition!.longitude,
          stopLat,
          stopLon,
        );

        if (distance <= 50) {
          // 50 metros de distancia
          timer.cancel();
          _handleArrivalAtStop(stop, selectedBus, destinationName);
        }
      }
    });
  }

  /// Maneja la llegada al paradero
  void _handleArrivalAtStop(
    Map<String, dynamic> stop,
    BusInfo selectedBus,
    String destinationName,
  ) {
    final stopName = stop['name'] as String? ?? 'Paradero';

    TtsService.instance.speak(
      '¡Has llegado al $stopName! '
      'El bus ${selectedBus.route} hacia ${selectedBus.destination} '
      'debería llegar en ${selectedBus.arrivalTimeMinutes} minutos. '
      'Te notificaré cuando esté cerca.',
    );

    _showSuccessNotification(
      'Llegaste al paradero $stopName',
      withVibration: true,
    );

    // Iniciar monitoreo de llegada del bus
    _startBusArrivalMonitoring(selectedBus, destinationName);
  }

  /// Inicia el monitoreo de llegada del bus
  void _startBusArrivalMonitoring(BusInfo selectedBus, String destinationName) {
    TtsService.instance.speak(
      'Monitoreando la llegada del bus ${selectedBus.route}. '
      'Te avisaré cuando esté por llegar.',
    );

    // Simular llegada del bus después del tiempo estimado
    Timer(Duration(minutes: selectedBus.arrivalTimeMinutes), () {
      if (!mounted) return;

      TtsService.instance.speak(
        '¡El bus ${selectedBus.route} está llegando! '
        'Prepárate para abordar. Te guiaré hacia $destinationName.',
      );

      _showNotification(
        NotificationData(
          message: 'Bus ${selectedBus.route} llegando al paradero',
          type: NotificationType.success,
          withVibration: true,
        ),
      );

      // Iniciar seguimiento hacia el destino final
      _startDestinationTracking(selectedBus, destinationName);
    });
  }

  /// Inicia el seguimiento hacia el destino final
  void _startDestinationTracking(BusInfo selectedBus, String destinationName) {
    TtsService.instance.speak(
      'Ahora te estoy siguiendo en el bus ${selectedBus.route} hacia $destinationName. '
      'Te avisaré cuando te acerques a tu destino.',
    );

    setState(() {
      _isTrackingRoute = true;
    });

    // Aquí podrías implementar lógica más sofisticada para:
    // 1. Seguir la ruta del bus en tiempo real
    // 2. Alertar cuando se acerque al destino
    // 3. Proporcionar instrucciones de bajada
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
      }

      TtsService.instance.speak(message);
      _announce('Ruta calculada exitosamente');

      // CAP-29 & CAP-30: Preguntar si quiere monitoreo de abordaje
      Timer(const Duration(seconds: 3), () {
        if (!mounted) return;
        _askForBoardingMonitoring();
      });
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

  /// CAP-29: Preguntar si quiere monitoreo de abordaje
  void _askForBoardingMonitoring() {
    TtsService.instance.speak(
      '¿Quieres que monitoree cuando abordes el bus? '
      'Di "monitorear abordaje" o "sí" para activarlo.',
    );
  }

  /// CAP-29: Iniciar monitoreo de abordaje (activado por voz)
  void _startBoardingMonitoring(String busRoute) {
    setState(() {
      _waitingBoardingConfirmation = true;
    });

    TransitBoardingService.instance.startMonitoring(expectedBusRoute: busRoute);

    _showNotification(
      NotificationData(
        message: 'Monitoreando abordaje del bus $busRoute',
        type: NotificationType.info,
        duration: const Duration(seconds: 5),
      ),
    );
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
  /// ACCESIBILIDAD: Anuncia ruta por TTS e inicia navegación automáticamente
  /// ACCESIBILIDAD: Anuncia ruta por TTS e inicia navegación automáticamente
  Future<void> _announceAndStartNavigation(
    CombinedRoute route,
    String destName,
  ) async {
    if (!mounted) return;

    // Extraer información de la ruta desde los segments
    final busSegments = route.segments
        .where((seg) => seg.mode == TransportMode.bus)
        .toList();

    if (busSegments.isEmpty) {
      final walkDuration = route.totalDuration.inMinutes;
      await TtsService.instance.speak(
        'No se encontró ruta en bus. Solo ruta caminando de $walkDuration minutos.',
        urgent: true,
      );
      return;
    }

    // Mostrar loading en el botón del micrófono
    setState(() {
      _isCalculatingRoute = true;
    });

    // Mostrar notificación visual simple
    _showSuccessNotification('Calculando ruta');

    // Iniciar navegación usando IntegratedNavigationService
    // El servicio se encargará de anunciar todo (resumen + primer paso)
    try {
      // Obtener coordenadas de inicio y destino desde los segments
      final firstSegment = route.segments.first;
      final lastSegment = route.segments.last;

      final originLat = firstSegment.startPoint.latitude;
      final originLon = firstSegment.startPoint.longitude;
      final destLat = lastSegment.endPoint.latitude;
      final destLon = lastSegment.endPoint.longitude;

      // Iniciar navegación integrada
      // Este método ya se encarga de anunciar el resumen y el primer paso
      print('🗺️ [ANNOUNCE_NAV] Llamando startNavigation...');
      final navigation = await IntegratedNavigationService.instance
          .startNavigation(
            originLat: originLat,
            originLon: originLon,
            destLat: destLat,
            destLon: destLon,
            destinationName: destName,
            existingItinerary:
                route.redBusItinerary, // ✅ Pasar itinerario ya obtenido
          );

      print(
        '🗺️ [ANNOUNCE_NAV] startNavigation completado, actualizando mapa...',
      );

      // ✅ Extraer instrucciones de caminata
      final currentStep = navigation.currentStep;
      if (currentStep?.streetInstructions != null &&
          currentStep!.streetInstructions!.isNotEmpty) {
        setState(() {
          _currentInstructions = currentStep.streetInstructions!;
          _currentInstructionStep = 0;
          // Solo mostrar panel si NO está en modo auto-lectura (para videntes)
          _showInstructionsPanel = !_autoReadInstructions;
        });
        print(
          '🗺️ [INSTRUCCIONES] Cargadas ${_currentInstructions.length} instrucciones',
        );

        // Para usuarios no videntes: anunciar que hay instrucciones disponibles
        if (_autoReadInstructions) {
          TtsService.instance.speak(
            'Ruta calculada con ${_currentInstructions.length} pasos. '
            'Di "todas las instrucciones" para escucharlas, '
            'o "siguiente paso" para avanzar.',
            urgent: true,
          );
        }
      }

      // ✅ ACTUALIZAR MAPA: Configurar callbacks y dibujar geometría del paso actual
      IntegratedNavigationService.instance.onStepChanged = (step) {
        print('🗺️ [CALLBACK] Paso cambiado a: ${step.type}');

        // Actualizar instrucciones si el nuevo paso tiene instrucciones de calle
        if (step.streetInstructions != null &&
            step.streetInstructions!.isNotEmpty) {
          setState(() {
            _currentInstructions = step.streetInstructions!;
            _currentInstructionStep = 0;
            // Solo mostrar panel si está en modo visual
            _showInstructionsPanel = !_autoReadInstructions;
          });

          // Anunciar cambio de paso para usuarios no videntes
          if (_autoReadInstructions && step.instruction.isNotEmpty) {
            TtsService.instance.speak(
              'Nuevo paso: ${step.instruction}',
              urgent: true,
            );
          }
        }

        setState(() {
          final activeNav =
              IntegratedNavigationService.instance.activeNavigation;
          if (activeNav != null) {
            _updateNavigationMapState(activeNav);
          }
        });
      };

      // Callback para actualizar geometría en tiempo real
      IntegratedNavigationService.instance.onGeometryUpdated = () {
        if (!mounted) return;

        setState(() {
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
          } else if (stepGeometry.isNotEmpty) {
            _polylines = [
              Polyline(
                points: stepGeometry,
                color: const Color(0xFFE30613), // Color Red
                strokeWidth: 5.0,
              ),
            ];
          }

          // Actualizar posición del usuario y marcadores
          final position = IntegratedNavigationService.instance.lastPosition;
          if (position != null) {
            _currentPosition = position;

            final activeNav =
                IntegratedNavigationService.instance.activeNavigation;
            if (activeNav != null && activeNav.currentStep != null) {
              _updateNavigationMarkers(activeNav.currentStep!, activeNav);
            }
          }
        });
      };

      setState(() {
        print('🗺️ [ANNOUNCE_NAV] Llamando _updateNavigationMapState...');
        _updateNavigationMapState(navigation);
        _isCalculatingRoute = false; // Terminar loading
      });

      print('🗺️ [ANNOUNCE_NAV] Mapa actualizado exitosamente');

      // NO llamar _displayCombinedRoute aquí porque IntegratedNavigationService
      // ya maneja el dibujo del mapa paso a paso según el progreso de la navegación
      // _displayCombinedRoute(route); // ❌ COMENTADO - causa conflicto
    } catch (e) {
      print('Error al iniciar navegación: $e');
      setState(() {
        _isCalculatingRoute = false; // Terminar loading en caso de error
      });
      await TtsService.instance.speak(
        'Error al iniciar navegación. Intenta nuevamente.',
        urgent: true,
      );
    }
  }

  Future<void> _showRouteWithItinerary(
    CombinedRoute route,
    String destName,
  ) async {
    if (!mounted) return;

    // Mostrar modal con el itinerario detallado
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: DraggableScrollableSheet(
            initialChildSize: 0.7,
            minChildSize: 0.5,
            maxChildSize: 0.95,
            expand: false,
            builder: (context, scrollController) {
              return Column(
                children: [
                  // Header
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            'Ruta hacia $destName',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 2,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  // Itinerario detallado
                  Expanded(
                    child: SingleChildScrollView(
                      controller: scrollController,
                      child: ItineraryDetails(route: route),
                    ),
                  ),
                  // Botón para iniciar navegación
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.navigation),
                        label: const Text('Iniciar Navegación'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        onPressed: () {
                          Navigator.of(context).pop();
                          _displayCombinedRoute(route);
                          _showSuccessNotification('Navegación iniciada');
                        },
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _showRouteOptions(
    List<CombinedRoute> routes,
    String destName,
  ) async {
    if (!mounted || routes.isEmpty) return;

    // Generar recomendaciones simples (ranked)
    final recommendations = RouteRecommendationService.instance.recommendRoutes(
      routes: routes,
      criteria: RecommendationCriteria.fastest,
    );

    // State inside modal: index focused
    int focusedIndex = 0;

    // Function to speak focused option
    void speakFocused(int idx) {
      if (idx < 0 || idx >= recommendations.length) return;
      final rec = recommendations[idx];
      final txt =
          'Opción ${rec.ranking}. ${rec.route.summary}. Duración ${rec.route.totalDuration.inMinutes} minutos.';
      TtsService.instance.speak(txt);
      _showNotification(
        NotificationData(
          message: 'Opción ${rec.ranking}: ${rec.route.summary}',
          type: NotificationType.info,
          duration: const Duration(seconds: 3),
        ),
      );
    }

    // Mostrar modal con lista de opciones y controles de navegación
    final choice = await showModalBottomSheet<int?>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (context, setModalState) {
              // Read the first option when opened
              WidgetsBinding.instance.addPostFrameCallback((_) {
                speakFocused(focusedIndex);
              });

              return Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Rutas hacia $destName',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () {
                            // Choose fastest automatically (first in recommendations)
                            Navigator.of(context).pop(0);
                          },
                          icon: const Icon(
                            Icons.flash_on,
                            color: Colors.orange,
                          ),
                          label: const Text('Elegir más rápida'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Elige la opción que prefieras',
                      style: const TextStyle(fontSize: 14),
                    ),
                    const SizedBox(height: 12),
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: recommendations.length,
                        separatorBuilder: (_, __) => const Divider(),
                        itemBuilder: (context, index) {
                          final rec = recommendations[index];
                          final route = rec.route;
                          final minutes = (route.totalDuration.inMinutes);
                          final distance = route.totalDistanceText;

                          final selected = index == focusedIndex;

                          return ListTile(
                            selected: selected,
                            selectedTileColor: Colors.blue.withOpacity(0.08),
                            leading: CircleAvatar(
                              child: Text('${rec.ranking}'),
                            ),
                            title: Text(rec.route.summary),
                            subtitle: Text(
                              'Duración: $minutes min · $distance',
                            ),
                            trailing: index == 0
                                ? const Icon(Icons.speed, color: Colors.green)
                                : null,
                            onTap: () {
                              Navigator.of(context).pop(index);
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () {
                            if (focusedIndex > 0) {
                              setModalState(() {
                                focusedIndex--;
                              });
                              speakFocused(focusedIndex);
                            }
                          },
                          icon: const Icon(Icons.arrow_back),
                          label: const Text('Anterior'),
                        ),
                        ElevatedButton.icon(
                          onPressed: () {
                            if (focusedIndex < recommendations.length - 1) {
                              setModalState(() {
                                focusedIndex++;
                              });
                              speakFocused(focusedIndex);
                            }
                          },
                          icon: const Icon(Icons.arrow_forward),
                          label: const Text('Siguiente'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(null),
                          child: const Text('Cancelar'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );

    if (choice == null) {
      TtsService.instance.speak('Selección cancelada');
      return;
    }

    final selected = recommendations[choice].route;
    TtsService.instance.speak(
      'Has seleccionado la opción ${recommendations[choice].ranking}',
    );

    // Mostrar la ruta seleccionada en el mapa
    _displayCombinedRoute(selected);
  }

  /// Dibuja una CombinedRoute en el mapa (polylines y marcadores)
  /// NOTA: NO dibuja polylines para segmentos de bus, solo para caminata
  void _displayCombinedRoute(CombinedRoute combined) {
    final newPolylines = <Polyline>[];
    final newMarkers = <Marker>[];

    for (var segment in combined.segments) {
      // SOLO dibujar polyline para segmentos de caminata (NO para buses)
      if (segment.mode == TransportMode.walk &&
          segment.geometry != null &&
          segment.geometry!.isNotEmpty) {
        newPolylines.add(
          Polyline(
            points: segment.geometry!,
            color: Colors.grey,
            strokeWidth: 3.0,
          ),
        );
      }
      // Para buses: NO dibujar polyline, los paraderos se muestran como marcadores

      // Add markers for stops/transfer points
      if (segment.stopName != null) {
        newMarkers.add(
          Marker(
            point: segment.startPoint,
            child: Icon(Icons.location_on, color: Colors.orange, size: 26),
          ),
        );
      }
    }

    // Ensure we keep user's location marker
    if (_currentPosition != null) {
      newMarkers.insert(
        0,
        Marker(
          point: LatLng(
            _currentPosition!.latitude,
            _currentPosition!.longitude,
          ),
          child: const Icon(Icons.my_location, color: Colors.blue, size: 30),
        ),
      );
    }

    setState(() {
      _polylines = newPolylines;
      _markers = newMarkers;
      _currentInstructions = combined.getVoiceInstructions();
      _currentInstructionStep = 0;
    });

    _showSuccessNotification('Ruta mostrada: ${combined.summary}');

    // Guardar la ruta seleccionada en el estado para la tarjeta persistente
    if (combined.segments.isNotEmpty) {
      final allPoints = combined.segments
          .expand((s) => s.geometry ?? <LatLng>[])
          .toList(growable: false);

      if (allPoints.isNotEmpty) {
        setState(() {
          _selectedCombinedRoute = combined;
          _selectedPlannedRoute = allPoints;
          _selectedDestinationName = combined.summary;
        });
      }
    }
  }

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
    if (_isCalculatingRoute) {
      return const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
          SizedBox(height: 12),
          Text(
            'Calculando ruta...',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          _isListening ? Icons.mic : Icons.mic_off,
          color: Colors.white,
          size: 48,
        ),

        // Mostrar instrucciones disponibles en modo audio
        if (_currentInstructions.isNotEmpty &&
            _autoReadInstructions &&
            !_isListening) ...[
          const SizedBox(height: 8),
          Text(
            '${_currentInstructions.length} pasos',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Text(
            'Presiona para hablar',
            style: TextStyle(color: Colors.white60, fontSize: 10),
          ),
        ],

        if (_currentPosition?.heading != null) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Transform.rotate(
                angle: _currentPosition!.heading * 3.14159 / 180,
                child: const Icon(
                  Icons.navigation,
                  color: Colors.white70,
                  size: 20,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${_currentPosition!.heading.toStringAsFixed(0)}°',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  void _startMicrophoneCalibration() async {
    if (_isListening) {
      _showWarningNotification('Detén la grabación antes de calibrar');
      return;
    }

    _showNotification(
      NotificationData(
        message: 'Iniciando calibración del micrófono...',
        type: NotificationType.info,
        duration: const Duration(seconds: 2),
      ),
    );

    TtsService.instance.speak(
      'Calibración iniciada. Di "Hola, mi nombre es" seguido de tu nombre. '
      'Esto ayudará a mejorar el reconocimiento de tu voz.',
    );

    // Esperar un momento para que el TTS termine
    await Future.delayed(const Duration(seconds: 4));

    // Iniciar una sesión de calibración
    try {
      setState(() {
        _isListening = true;
        _currentRecognizedText = '';
        _speechConfidence = 0.0;
      });

      await _speech.listen(
        onResult: (result) {
          if (!mounted) return;

          setState(() {
            _currentRecognizedText = result.recognizedWords;
            _speechConfidence = result.confidence;
          });

          if (result.finalResult) {
            _finishCalibration(result.recognizedWords, result.confidence);
          }
        },
        listenFor: const Duration(seconds: 10),
        pauseFor: const Duration(seconds: 2),
        localeId: 'es_ES',
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          listenMode: ListenMode.confirmation,
          sampleRate: 16000,
          enableHapticFeedback: true,
        ),
      );
    } catch (e) {
      setState(() {
        _isListening = false;
      });
      _showErrorNotification('Error durante la calibración: ${e.toString()}');
    }
  }

  void _finishCalibration(String recognizedText, double confidence) {
    setState(() {
      _isListening = false;
      _currentRecognizedText = '';
      _speechConfidence = 0.0;
    });

    if (confidence > 0.8) {
      _showSuccessNotification(
        'Calibración exitosa! Reconocimiento mejorado (${(confidence * 100).toInt()}%)',
        withVibration: true,
      );
      TtsService.instance.speak('Calibración completada con éxito');
    } else if (confidence > 0.6) {
      _showWarningNotification(
        'Calibración parcial. Intenta hablar más claro (${(confidence * 100).toInt()}%)',
      );
      TtsService.instance.speak(
        'Calibración parcial. Puedes intentar de nuevo',
      );
    } else {
      _showErrorNotification(
        'Calibración fallida. Verifica el micrófono (${(confidence * 100).toInt()}%)',
      );
      TtsService.instance.speak(
        'Calibración fallida. Verifica el micrófono y vuelve a intentar',
      );
    }

    // Guardar en historial para análisis futuro
    _recognitionHistory.add(
      'Calibración: "$recognizedText" - ${(confidence * 100).toInt()}%',
    );
  }

  @override
  void dispose() {
    _resultDebounce?.cancel();
    _feedbackTimer?.cancel();
    _confirmationTimer?.cancel();
    _walkSimulationTimer?.cancel(); // Cancelar simulación de caminata

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
      backgroundColor: Colors.grey[300],
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const SizedBox(),
        title: const Text(
          'WayFindCL',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          // Área del mapa
          Positioned.fill(
            child: _isLoadingLocation
                ? Container(
                    color: Colors.grey[300],
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Obteniendo ubicación...'),
                        ],
                      ),
                    ),
                  )
                : FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _currentPosition != null
                          ? LatLng(
                              _currentPosition!.latitude,
                              _currentPosition!.longitude,
                            )
                          : _initialPosition,
                      initialZoom: 14.0,
                      minZoom: 10.0,
                      maxZoom: 18.0,
                      initialRotation:
                          0.0, // Sin rotación para mejor rendimiento
                      onMapReady: () {
                        _isMapReady = true;

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
                      // Detectar cuando el usuario mueve el mapa manualmente
                      onPositionChanged: (position, hasGesture) {
                        if (hasGesture && _autoCenter) {
                          // Usuario movió el mapa con gesto -> desactivar auto-centrado
                          setState(() {
                            _userManuallyMoved = true;
                            _autoCenter = false;
                          });
                          print(
                            '🗺️ [MANUAL] Auto-centrado desactivado por gesto del usuario',
                          );
                        }
                      },
                      // Optimizaciones de rendimiento
                      keepAlive: true,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.wayfindcl',
                        maxZoom: 18,
                        // Optimizaciones de red
                        maxNativeZoom: 18,
                        retinaMode: false,
                      ),
                      if (_polylines.isNotEmpty)
                        PolylineLayer(polylines: _polylines),
                      if (_markers.isNotEmpty) MarkerLayer(markers: _markers),
                    ],
                  ),
          ),

          // Botón de TEST: Simular llegada al paradero o bus
          Positioned(
            left: 20,
            bottom: 400,
            child: GestureDetector(
              onTap: _simulateArrivalAtStop,
              child: Container(
                width: 60,
                height: 80,
                decoration: BoxDecoration(
                  color:
                      IntegratedNavigationService.instance.activeNavigation !=
                          null
                      ? Colors.green
                      : Colors.grey,
                  borderRadius: const BorderRadius.all(Radius.circular(10)),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 4,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.bug_report, color: Colors.white, size: 28),
                    const SizedBox(height: 4),
                    Text(
                      _getTestButtonLabel(),
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const Text(
                      'Simular',
                      style: TextStyle(fontSize: 8, color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Tarjeta persistente para la ruta seleccionada
          if (_selectedCombinedRoute != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 20,
              child: Card(
                elevation: 8,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _selectedDestinationName ?? 'Ruta seleccionada',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(_selectedCombinedRoute!.summary),
                          ],
                        ),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          // Iniciar seguimiento con la ruta seleccionada
                          if (_selectedPlannedRoute.isNotEmpty) {
                            final dest = _selectedPlannedRoute.last;
                            RouteTrackingService.instance.startTracking(
                              plannedRoute: _selectedPlannedRoute,
                              destination: dest,
                              destinationName:
                                  _selectedDestinationName ?? 'destino',
                            );
                            setState(() {
                              _isTrackingRoute = true;
                            });
                          }
                        },
                        child: const Text('Iniciar seguimiento'),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _selectedCombinedRoute = null;
                            _selectedPlannedRoute = [];
                            _selectedDestinationName = null;
                            _polylines = [];
                            _markers = [];
                          });
                        },
                        child: const Text('Cerrar'),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Botón de centrar ubicación
          Positioned(
            right: 20,
            bottom: 490, // Movido más arriba desde 340 a 490
            child: GestureDetector(
              onTap: _centerOnUserLocation,
              child: Container(
                width: 50,
                height: 50,
                decoration: const BoxDecoration(
                  color: Colors.blue,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 4,
                      offset: Offset(0, 2),
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

          // Botón de configuración (derecha)
          Positioned(
            right: 20,
            bottom: 400, // Movido más arriba desde 280 a 430
            child: GestureDetector(
              onTap: () => Navigator.pushNamed(context, '/settings'),
              child: Container(
                width: 50,
                height: 50,
                decoration: const BoxDecoration(
                  color: Colors.black,
                  shape: BoxShape.rectangle,
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 4,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.settings,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ),
          ),

          // Panel de instrucciones detalladas (OSRM)
          if (_hasActiveTrip)
            Positioned(
              left: 12,
              right: 12,
              bottom: 180,
              child: _buildInstructionsPanel(),
            ),

          // Panel inferior
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Handle del panel
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[400],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Texto dinámico según estado
                  Column(
                    children: [
                      Text(
                        _statusMessage(),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: _isListening ? Colors.blue : Colors.black,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),

                      // Indicador de confianza cuando está escuchando
                      if (_isListening && _speechConfidence > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Column(
                            children: [
                              Text(
                                'Confianza: ${(_speechConfidence * 100).toInt()}%',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _speechConfidence > 0.7
                                      ? Colors.green
                                      : _speechConfidence > 0.5
                                      ? Colors.orange
                                      : Colors.red,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              SizedBox(
                                width: 150,
                                child: LinearProgressIndicator(
                                  value: _speechConfidence,
                                  backgroundColor: Colors.grey[300],
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    _speechConfidence > 0.7
                                        ? Colors.green
                                        : _speechConfidence > 0.5
                                        ? Colors.orange
                                        : Colors.red,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                      // Indicador de procesamiento
                      if (_isProcessingCommand)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Procesando comando...',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.blue,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Botón del micrófono (con instrucciones de caminata integradas)
                  Semantics(
                    label: _isListening
                        ? 'Botón micrófono, escuchando'
                        : 'Botón micrófono, no escuchando',
                    hint: _isListening
                        ? 'Toca para detener'
                        : 'Toca para iniciar',
                    button: true,
                    enabled: true,
                    child: GestureDetector(
                      onTap: _toggleMicrophone,
                      onLongPress: _showWalkingInstructions,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        width: double.infinity,
                        height: 120,
                        decoration: BoxDecoration(
                          color: _isCalculatingRoute
                              ? Colors.blue.shade700
                              : _isListening
                              ? Colors.red
                              : Colors.black,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: _isListening
                              ? [
                                  BoxShadow(
                                    color: Colors.red.withValues(alpha: 0.3),
                                    blurRadius: 20,
                                    spreadRadius: 5,
                                  ),
                                ]
                              : _isCalculatingRoute
                              ? [
                                  BoxShadow(
                                    color: Colors.blue.withValues(alpha: 0.3),
                                    blurRadius: 20,
                                    spreadRadius: 5,
                                  ),
                                ]
                              : null,
                        ),
                        child: _buildMicrophoneContent(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Panel expandible de instrucciones de caminata
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    child:
                        _showInstructionsPanel &&
                            _currentInstructions.isNotEmpty
                        ? Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Colors.blue.shade600,
                                  Colors.blue.shade800,
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.blue.withValues(alpha: 0.3),
                                  blurRadius: 15,
                                  offset: const Offset(0, 5),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Row(
                                      children: [
                                        Icon(
                                          Icons.directions_walk,
                                          color: Colors.white,
                                          size: 24,
                                        ),
                                        SizedBox(width: 8),
                                        Text(
                                          'Instrucciones',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                    GestureDetector(
                                      onTap: () {
                                        setState(() {
                                          _showInstructionsPanel = false;
                                        });
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.all(4),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(
                                            alpha: 0.2,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.close,
                                          color: Colors.white,
                                          size: 20,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                ListView.builder(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  itemCount: _currentInstructions.length,
                                  itemBuilder: (context, index) {
                                    final instruction =
                                        _currentInstructions[index];
                                    final isFirst = index == 0;
                                    return GestureDetector(
                                      onTap: () {
                                        TtsService.instance.speak(instruction);
                                      },
                                      child: Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 12,
                                        ),
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: isFirst
                                              ? Colors.yellow.shade700
                                              : Colors.white.withValues(
                                                  alpha: 0.15,
                                                ),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          border: Border.all(
                                            color: isFirst
                                                ? Colors.yellow.shade900
                                                : Colors.white.withValues(
                                                    alpha: 0.3,
                                                  ),
                                            width: 2,
                                          ),
                                        ),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Container(
                                              width: 28,
                                              height: 28,
                                              decoration: BoxDecoration(
                                                color: isFirst
                                                    ? Colors.yellow.shade900
                                                    : Colors.white.withValues(
                                                        alpha: 0.3,
                                                      ),
                                                shape: BoxShape.circle,
                                              ),
                                              child: Center(
                                                child: Text(
                                                  '${index + 1}',
                                                  style: TextStyle(
                                                    color: isFirst
                                                        ? Colors.white
                                                        : Colors.white,
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Text(
                                                instruction,
                                                style: TextStyle(
                                                  color: isFirst
                                                      ? Colors.black87
                                                      : Colors.white,
                                                  fontSize: 15,
                                                  fontWeight: isFirst
                                                      ? FontWeight.w600
                                                      : FontWeight.w500,
                                                  height: 1.3,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Icon(
                                              Icons.volume_up,
                                              color: isFirst
                                                  ? Colors.black54
                                                  : Colors.white70,
                                              size: 20,
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),

                  // Botón de calibración del micrófono
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      GestureDetector(
                        onTap: _startMicrophoneCalibration,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey[200],
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.grey[400]!),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.tune, size: 16, color: Colors.grey),
                              SizedBox(width: 4),
                              Text(
                                'Calibrar micrófono',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Barra de navegación inferior
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
                        case 2:
                          Navigator.pushNamed(
                            context,
                            ContributeScreen.routeName,
                          );
                          break;
                        case 3:
                          Navigator.pushNamed(
                            context,
                            SettingsScreen.routeName,
                          );
                          break;
                      }
                    },
                  ),

                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),

          // Sistema de notificaciones
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Column(
                children: _activeNotifications.map((notification) {
                  return AccessibleNotification(
                    key: ValueKey(notification.hashCode),
                    notification: notification,
                    onDismiss: () => _dismissNotification(notification),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
