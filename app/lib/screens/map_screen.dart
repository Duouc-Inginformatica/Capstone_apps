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
import '../services/device/tts_service.dart';
import '../services/backend/api_client.dart';
import '../services/backend/address_validation_service.dart';
import '../services/navigation/route_tracking_service.dart';
import '../services/navigation/transit_boarding_service.dart';
import '../services/navigation/integrated_navigation_service.dart';
import '../services/backend/geometry_service.dart';
import '../services/device/npu_detector_service.dart';
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
    developer.log(
      message,
      name: 'MapScreen',
      error: error,
      stackTrace: stackTrace,
    );
  }

  bool _isListening = false;
  String _lastWords = '';
  final SpeechToText _speech = SpeechToText();
  bool _speechEnabled = false;
  Timer? _resultDebounce;
  String _pendingWords = '';
  String? _pendingDestination;

  bool _npuAvailable = false;
  bool _npuLoading = false;
  bool _npuChecked = false;

  // Mejoras de reconocimiento de voz
  double _speechConfidence = 0.0;
  String _currentRecognizedText = '';
  bool _isProcessingCommand = false;
  Timer? _speechTimeoutTimer;
  final List<String> _recognitionHistory = [];
  static const Duration _speechTimeout = Duration(seconds: 5);

  // Trip state - solo mostrar información adicional cuando hay viaje activo
  bool _hasActiveTrip = false;

  // CAP-9: Confirmación de destino
  String? _pendingConfirmationDestination;
  Timer? _confirmationTimer;

  // CAP-12: Instrucciones de ruta
  List<String> _currentInstructions = [];
  int _currentInstructionStep = 0;
  int _instructionFocusIndex = 0;
  bool _isCalculatingRoute = false;
  bool _showInstructionsPanel = false;

  // Lectura automática de instrucciones
  bool _autoReadInstructions = true; // Por defecto ON para no videntes

  // CAP-29: Confirmación de micro abordada
  bool _waitingBoardingConfirmation = false;

  // CAP-20 & CAP-30: Seguimiento en tiempo real
  bool _isTrackingRoute = false;

  // Accessibility features
  Timer? _feedbackTimer;

  // Auto-center durante navegación
  bool _autoCenter = true; // Por defecto activado
  bool _userManuallyMoved = false; // Detecta si el usuario movió el mapa

  // Simulación de caminata
  bool _isSimulatingWalk = false;

  // Sistema de brújula y orientación
  double _currentHeading = 0.0; // Orientación actual del dispositivo
  double _deviceHeading = 0.0; // Heading del dispositivo para guía contextual
  StreamSubscription<CompassEvent>? _compassSubscription;
  DateTime? _lastOrientationAnnouncement;

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
    _initializeNpuDetection();
    // Usar post-frame callback para evitar bloquear la construcción del widget
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initServices();
      _setupTrackingCallbacks();
      _setupBoardingCallbacks();
      _setupCompass(); // Configurar brújula
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

  Future<void> _initializeNpuDetection() async {
    setState(() {
      _npuLoading = true;
      _npuChecked = false;
    });

    try {
      final capabilities = await NpuDetectorService.instance
          .detectCapabilities();
      if (!mounted) return;
      setState(() {
        _npuAvailable = capabilities.hasNnapi;
        _npuLoading = false;
        _npuChecked = true;
      });
    } catch (e, st) {
      if (!mounted) return;
      _log('⚠️ [MAP] Error detectando NPU: $e', error: e, stackTrace: st);
      setState(() {
        _npuAvailable = false;
        _npuLoading = false;
        _npuChecked = true;
      });
    }
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

    final instructions = currentStep.streetInstructions!;
    final int focusIndex = instructions.isEmpty
        ? 0
        : _instructionFocusIndex < 0
        ? 0
        : _instructionFocusIndex >= instructions.length
        ? instructions.length - 1
        : _instructionFocusIndex;

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
                itemCount: instructions.length,
                itemBuilder: (context, index) {
                  final instruction = instructions[index];
                  final bool isFocused = index == focusIndex;
                  final bool isCompleted = index < focusIndex;

                  return InkWell(
                    onTap: () {
                      _focusOnInstruction(index);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: isFocused
                            ? Colors.white.withValues(alpha: 0.18)
                            : isCompleted
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.transparent,
                        border: Border(
                          left: BorderSide(
                            color: isFocused
                                ? Colors.yellow
                                : isCompleted
                                ? Colors.greenAccent
                                : Colors.white30,
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
                              color: isFocused
                                  ? Colors.yellow
                                  : isCompleted
                                  ? const Color(0xFF34D399)
                                  : Colors.white24,
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(
                                '${index + 1}',
                                style: TextStyle(
                                  color: isFocused || isCompleted
                                      ? Colors.black
                                      : Colors.white,
                                  fontWeight: isFocused
                                      ? FontWeight.w700
                                      : FontWeight.bold,
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
                                color: isFocused
                                    ? Colors.white
                                    : Colors.white.withValues(alpha: 0.9),
                                fontSize: 15,
                                height: 1.4,
                                fontWeight: isFocused
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                          if (isFocused)
                            const Icon(
                              Icons.navigation_rounded,
                              color: Colors.yellow,
                              size: 22,
                            )
                          else if (isCompleted)
                            const Icon(
                              Icons.check_circle,
                              color: Color(0xFF34D399),
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

  Widget _buildNavigationQuickActions(bool hasActiveNavigation) {
    final instructions = _getActiveWalkInstructions();
    final bool hasWalkInstructions =
        instructions != null && instructions.isNotEmpty;

    if (!hasActiveNavigation && !hasWalkInstructions) {
      return const SizedBox.shrink();
    }

    final int totalInstructions = instructions?.length ?? 0;
    final int focusIndex = totalInstructions == 0
        ? 0
        : _instructionFocusIndex < 0
        ? 0
        : _instructionFocusIndex >= totalInstructions
        ? totalInstructions - 1
        : _instructionFocusIndex;

    final String preview = totalInstructions == 0
        ? 'Inicia una navegación para ver instrucciones detalladas.'
        : instructions![focusIndex];

    final List<Widget> actionButtons = [];
    if (hasWalkInstructions) {
      actionButtons.add(
        _buildQuickActionButton(
          icon: Icons.record_voice_over,
          label: 'Leer paso',
          description: 'Paso ${focusIndex + 1} de $totalInstructions',
          onTap: _speakFocusedInstruction,
          primary: false,
          width: 160,
        ),
      );
    }

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 280),
      opacity: hasActiveNavigation ? 1.0 : 0.8,
      child: Container(
        constraints: BoxConstraints(maxWidth: hasWalkInstructions ? 320 : 240),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 18,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (actionButtons.isNotEmpty)
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: actionButtons,
              ),
            if (hasWalkInstructions) ...[
              if (actionButtons.isNotEmpty) const SizedBox(height: 12),
              Text(
                'Paso ${focusIndex + 1} de $totalInstructions',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                preview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.3,
                  color: Color(0xFF4B5563),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildMiniActionButton(
                    icon: Icons.chevron_left,
                    label: 'Anterior',
                    onTap: focusIndex > 0
                        ? () => _moveInstructionFocus(-1)
                        : null,
                  ),
                  const SizedBox(width: 8),
                  _buildMiniActionButton(
                    icon: Icons.chevron_right,
                    label: 'Siguiente',
                    onTap: focusIndex < totalInstructions - 1
                        ? () => _moveInstructionFocus(1)
                        : null,
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 4),
              Text(
                preview,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: Color(0xFF4B5563),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

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
        _log('🚌 [TEST] Simulando llegada del bus');

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

    if (stops.length < 2) {
      _log('⚠️ [BUS_SIM] Ruta insuficiente (${stops.length} puntos)');
      TtsService.instance.speak('No hay ruta de bus disponible para simular');
      return;
    }

    _log('🚌 [BUS_SIM] Navegación en bus con GPS real');
    
    // La navegación en bus usa GPS real del dispositivo
    // El listener GPS ya configurado en _setupGPSListener() detectará
    // automáticamente cuando el usuario se acerca a cada parada
    
    TtsService.instance.speak('Sube al bus. Te avisaré cuando llegues a tu parada.');
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

    _log('🚶 [SIMULATOR] Iniciando simulación realista de caminata');
    _log('� [SIMULATOR] Puntos de ruta: ${stepGeometry.length}');

    setState(() {
      _isSimulatingWalk = true;
    });

    TtsService.instance.speak('Iniciando simulación de caminata');
    _showSuccessNotification('Simulación de caminata iniciada');

    int currentWaypointIndex = 0;
    LatLng currentSimulatedPosition = stepGeometry[0];

    // Simulador realista: actualización cada 1 segundo con velocidad variable
    _walkSimulationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || currentWaypointIndex >= stepGeometry.length - 1) {
        timer.cancel();
        _walkSimulationTimer = null;
        
        if (mounted) {
          setState(() {
            _isSimulatingWalk = false;
          });
          
          _log('✅ [SIMULATOR] Simulación de caminata completada');
          TtsService.instance.speak('Has llegado al destino');
          _showSuccessNotification('Simulación completada');
        }
        return;
      }

      final targetWaypoint = stepGeometry[currentWaypointIndex + 1];
      
      // Calcular distancia al siguiente waypoint
      final distanceToTarget = Geolocator.distanceBetween(
        currentSimulatedPosition.latitude,
        currentSimulatedPosition.longitude,
        targetWaypoint.latitude,
        targetWaypoint.longitude,
      );

      // Velocidad de caminata realista: 1.2-1.5 m/s (4.3-5.4 km/h)
      final random = math.Random();
      final walkingSpeed = 1.2 + (random.nextDouble() * 0.3); // Variable entre pasos

      if (distanceToTarget <= walkingSpeed) {
        // Alcanzamos el waypoint, avanzar al siguiente
        currentWaypointIndex++;
        currentSimulatedPosition = stepGeometry[currentWaypointIndex];
        _log('📍 [SIMULATOR] Waypoint $currentWaypointIndex/${stepGeometry.length}');
      } else {
        // Calcular bearing hacia el siguiente waypoint
        final bearing = Geolocator.bearingBetween(
          currentSimulatedPosition.latitude,
          currentSimulatedPosition.longitude,
          targetWaypoint.latitude,
          targetWaypoint.longitude,
        );

        // Mover hacia el waypoint
        final newPosition = _calculateNewPosition(
          currentSimulatedPosition,
          bearing,
          walkingSpeed,
        );
        currentSimulatedPosition = newPosition;
      }

      // Actualizar posición simulada
      if (mounted) {
        setState(() {
          _currentPosition = Position(
            latitude: currentSimulatedPosition.latitude,
            longitude: currentSimulatedPosition.longitude,
            timestamp: DateTime.now(),
            accuracy: 5.0,
            altitude: 0.0,
            altitudeAccuracy: 0.0,
            heading: 0.0,
            headingAccuracy: 0.0,
            speed: walkingSpeed,
            speedAccuracy: 0.0,
          );
        });

        _updateCurrentLocationMarker();

        // Auto-centrar en la posición actual si está habilitado
        if (_autoCenter && !_userManuallyMoved) {
          _moveMap(currentSimulatedPosition, _mapController.camera.zoom);
        }
      }
    });
  }

  // Calcular nueva posición dado bearing y distancia
  LatLng _calculateNewPosition(LatLng start, double bearing, double distanceMeters) {
    const double earthRadius = 6371000; // metros
    final double lat1 = start.latitude * math.pi / 180;
    final double lon1 = start.longitude * math.pi / 180;
    final double bearingRad = bearing * math.pi / 180;

    final double lat2 = math.asin(
      math.sin(lat1) * math.cos(distanceMeters / earthRadius) +
      math.cos(lat1) * math.sin(distanceMeters / earthRadius) * math.cos(bearingRad)
    );

    final double lon2 = lon1 + math.atan2(
      math.sin(bearingRad) * math.sin(distanceMeters / earthRadius) * math.cos(lat1),
      math.cos(distanceMeters / earthRadius) - math.sin(lat1) * math.sin(lat2)
    );

    return LatLng(lat2 * 180 / math.pi, lon2 * 180 / math.pi);
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
      String label = '';

      if (isFirst) {
        // 🟢 PARADERO DE SUBIDA (verde brillante con icono de bus)
        markerColor = const Color(0xFF4CAF50); // Verde Material
        markerIcon = Icons.directions_bus; // Icono de bus
        markerSize = 52;
        label = 'SUBIDA';
      } else if (isLast) {
        // 🔴 PARADERO DE BAJADA (rojo con icono de bus)
        markerColor = const Color(0xFFE30613); // Rojo RED
        markerIcon = Icons.directions_bus; // Icono de bus
        markerSize = 52;
        label = 'BAJADA';
      } else {
        // 🔵 PARADEROS INTERMEDIOS (azul con icono de bus alert)
        markerColor = const Color(0xFF2196F3); // Azul Material
        markerIcon = Icons.bus_alert; // Icono de bus intermedio
        markerSize = 36;
        label = 'P$i'; // Parada número
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
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                  BoxShadow(
                    color: markerColor.withValues(alpha: 0.5),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Center(
                child: Icon(
                  markerIcon,
                  color: Colors.white,
                  size: markerSize * 0.65,
                ),
              ),
            ),
            // Etiqueta con código de parada y descripción mejorada
            if (stop.code != null && stop.code!.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 3),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.90),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: markerColor,
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: markerColor,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      stop.code!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
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

      // Configurar listener de GPS en tiempo real
      _setupGPSListener();
    } catch (e) {
      if (!mounted) return;
      TtsService.instance.speak('Error obteniendo ubicación');
    }
  }

  /// Configura el listener de brújula para rotación del mapa
  void _setupCompass() {
    _compassSubscription = FlutterCompass.events?.listen((CompassEvent event) {
      if (!mounted) return;

      final heading = event.heading;
      if (heading == null) return;

      setState(() {
        _currentHeading = heading;
        _deviceHeading = heading; // Guardar para guía contextual
      });

      // Rotar el mapa según la orientación del dispositivo
      if (_isMapReady && _autoCenter && !_userManuallyMoved) {
        _mapController.rotate(-heading); // Negativo porque norte es 0°
        _log('🧭 [COMPASS] Heading: ${heading.toStringAsFixed(1)}°');
      }
    });

    _log('🧭 [COMPASS] Sistema de brújula inicializado');
  }

  /// Configura el listener de GPS para navegación en tiempo real
  void _setupGPSListener() {
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5, // Actualizar cada 5 metros
    );

    Geolocator.getPositionStream(locationSettings: locationSettings).listen(
      (Position position) {
        // 🚫 Ignorar GPS real si estamos simulando
        if (_isSimulatingWalk) {
          _log('🚫 [GPS] Ignorando actualización GPS (simulación activa)');
          return;
        }

        if (!mounted) return;

        setState(() {
          _currentPosition = position;
        });

        _updateCurrentLocationMarker();

        // Auto-centrar si está habilitado
        if (_autoCenter && !_userManuallyMoved) {
          _moveMap(
            LatLng(position.latitude, position.longitude),
            _mapController.camera.zoom,
          );
        }

        // Verificar llegada a waypoint si hay navegación activa
        _checkArrivalAtWaypoint(position);
      },
      onError: (error) {
        _log('❌ [GPS] Error en stream de ubicación: $error', error: error);
      },
    );
  }

  /// Verifica si el usuario llegó a un waypoint de la ruta
  void _checkArrivalAtWaypoint(Position currentPos) {
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    if (activeNav == null || activeNav.isComplete) return;

    final currentStep = activeNav.steps[activeNav.currentStepIndex];
    
    // Solo verificar en pasos de caminata
    if (currentStep.type != 'walk') return;

    final stepGeometry = IntegratedNavigationService.instance.currentStepGeometry;
    if (stepGeometry.isEmpty) return;

    // Obtener el waypoint destino del paso actual
    final targetWaypoint = stepGeometry.last;
    
    final distanceToTarget = Geolocator.distanceBetween(
      currentPos.latitude,
      currentPos.longitude,
      targetWaypoint.latitude,
      targetWaypoint.longitude,
    );

    // Proporcionar guía contextual según distancia
    _provideContextualGuidance(currentPos, currentStep, distanceToTarget);

    // Umbral de llegada: 15 metros
    const double arrivalThreshold = 15.0;

    if (distanceToTarget <= arrivalThreshold) {
      _log('✅ [GPS] Llegada a waypoint detectada (${distanceToTarget.toStringAsFixed(1)}m)');
      
      // Anunciar llegada
      TtsService.instance.speak('Has llegado al waypoint');
      _showSuccessNotification('Waypoint alcanzado');

      // Avanzar al siguiente paso si es posible
      if (activeNav.currentStepIndex < activeNav.steps.length - 1) {
        Future.delayed(const Duration(seconds: 2), () {
          IntegratedNavigationService.instance.advanceToNextStep();
          if (mounted) {
            setState(() {
              _updateNavigationMapState(activeNav);
            });
          }
        });
      }
    }
  }

  /// Proporcionar guía contextual según posición y orientación
  /// "Camina hacia adelante", "Gira a la derecha", "Sigue recto"
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

  /// Normaliza ángulo a rango -180 a 180
  double _normalizeAngle(double angle) {
    while (angle > 180) {
      angle -= 360;
    }
    while (angle < -180) {
      angle += 360;
    }
    return angle;
  }

  /// Obtiene dirección relativa basada en diferencia de heading
  String _getRelativeDirection(double headingDiff) {
    if (headingDiff.abs() < 15) {
      return 'recto adelante';
    } else if (headingDiff > 15 && headingDiff < 45) {
      return 'ligeramente a la derecha';
    } else if (headingDiff >= 45 && headingDiff < 135) {
      return 'a la derecha';
    } else if (headingDiff >= 135) {
      return 'gira completamente a la derecha';
    } else if (headingDiff < -15 && headingDiff > -45) {
      return 'ligeramente a la izquierda';
    } else if (headingDiff <= -45 && headingDiff > -135) {
      return 'a la izquierda';
    } else {
      return 'gira completamente a la izquierda';
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
  void _repeatCurrentInstruction() {
    if (_currentInstructions.isEmpty) {
      TtsService.instance.speak('No hay instrucciones disponibles');
      return;
    }

    final step = _currentInstructionStep > 0 ? _currentInstructionStep - 1 : 0;

    if (step < _currentInstructions.length) {
      final instruction = _currentInstructions[step];
      _focusOnInstruction(step, speak: false);
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

  /// CAP-20: Recalcular ruta desde posición actual
  Future<void> _recalculateRoute() async {
    if (_currentPosition == null ||
        RouteTrackingService.instance.destination == null) {
      return;
    }

    final dest = RouteTrackingService.instance.destination!;
    final destName = RouteTrackingService.instance.destinationName ?? 'destino';

    setState(() => _isCalculatingRoute = true); // 🔄 Mostrar indicador
    
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
    } finally {
      setState(() => _isCalculatingRoute = false); // ✅ Ocultar indicador
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
      _isCalculatingRoute = true; // 🔄 Mostrar indicador de carga
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
        setState(() => _isCalculatingRoute = false); // ❌ Ocultar indicador
        _showErrorNotification('No se encontró el destino: $destination');
        TtsService.instance.speak('No se encontró el destino $destination');
        return;
      }

      final firstResult = suggestions.first;
      final destLat = (firstResult['lat'] as num).toDouble();
      final destLon = (firstResult['lon'] as num).toDouble();

      // Iniciar navegación directamente usando IntegratedNavigationService
      await _startIntegratedMoovitNavigation(destination, destLat, destLon);
      
      setState(() => _isCalculatingRoute = false); // ✅ Ocultar indicador al finalizar
    } catch (e) {
      setState(() => _isCalculatingRoute = false); // ❌ Ocultar indicador en error
      _showErrorNotification('Error calculando ruta: ${e.toString()}');
      TtsService.instance.speak(
        'Error al calcular la ruta. Por favor intenta nuevamente.',
      );
    }
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
      _log('🗺️ [MAP] Antes de llamar startNavigation...');

      final navigation = await IntegratedNavigationService.instance
          .startNavigation(
            originLat: _currentPosition!.latitude,
            originLon: _currentPosition!.longitude,
            destLat: destLat,
            destLon: destLon,
            destinationName: destination,
          );

      _log('🗺️ [MAP] startNavigation completado exitosamente');
      _log('🗺️ [MAP] Navigation tiene ${navigation.steps.length} pasos');

      // ══════════════════════════════════════════════════════════════
      // CONFIGURAR CALLBACKS PARA ACTUALIZAR UI CUANDO CAMBIA EL PASO
      // ══════════════════════════════════════════════════════════════

      _log('🗺️ [MAP] Configurando callbacks...');

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
            _log(
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
    } catch (e) {
      _showErrorNotification('Error al calcular la ruta: $e');
      TtsService.instance.speak('Error al calcular la ruta. Intenta de nuevo.');
      _log('❌ Error en navegación integrada: $e');
    }
  }

  /// Actualiza el estado del mapa (polylines y marcadores) para la navegación activa
  void _updateNavigationMapState(ActiveNavigation navigation) {
    final stepGeometry =
        IntegratedNavigationService.instance.currentStepGeometry;

    _log(
      '🗺️ [MAP] Actualizando mapa - Geometría: ${stepGeometry.length} puntos, Tipo: ${navigation.currentStep?.type}',
    );

    // Actualizar polyline del paso actual
    // NOTA: NO dibujar polyline para pasos de bus (ride_bus), solo mostrar paraderos
    if (navigation.currentStep?.type == 'ride_bus') {
      _polylines = [];
      _log('🚌 [BUS] No se dibuja polyline para ride_bus (solo paraderos)');
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
                        color: markerColor.withValues(alpha: 0.5),
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
          _log(
            '🗺️ [MARKERS] Re-creados ${stops.length} marcadores de paradas de bus',
          );
        }
      } catch (e) {
        _log('⚠️ [MARKERS] Error obteniendo paradas de bus: $e');
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
                color: Colors.orange.withValues(alpha: 0.5),
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
                  color: Colors.green.withValues(alpha: 0.5),
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
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Animación de carga mejorada
          SizedBox(
            width: 45,
            height: 45,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 3,
                ),
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.route,
                    color: Colors.white,
                    size: 16,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Procesando ruta...',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Por favor espera',
            style: TextStyle(
              color: Colors.white.withOpacity(0.8),
              fontSize: 11,
              fontWeight: FontWeight.w400,
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
    _compassSubscription?.cancel(); // Cancelar brújula

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
          final double floatingSecondary = overlayBase + gap * 1.15;
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
                      initialZoom: 14.0,
                      minZoom: 10.0,
                      maxZoom: 18.0,
                      initialRotation: 0.0,
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
                      onPositionChanged: (position, hasGesture) {
                        if (hasGesture && _autoCenter) {
                          setState(() {
                            _userManuallyMoved = true;
                            _autoCenter = false;
                          });
                          _log(
                            '🗺️ [MANUAL] Auto-centrado desactivado por gesto del usuario',
                          );
                        }
                      },
                      keepAlive: true,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.wayfindcl',
                        maxZoom: 18,
                        maxNativeZoom: 18,
                        retinaMode: false,
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

              if (hasActiveNavigation)
                Positioned(
                  right: 96,
                  bottom: floatingPrimary,
                  child: _buildSimulationFab(),
                ),

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

              // Botón de configuración (derecha)
              Positioned(
                right: 20,
                bottom: floatingSecondary,
                child: GestureDetector(
                  onTap: () => Navigator.pushNamed(context, '/settings'),
                  child: Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF111827), Color(0xFF1F2937)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0F172A).withValues(alpha: 0.4),
                          blurRadius: 18,
                          offset: const Offset(0, 10),
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
    final bool loading = _npuLoading && !_npuChecked;
    final bool available = _npuAvailable;

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
          // Logo Red Movilidad (32x32)
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipOval(
              child: Image.asset(
                'assets/icons.webp',
                width: 32,
                height: 32,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  // Fallback si no existe la imagen
                  return const Icon(
                    Icons.directions_bus,
                    color: Color(0xFFE30613),
                    size: 18,
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Text(
            'WayFindCL',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(width: 12),
          _buildIaBadge(loading: loading, available: available),
        ],
      ),
    );
  }

  Widget _buildIaBadge({required bool loading, required bool available}) {
    final List<Color> colors;
    final String label;
    if (loading) {
      colors = [const Color(0xFFE2E8F0), const Color(0xFFCBD5F5)];
      label = 'IA';
    } else if (available) {
      colors = [const Color(0xFF00BCD4), const Color(0xFF0097A7)];
      label = 'IA';
    } else {
      colors = [const Color(0xFFE53935), const Color(0xFFD32F2F)];
      label = 'IA OFF';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: colors),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: colors.last.withValues(alpha: 0.35),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading) ...[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            const SizedBox(width: 6),
          ] else ...[
            const Icon(Icons.bolt, size: 16, color: Colors.white),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomPanel(BuildContext context) {
    final bool isListening = _isListening;
    final bool isCalculating = _isCalculatingRoute;
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    final bool hasActiveNav = activeNav != null && !activeNav.isComplete;

    // INTERFAZ MINIMAL durante navegación activa
    if (hasActiveNav && !isCalculating) {
      return _buildMinimalNavigationPanel(context, isListening, activeNav);
    }

    // INTERFAZ COMPLETA cuando NO hay navegación
    return _buildFullBottomPanel(context, isListening, isCalculating);
  }

  /// Interfaz minimal durante navegación: solo micrófono + info de ruta
  Widget _buildMinimalNavigationPanel(BuildContext context, bool isListening, dynamic activeNav) {
    final List<Color> micGradient = isListening
        ? const [Color(0xFFE53935), Color(0xFFB71C1C)]
        : const [Color(0xFF00BCD4), Color(0xFF0097A7)];

    final Color micShadowColor = isListening
        ? const Color(0xFFB71C1C)
        : const Color(0xFF0097A7);

    // Calcular tiempo y distancia de forma segura
    final int durationMin = activeNav.totalDurationSeconds != null 
        ? (activeNav.totalDurationSeconds ~/ 60) 
        : 0;
    final int distanceM = activeNav.totalDistanceMeters ?? 0;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Mensajes recientes (si hay)
            if (_messageHistory.isNotEmpty) _buildMessageHistoryPanel(),
            if (_messageHistory.isNotEmpty) const SizedBox(height: 8),
            
            // Panel minimal con micrófono
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: micShadowColor.withValues(alpha: 0.15),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // Botón de micrófono
                  GestureDetector(
                    onTap: isListening ? _stopListening : _startListening,
                    child: Container(
                      width: 70,
                      height: 70,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: micGradient,
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: micShadowColor.withValues(alpha: 0.3),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Icon(
                        isListening ? Icons.mic : Icons.mic_none,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  // Info de navegación
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.access_time, size: 18, color: Color(0xFF64748B)),
                            const SizedBox(width: 6),
                            Text(
                              '${durationMin}min',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                            const SizedBox(width: 16),
                            const Icon(Icons.straighten, size: 18, color: Color(0xFF64748B)),
                            const SizedBox(width: 6),
                            Text(
                              '${distanceM}m',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // Botón Simular Caminata
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _simulateArrivalAtStop,
                icon: const Icon(Icons.directions_walk),
                label: Text(_getSimulationButtonLabel()),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: const Color(0xFFFFA726),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  elevation: 4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Interfaz completa cuando NO hay navegación activa
  Widget _buildFullBottomPanel(BuildContext context, bool isListening, bool isCalculating) {
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
            Row(
              children: const [
                Icon(Icons.campaign, color: Colors.white, size: 18),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Mensajes recientes',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
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
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    final bool hasActiveNav = activeNav != null && !activeNav.isComplete;
    final instructions = _getActiveWalkInstructions();
    final bool hasInstructions = instructions != null && instructions.isNotEmpty;
    final int totalInstructions = instructions?.length ?? 0;
    int focusIndex = 0;
    if (hasInstructions) {
      focusIndex = _instructionFocusIndex.clamp(0, totalInstructions - 1);
    }

    final List<String> visibleInstructions = instructions ?? const <String>[];
    final String preview = hasInstructions
        ? visibleInstructions[focusIndex]
        : 'Inicia una ruta para habilitar la simulacion.';

    final bool panelEnabled = hasActiveNav || _hasActiveTrip || hasInstructions;

    return Semantics(
      container: true,
      label: panelEnabled
          ? 'Controles de ruta listos'
          : 'Controles de ruta, inicia una ruta para habilitarlos',
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 18,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: const [
                Icon(Icons.assistant_navigation, color: Color(0xFF00BCD4)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Controles de ruta',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                SizedBox(
                  width: 220,
                  child: ElevatedButton.icon(
                    onPressed: hasActiveNav ? _simulateArrivalAtStop : null,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(_getSimulationButtonLabel()),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      backgroundColor: const Color(0xFF00BCD4),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFFB0BEC5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                  ),
                ),
                if (hasInstructions)
                  SizedBox(
                    width: 220,
                    child: OutlinedButton.icon(
                      onPressed: _speakFocusedInstruction,
                      icon: const Icon(Icons.record_voice_over),
                      label: const Text('Leer paso'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                        side: const BorderSide(color: Color(0xFF1F2937)),
                        foregroundColor: const Color(0xFF1F2937),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (hasInstructions) ...[
              Text(
                'Paso ${focusIndex + 1} de $totalInstructions',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                preview,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.3,
                  color: Color(0xFF4B5563),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: focusIndex > 0
                        ? () => _moveInstructionFocus(-1)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                    label: const Text('Anterior'),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: focusIndex < totalInstructions - 1
                        ? () => _moveInstructionFocus(1)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                    label: const Text('Siguiente'),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const Text(
                'Inicia una ruta para habilitar la simulación.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.3,
                  color: Color(0xFF4B5563),
                ),
              ),
            ],
          ],
        ),
      ),
    );
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
