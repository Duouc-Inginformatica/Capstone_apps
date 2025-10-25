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
import '../services/device/tts_service.dart';
import '../services/backend/api_client.dart';
import '../services/backend/address_validation_service.dart';
import '../services/navigation/route_tracking_service.dart';
import '../services/navigation/transit_boarding_service.dart';
import '../services/navigation/integrated_navigation_service.dart';
import '../services/device/npu_detector_service.dart';
import '../services/debug_logger.dart';
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

  bool _npuAvailable = false;
  bool _npuLoading = false;
  bool _npuChecked = false;

  // Reconocimiento de voz simplificado
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

  // Cache de geometría para optimización
  List<LatLng> _cachedStepGeometry = [];
  int _cachedStepIndex = -1;

  // Control de simulación GPS
  bool _isSimulating = false; // Evita auto-centrado durante simulación
  int _currentSimulatedBusStopIndex = -1; // Índice del paradero actual durante simulación de bus

  // Control de visualización de ruta de bus
  final bool _busRouteShown =
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
  
  // NOTA: Variables de compass removidas (causaban bugs en el mapa)

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
    
    // Log de inicialización con optimizaciones
    DebugLogger.separator(title: 'MAP SCREEN OPTIMIZADO');
    DebugLogger.info('🗺️ Inicializando con autocentrado permanente', context: 'MapScreen');
    DebugLogger.info('⚡ Throttling activado: Map(100ms), GPS(10m)', context: 'MapScreen');
    
    unawaited(TtsService.instance.setActiveContext('map_navigation'));
    _initializeNpuDetection();
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

  /// Determina el índice de la instrucción actual basado en la posición GPS
  int _determineCurrentInstructionIndex() {
    if (_currentPosition == null) return 0;
    
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    if (activeNav == null) return 0;

    final currentStep = activeNav.currentStep;
    if (currentStep == null || 
        currentStep.streetInstructions == null ||
        currentStep.streetInstructions!.isEmpty) {
      return 0;
    }

    // Obtener la geometría del paso actual
    final geometry = _getCurrentStepGeometryCached();
    if (geometry.isEmpty) return 0;

    // Calcular la distancia recorrida en el paso actual
    double distanceToUser = double.infinity;
    int closestPointIndex = 0;
    
    for (int i = 0; i < geometry.length; i++) {
      final point = geometry[i];
      final distance = Geolocator.distanceBetween(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
        point.latitude,
        point.longitude,
      );
      
      if (distance < distanceToUser) {
        distanceToUser = distance;
        closestPointIndex = i;
      }
    }

    // Calcular el progreso como porcentaje del recorrido
    final double progress = closestPointIndex / geometry.length;
    final int totalInstructions = currentStep.streetInstructions!.length;
    
    // Determinar qué instrucción mostrar según el progreso
    int instructionIndex = (progress * totalInstructions).floor();
    instructionIndex = instructionIndex.clamp(0, totalInstructions - 1);
    
    return instructionIndex;
  }

  /// Construye el panel de instrucción actual basado en posición GPS
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
    final int currentIndex = _determineCurrentInstructionIndex();
    final String currentInstruction = instructions[currentIndex];
    final String? nextInstruction = 
        currentIndex < instructions.length - 1 
            ? instructions[currentIndex + 1] 
            : null;

    return Card(
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Métricas del trayecto
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildMetric(
                  Icons.straighten,
                  '${(currentStep.realDistanceMeters! / 1000).toStringAsFixed(2)} km',
                  'Distancia',
                ),
                _buildMetric(
                  Icons.access_time,
                  '${(currentStep.realDurationSeconds! / 60).toStringAsFixed(0)} min',
                  'Tiempo',
                ),
                _buildMetric(
                  Icons.format_list_numbered,
                  '${currentIndex + 1}/${instructions.length}',
                  'Paso',
                ),
              ],
            ),
            
            const SizedBox(height: 20),
            const Divider(color: Color(0xFFE2E8F0), height: 1),
            const SizedBox(height: 20),

            // Instrucción actual
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFFF59E0B),
                  width: 2,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: const BoxDecoration(
                      color: Color(0xFFF59E0B),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.navigation_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      currentInstruction,
                      style: const TextStyle(
                        color: Color(0xFF0F172A),
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Próxima instrucción (preview)
            if (nextInstruction != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.arrow_forward,
                      color: Color(0xFF64748B),
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Siguiente: $nextInstruction',
                        style: const TextStyle(
                          color: Color(0xFF64748B),
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetric(IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, color: const Color(0xFF0F172A), size: 20),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: Color(0xFF0F172A),
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF64748B),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildNavigationQuickActions(bool hasActiveNavigation) {
    final instructions = _getActiveWalkInstructions();
    final bool hasWalkInstructions =
        instructions != null && instructions.isNotEmpty;

    if (!hasActiveNavigation && !hasWalkInstructions) {
      return const SizedBox.shrink();
    }
    
    // NO mostrar en modo viaje de bus (ride_bus)
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    if (activeNav?.currentStep?.type == 'ride_bus' || activeNav?.currentStep?.type == 'bus') {
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
    // NO mostrar en modo viaje de bus (ride_bus)
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    if (activeNav?.currentStep?.type == 'ride_bus' || activeNav?.currentStep?.type == 'bus') {
      return const SizedBox.shrink();
    }
    
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
        // Verificar si el siguiente paso es bus o es la caminata final
        if (activeNav.currentStepIndex < activeNav.steps.length - 1) {
          final nextStep = activeNav.steps[activeNav.currentStepIndex + 1];
          if (nextStep.type == 'wait_bus' || nextStep.type == 'bus' || nextStep.type == 'ride_bus') {
            return 'Simular → Paradero';
          }
        }
        return 'Simular → Destino';
      case 'wait_bus':
        return 'Subir al bus';
      case 'ride_bus':
      case 'bus':
        return 'Simular viaje';
      default:
        return 'Simular';
    }
  }

  /// TEST: Simula movimiento GPS realista a lo largo de la geometría para desarrolladores
  void _simulateArrivalAtStop() async {
    final activeNav = IntegratedNavigationService.instance.activeNavigation;

    if (activeNav == null) {
      await TtsService.instance.speak('No hay navegación activa');
      _showWarningNotification(
        'Primero inicia navegación diciendo: ir a Costanera Center',
      );
      return;
    }

    // Verificar si ya completamos todos los pasos
    if (activeNav.currentStepIndex >= activeNav.steps.length) {
      _log('✅ [SIMULAR] Navegación completada');
      await TtsService.instance.speak('Navegación completada');
      _showSuccessNotification('Ruta completada');
      return;
    }
    
    final currentStep = activeNav.steps[activeNav.currentStepIndex];

    // CASO ESPECIAL: Si estamos en wait_bus, significa que YA llegamos al paradero
    // El botón "Simular" confirma que el usuario subió al bus y dibuja la ruta
    if (currentStep.type == 'wait_bus') {
      _log('🚌 [SIMULAR] Usuario confirmó que subió al bus desde wait_bus');
      
      // Verificar si hay un siguiente paso de tipo bus
      if (activeNav.currentStepIndex < activeNav.steps.length - 1) {
        final nextStep = activeNav.steps[activeNav.currentStepIndex + 1];
        if (nextStep.type == 'bus' || nextStep.type == 'ride_bus') {
          // PRIMERO: Dibujar la geometría del bus ANTES de avanzar
          try {
            final busLeg = activeNav.itinerary.legs.firstWhere(
              (leg) => leg.type == 'bus' && leg.isRedBus,
              orElse: () => throw Exception('No bus leg found'),
            );
            
            // Usar la geometría COMPLETA de la ruta (no solo las paradas)
            final busGeometry = busLeg.geometry;
            final stops = busLeg.stops;
            
            if (busGeometry != null && busGeometry.isNotEmpty) {
              // Usar geometría real del backend (ruta completa)
              _log('🚌 [BUS] Usando geometría completa: ${busGeometry.length} puntos');
              
              setState(() {
                _polylines = [
                  Polyline(
                    points: busGeometry,
                    color: const Color(0xFF2196F3), // Azul para ruta de bus
                    strokeWidth: 4.0,
                  ),
                ];
                
                // TAMBIÉN actualizar marcadores para mostrar los paraderos
                _updateNavigationMarkers(nextStep, activeNav);
              });
              
              _log('🚌 [BUS] Geometría dibujada: ${busGeometry.length} puntos de ruta, ${stops?.length ?? 0} paraderos');
            } else if (stops != null && stops.isNotEmpty) {
              // Fallback: usar solo puntos de paradas si no hay geometría
              final busRoutePoints = stops.map((stop) => stop.location).toList();
              _log('⚠️ [BUS] Sin geometría completa, usando ${busRoutePoints.length} puntos de paraderos');
              
              setState(() {
                _polylines = [
                  Polyline(
                    points: busRoutePoints,
                    color: const Color(0xFF2196F3), // Azul para ruta de bus
                    strokeWidth: 4.0,
                  ),
                ];
                
                // TAMBIÉN actualizar marcadores para mostrar los paraderos
                _updateNavigationMarkers(nextStep, activeNav);
              });
            }
          } catch (e) {
            _log('⚠️ [BUS] Error dibujando geometría: $e');
          }
          
          // SEGUNDO: Vibración de confirmación (patrón corto)
          final hasVibrator = await Vibration.hasVibrator();
          if (hasVibrator == true) {
            Vibration.vibrate(duration: 200);
          }
          
          // TERCERO: Anunciar TTS y ESPERAR que termine
          await TtsService.instance.speak('Subiendo al bus ${nextStep.busRoute}', urgent: true);
          
          // CUARTO: Pequeña pausa para dar tiempo visual
          await Future.delayed(const Duration(milliseconds: 800));
        }
      }
      
      // CUARTO: Avanzar al siguiente paso (el bus)
      IntegratedNavigationService.instance.advanceToNextStep();
      if (mounted) {
        setState(() {
          _updateNavigationMapState(IntegratedNavigationService.instance.activeNavigation!);
        });
      }
      return;
    }

    // SIMULAR MOVIMIENTO GPS REALISTA SEGÚN EL TIPO DE PASO
    _log('🔧 [SIMULAR] Iniciando simulación GPS para: ${currentStep.type}');
    _showSuccessNotification('Simulando: ${currentStep.type}');

    if (currentStep.type == 'walk') {
      // SIMULAR CAMINATA: Mover GPS punto por punto a lo largo de la geometría
      _log('🚶 [SIMULAR] Caminata - Moviendo GPS por geometría');
      
      final geometry = _getCurrentStepGeometryCached();
      
      if (geometry.isEmpty) {
        _log('⚠️ [SIMULAR] Sin geometría para simular');
        await TtsService.instance.speak('Sin datos de ruta');
        return;
      }
      
      // Cancelar cualquier simulación previa
      _walkSimulationTimer?.cancel();
      
      // Activar modo simulación para evitar auto-centrado
      setState(() {
        _isSimulating = true;
      });
      
      int currentPointIndex = 0;
      final totalPoints = geometry.length;
      final pointsPerInstruction = (totalPoints / (currentStep.streetInstructions?.length ?? 1)).ceil();
      
      // Variable para rastrear la última instrucción anunciada
      int lastAnnouncedInstruction = -1;
      
      // Timer para mover GPS cada 2 segundos
      _walkSimulationTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
        if (currentPointIndex >= totalPoints) {
          timer.cancel();
          _log('✅ [SIMULAR] Caminata completada');
          
          // Desactivar modo simulación
          setState(() {
            _isSimulating = false;
          });
          
          // Vibración de llegada (doble vibración)
          final hasVibrator = await Vibration.hasVibrator();
          if (hasVibrator == true) {
            Vibration.vibrate(duration: 150);
            await Future.delayed(const Duration(milliseconds: 200));
            Vibration.vibrate(duration: 150);
          }
          
          // Detectar si es el destino final o un paradero intermedio
          final isLastStep = activeNav.currentStepIndex >= activeNav.steps.length - 1;
          if (isLastStep) {
            await TtsService.instance.speak('Has llegado a tu destino, ${currentStep.stopName}');
            // Finalizar navegación
            IntegratedNavigationService.instance.stopNavigation();
          } else {
            // NO avanzar automáticamente - el usuario debe presionar "Simular subida al bus"
            await TtsService.instance.speak('Llegaste al paradero. Espera el bus ${currentStep.busRoute ?? ""}');
            _log('🚏 [SIMULAR] Llegaste al paradero. NO se avanza automáticamente.');
            _log('🚏 [SIMULAR] El usuario debe presionar "Simular subida al bus" cuando esté listo.');
            
            // DETENER la simulación aquí - NO avanzar al siguiente paso
            // La simulación se detendrá y el usuario debe presionar el botón de nuevo
          }
          return;
        }
        
        // Mover GPS al siguiente punto (SIN mover el mapa para permitir interacción)
        final nextPoint = geometry[currentPointIndex];
        _updateSimulatedGPS(nextPoint, moveMap: false);
        
        // Anunciar instrucción cuando se alcanza un nuevo segmento
        if (currentStep.streetInstructions != null && currentStep.streetInstructions!.isNotEmpty) {
          final instructionIndex = (currentPointIndex / pointsPerInstruction).floor()
              .clamp(0, currentStep.streetInstructions!.length - 1);
          
          // Solo anunciar si es una nueva instrucción
          if (instructionIndex != lastAnnouncedInstruction && instructionIndex < currentStep.streetInstructions!.length) {
            final instruction = currentStep.streetInstructions![instructionIndex];
            lastAnnouncedInstruction = instructionIndex;
            
            _log('📍 [SIMULAR] Nueva instrucción (${instructionIndex + 1}/${currentStep.streetInstructions!.length}): $instruction');
            
            // Anunciar la instrucción por TTS
            await TtsService.instance.speak(instruction, urgent: false);
          }
        }
        
        currentPointIndex++;
        
        if (mounted) {
          setState(() {}); // Actualizar UI
        }
      });
      
    } else if (currentStep.type == 'bus' || currentStep.type == 'ride_bus') {
      // SIMULAR VIAJE EN BUS: Mover GPS por cada parada
      _log('� [SIMULAR] Viaje en bus - Moviendo GPS por paradas');
      // NO anunciar "Subiendo al bus" aquí porque ya se anunció en wait_bus
      // Dar un pequeño delay antes de empezar a mover el GPS
      await Future.delayed(const Duration(milliseconds: 500));
      
      // Obtener paradas del bus
      final busLeg = activeNav.itinerary.legs.firstWhere(
        (leg) => leg.type == 'bus' && leg.isRedBus,
        orElse: () => throw Exception('No bus leg found'),
      );
      
      final allStops = busLeg.stops ?? [];
      if (allStops.isEmpty) {
        _log('⚠️ [SIMULAR] Sin paradas para simular');
        await TtsService.instance.speak('Viaje en bus completado');
        IntegratedNavigationService.instance.advanceToNextStep();
        if (mounted) {
          setState(() {
            _updateNavigationMapState(activeNav);
          });
        }
        return;
      }
      
      // Cancelar timer previo
      _walkSimulationTimer?.cancel();
      
      // Activar modo simulación
      setState(() {
        _isSimulating = true;
        _currentSimulatedBusStopIndex = 0; // Empezar desde el primer paradero
      });
      
      int currentStopIndex = 0;
      
      // Determinar qué paraderos anunciar (evitar spam en rutas largas)
      final importantStopIndices = _getImportantStopIndices(allStops.length);
      
      // Anunciar primera parada
      await TtsService.instance.speak(
        'Partiendo desde ${allStops[0].name}',
        urgent: false,
      );
      
      // Timer para mover GPS por cada parada cada 3 segundos
      _walkSimulationTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
        if (currentStopIndex >= allStops.length) {
          timer.cancel();
          _log('✅ [SIMULAR] Viaje en bus completado');
          
          // Desactivar modo simulación
          setState(() {
            _isSimulating = false;
            _currentSimulatedBusStopIndex = -1; // Resetear índice
          });
          
          // Vibración al bajar del bus (triple vibración)
          final hasVibrator = await Vibration.hasVibrator();
          if (hasVibrator == true) {
            Vibration.vibrate(duration: 100);
            await Future.delayed(const Duration(milliseconds: 150));
            Vibration.vibrate(duration: 100);
            await Future.delayed(const Duration(milliseconds: 150));
            Vibration.vibrate(duration: 100);
          }
          
          await TtsService.instance.speak('Bajaste del bus');
          
          // Avanzar al siguiente paso (probablemente walk final) pero NO continuar simulación
          // El desarrollador debe presionar "Simular" de nuevo para la caminata final
          if (activeNav.currentStepIndex < activeNav.steps.length - 1) {
            IntegratedNavigationService.instance.advanceToNextStep();
            if (mounted) {
              setState(() {
                _updateNavigationMapState(IntegratedNavigationService.instance.activeNavigation!);
              });
            }
          }
          return;
        }
        
        // Mover GPS a la parada (SIN mover el mapa para permitir interacción)
        final stop = allStops[currentStopIndex];
        _updateSimulatedGPS(stop.location, moveMap: false);
        
        final isFirstStop = currentStopIndex == 0;
        final isLastStop = currentStopIndex == allStops.length - 1;
        final isImportantStop = importantStopIndices.contains(currentStopIndex);
        
        // Anunciar SOLO paraderos importantes para evitar spam
        String announcement = '';
        if (isLastStop) {
          announcement = 'Próxima parada: ${stop.name}. Prepárate para bajar';
          // Vibración más fuerte para última parada
          final hasVibrator = await Vibration.hasVibrator();
          if (hasVibrator == true) {
            Vibration.vibrate(duration: 300);
          }
        } else if (isImportantStop && !isFirstStop) {
          // Anunciar paraderos importantes (cada N paradas)
          final stopCode = stop.code != null ? 'código ${stop.code}' : '';
          announcement = 'Paradero ${stop.name} $stopCode';
          // Vibración sutil para paraderos importantes
          final hasVibrator = await Vibration.hasVibrator();
          if (hasVibrator == true) {
            Vibration.vibrate(duration: 100);
          }
        }
        
        if (announcement.isNotEmpty) {
          await TtsService.instance.speak(announcement, urgent: false);
        }
        
        _log('🚏 [SIMULAR] Parada ${currentStopIndex + 1}/${allStops.length}: ${stop.name} ${stop.code ?? ""}');
        
        currentStopIndex++;
        
        if (mounted) {
          setState(() {
            _currentSimulatedBusStopIndex = currentStopIndex; // Actualizar índice
          });
        }
      });
      
    } else {
      // Otros tipos de pasos
      _log('⚠️ [SIMULAR] Tipo no manejado: ${currentStep.type}');
      await TtsService.instance.speak('Paso completado');
      
      if (activeNav.currentStepIndex < activeNav.steps.length - 1) {
        IntegratedNavigationService.instance.advanceToNextStep();
        if (mounted) {
          setState(() {
            _updateNavigationMapState(activeNav);
          });
        }
      }
    }
  }

  /// Determina qué paraderos son importantes para anunciar según la longitud del viaje
  /// Evita spam en rutas largas anunciando solo paraderos clave
  Set<int> _getImportantStopIndices(int totalStops) {
    final Set<int> importantIndices = {};
    
    if (totalStops <= 5) {
      // Ruta corta: anunciar todos los intermedios
      for (int i = 1; i < totalStops - 1; i++) {
        importantIndices.add(i);
      }
    } else if (totalStops <= 10) {
      // Ruta mediana: anunciar cada 2 paradas
      for (int i = 1; i < totalStops - 1; i += 2) {
        importantIndices.add(i);
      }
    } else if (totalStops <= 20) {
      // Ruta larga: anunciar cada 3 paradas
      for (int i = 1; i < totalStops - 1; i += 3) {
        importantIndices.add(i);
      }
    } else {
      // Ruta muy larga: anunciar cada 5 paradas
      for (int i = 1; i < totalStops - 1; i += 5) {
        importantIndices.add(i);
      }
    }
    
    // Siempre incluir el penúltimo para dar aviso antes del final
    if (totalStops > 2) {
      importantIndices.add(totalStops - 2);
    }
    
    return importantIndices;
  }

  /// Obtiene las instrucciones de caminata activas
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

  // Calcular nueva posición dado bearing y distancia
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

  void _moveMap(LatLng target, double zoom) {
    // Movimiento inmediato (solo se usa para carga inicial del mapa)
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

  /// Configura el listener de GPS para navegación en tiempo real
  void _setupGPSListener() {
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10, // Optimizado: Actualizar cada 10 metros (reduce carga)
    );

    Geolocator.getPositionStream(locationSettings: locationSettings).listen(
      (Position position) {
        if (!mounted) return;

        setState(() {
          _currentPosition = position;
        });

        _updateCurrentLocationMarker();

        // NO AUTO-CENTRAR - el usuario tiene control total del mapa

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

    // Usar geometría cacheada
    final stepGeometry = _getCurrentStepGeometryCached();
    if (stepGeometry.isEmpty) return;

    // Obtener el waypoint destino del paso actual
    final targetWaypoint = stepGeometry.last;
    
    final distanceToTarget = Geolocator.distanceBetween(
      currentPos.latitude,
      currentPos.longitude,
      targetWaypoint.latitude,
      targetWaypoint.longitude,
    );

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

  void _updateCurrentLocationMarker() {
    if (_currentPosition == null || !mounted) return;

    final currentMarker = Marker(
      point: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
      width: 56,
      height: 56,
      // Optimización: usar const para widgets estáticos
      child: const _UserLocationMarkerWidget(),
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

        // Procesar resultado final
        if (result.finalResult) {
          _speechTimeoutTimer?.cancel();
          _processRecognizedText(result.recognizedWords);
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
      });
      return;
    }

    final destination = _extractDestination(normalized);
    if (destination != null) {
      setState(() {
        _lastWords = command;
      });

      // CAP-9: Solicitar confirmación antes de buscar ruta
      _requestDestinationConfirmation(destination);
      return;
    }

    setState(() {
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

  /// Actualiza el GPS simulado a una nueva ubicación SIN mover el mapa
  void _updateSimulatedGPS(LatLng targetLocation, {bool moveMap = false}) {
    _log('📍 [GPS SIMULADO] Actualizando posición a: ${targetLocation.latitude}, ${targetLocation.longitude}');
    
    // Crear una nueva Position simulada
    _currentPosition = Position(
      latitude: targetLocation.latitude,
      longitude: targetLocation.longitude,
      timestamp: DateTime.now(),
      accuracy: 10.0, // Precisión simulada de 10 metros
      altitude: 0.0,
      altitudeAccuracy: 0.0,
      heading: 0.0,
      headingAccuracy: 0.0,
      speed: 0.0,
      speedAccuracy: 0.0,
    );
    
    // CRÍTICO: Actualizar también el servicio de navegación para que use esta posición
    // Esto asegura que la geometría se recorte desde la posición simulada correcta
    IntegratedNavigationService.instance.updateSimulatedPosition(_currentPosition!);
    
    // Actualizar marcador de ubicación
    if (mounted) {
      setState(() {
        _updateCurrentLocationMarker();
      });
    }
    
    // NO AUTO-CENTRAR - moveMap siempre es false, el usuario tiene control total
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

  // Procesar texto reconocido por voz
  void _processRecognizedText(String recognizedText) {
    if (!mounted || _isProcessingCommand) return;

    setState(() {
      _isProcessingCommand = true;
    });

    // Agregar a historial
    _recognitionHistory.add(recognizedText);
    if (_recognitionHistory.length > 10) {
      _recognitionHistory.removeAt(0);
    }

    // Procesar comando
    bool commandProcessed = _processVoiceCommandEnhanced(recognizedText);

    // Intentar con texto normalizado si no se procesó
    if (!commandProcessed) {
      String normalizedText = _normalizeText(recognizedText);
      commandProcessed = _processVoiceCommandEnhanced(normalizedText);
    }

    if (commandProcessed) {
      _showSuccessNotification(
        'Comando ejecutado: "$recognizedText"',
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
      });
      return true;
    }

    // 🚌 Comando para navegación integrada con Moovit (buses Red)
    if (normalized.contains('navegación red') ||
        normalized.contains('ruta red') ||
        normalized.contains('bus red')) {
      final destination = _extractDestination(command);
      if (destination != null && destination.isNotEmpty) {
        setState(() {
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

          // Usar geometría cacheada en lugar de llamar al servicio
          final stepGeometry = _getCurrentStepGeometryCached();

          if (step.type == 'wait_bus') {
            // Para wait_bus: NO mostrar geometría del bus todavía
            // Solo mostrar la geometría de la caminata previa (si existe)
            // La geometría del bus se mostrará cuando el usuario confirme con "Simular"
            _polylines = [];
            _log('🚏 [WAIT_BUS] Sin geometría hasta confirmar subida al bus');
          } else if (step.type == 'ride_bus') {
            // Para ride_bus: NO dibujar automáticamente aquí
            // La geometría ya se dibujó en _simulateBoardingBus() cuando el usuario confirmó
            // Mantener la geometría existente (no modificar _polylines)
            _log('🚌 [RIDE_BUS] Manteniendo geometría dibujada en simulación');
          } else {
            // Para walk, etc: dibujar polyline normal
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
          // Actualizar UI con distancia/tiempo restante

          // Usar geometría cacheada para evitar spam de llamadas
          final activeNav =
              IntegratedNavigationService.instance.activeNavigation;
          final currentStep = activeNav?.currentStep;
          final stepGeometry = _getCurrentStepGeometryCached();

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

            // NO AUTO-CENTRAR - el usuario tiene control total del mapa
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
    final currentStepIndex = navigation.currentStepIndex;
    final previousStepIndex = _cachedStepIndex;
    
    // Solo actualizar caché si cambió el paso
    if (_cachedStepIndex != currentStepIndex) {
      _cachedStepGeometry = IntegratedNavigationService.instance.currentStepGeometry;
      _cachedStepIndex = currentStepIndex;
      
      _log(
        '🗺️ [MAP] Cambio de paso: $previousStepIndex → $currentStepIndex (Geometría: ${_cachedStepGeometry.length} puntos)',
      );
    }

    // Actualizar polyline del paso actual
    if (navigation.currentStep?.type == 'wait_bus') {
      // NO mostrar geometría del bus hasta que confirme con "Simular"
      _polylines = [];
    } else if (navigation.currentStep?.type == 'ride_bus') {
      // Geometría del bus ya se dibujó cuando confirmó "Subir al bus"
      // Mantener la geometría existente
    } else {
      _polylines = _cachedStepGeometry.isNotEmpty
          ? [
              Polyline(
                points: _cachedStepGeometry,
                color: const Color(0xFFE30613),
                strokeWidth: 5.0,
              ),
            ]
          : [];
    }

    // Actualizar marcadores
    _updateNavigationMarkers(navigation.currentStep, navigation);
    
    // NO AUTO-CENTRAR - el usuario tiene control total del mapa en todo momento
    // El centrado solo ocurre al cargar el mapa inicialmente
  }

  /// Obtiene la geometría del paso actual usando caché para optimización
  List<LatLng> _getCurrentStepGeometryCached() {
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    if (activeNav == null) return [];
    
    final currentStepIndex = activeNav.currentStepIndex;
    
    // Usar caché si el índice no ha cambiado
    if (_cachedStepIndex == currentStepIndex && _cachedStepGeometry.isNotEmpty) {
      return _cachedStepGeometry;
    }
    
    // Actualizar caché
    _cachedStepGeometry = IntegratedNavigationService.instance.currentStepGeometry;
    _cachedStepIndex = currentStepIndex;
    
    return _cachedStepGeometry;
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

    // Mostrar paraderos de bus:
    // - SIEMPRE: paradero de origen (subida) y destino (bajada)
    // - SOLO durante ride_bus: paradas intermedias
    print('🔍 [MARKERS] Buscando leg de bus en itinerario...');
    _log('🔍 [MARKERS] Buscando leg de bus en itinerario...');
    try {
      final busLeg = navigation.itinerary.legs.firstWhere(
        (leg) => leg.type == 'bus' && leg.isRedBus,
        orElse: () => throw Exception('No bus leg found'),
      );

      print('✅ [MARKERS] Leg de bus encontrado');
      _log('✅ [MARKERS] Leg de bus encontrado');

      final stops = busLeg.stops;
      print('🔍 [MARKERS] Stops: ${stops?.length ?? 0}');
      _log('🔍 [MARKERS] Stops: ${stops?.length ?? 0}');
      
      if (stops != null && stops.isNotEmpty) {
        final isRidingBus = currentStep?.type == 'ride_bus';
        final isWaitingBus = currentStep?.type == 'wait_bus';
        print('🚏 [MARKERS] Creando marcadores de paraderos (isRidingBus=$isRidingBus, isWaitingBus=$isWaitingBus, currentStep=${currentStep?.type})');
        _log('🚏 [MARKERS] Creando marcadores de paraderos (isRidingBus=$isRidingBus, isWaitingBus=$isWaitingBus, currentStep=${currentStep?.type})');
        
        for (int i = 0; i < stops.length; i++) {
          final stop = stops[i];
          final isFirst = i == 0;
          final isLast = i == stops.length - 1;
          final isCurrent = _isSimulating && 
                            isRidingBus && 
                            i == _currentSimulatedBusStopIndex;

          // FILTRO: Mostrar origen y destino SIEMPRE, y paradas intermedias solo durante ride_bus
          if (!isFirst && !isLast && !isRidingBus) {
            print('🚏 [MARKERS] Saltando parada intermedia $i (${stop.name})');
            continue; // Saltar paradas intermedias si no estamos en el bus
          }

          print('🚏 [MARKERS] Creando marcador $i: ${stop.name} (isFirst=$isFirst, isLast=$isLast, isCurrent=$isCurrent)');

          Color markerColor;
          IconData markerIcon;
          double markerSize;
          
          if (isCurrent) {
            // Paradero actual durante simulación: amarillo brillante
            markerColor = const Color(0xFFFFC107); // Amarillo
            markerIcon = Icons.directions_bus;
            markerSize = 45;
          } else if (isFirst) {
            // Paradero de ORIGEN del bus (donde se sube): Naranja
            markerColor = Colors.orange;
            markerIcon = Icons.arrow_upward; // Flecha hacia arriba = subida
            markerSize = 40;
          } else if (isLast) {
            // Paradero de DESTINO del bus (donde se baja): Morado
            markerColor = Colors.purple;
            markerIcon = Icons.arrow_downward; // Flecha hacia abajo = bajada
            markerSize = 40;
          } else {
            // Paraderos intermedios: icono pequeño con código
            markerColor = const Color(0xFF2196F3); // Azul
            markerIcon = Icons.circle;
            markerSize = 18; // Reducido de 20 a 18
          }

          newMarkers.add(
            Marker(
              point: stop.location,
              width: isCurrent ? markerSize + 10 : (isFirst || isLast ? markerSize + 4 : 50),
              height: isCurrent ? markerSize + 10 : (isFirst || isLast ? markerSize + 4 : 32), // Reducido de 35 a 32
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Icono del paradero
                  Container(
                    width: markerSize,
                    height: markerSize,
                    decoration: BoxDecoration(
                      color: markerColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isCurrent ? Colors.orange : Colors.white, 
                        width: isCurrent ? 3 : 2
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: markerColor.withValues(alpha: isCurrent ? 0.8 : 0.5),
                          blurRadius: isCurrent ? 12 : 6,
                          spreadRadius: isCurrent ? 4 : 2,
                        ),
                      ],
                    ),
                    child: Icon(
                      markerIcon,
                      color: Colors.white,
                      size: isCurrent ? 30 : (isFirst || isLast ? 24 : 9), // Reducido de 10 a 9
                    ),
                  ),
                  // Código del paradero (solo para intermedios, con tamaño reducido)
                  if (!isFirst && !isLast && stop.code != null)
                    Container(
                      margin: const EdgeInsets.only(top: 1), // Reducido de 2 a 1
                      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1), // Reducido padding
                      decoration: BoxDecoration(
                        color: isCurrent ? const Color(0xFFFFC107) : Colors.white,
                        borderRadius: BorderRadius.circular(2), // Reducido de 3 a 2
                        border: Border.all(
                          color: isCurrent ? Colors.orange : const Color(0xFF2196F3), 
                          width: isCurrent ? 2 : 1
                        ),
                      ),
                      child: Text(
                        stop.code!,
                        style: TextStyle(
                          fontSize: isCurrent ? 9 : 7, // Reducido de 10:8 a 9:7
                          fontWeight: FontWeight.bold,
                          color: isCurrent ? Colors.orange.shade900 : const Color(0xFF2196F3),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        }
        final visibleCount = isRidingBus ? stops.length : 2; // Solo origen y destino antes de subir
        print('🗺️ [MARKERS] Creados $visibleCount marcadores de paraderos (${stops.length} paradas totales)');
        print('🗺️ [MARKERS] Total markers hasta ahora: ${newMarkers.length}');
        _log('🗺️ [MARKERS] Creados $visibleCount marcadores de paraderos (${stops.length} paradas totales)');
        _log('🗺️ [MARKERS] Total markers hasta ahora: ${newMarkers.length}');
      }
    } catch (e) {
      print('⚠️ [MARKERS] No hay leg de bus en este itinerario: $e');
      _log('⚠️ [MARKERS] No hay leg de bus en este itinerario: $e');
    }

    // Marcador del paso actual (paradero o punto de acción)
    // SOLO si NO es ride_bus (porque ya están los marcadores de paradas)
    if (currentStep?.location != null && currentStep!.type != 'ride_bus') {
      print('🎯 [MARKERS] Creando marcador del paso actual: ${currentStep.type} en ${currentStep.location}');
      final Widget markerWidget;

      if (currentStep.type == 'walk' || currentStep.type == 'wait_bus') {
        print('🚏 [MARKERS] Creando marcador de paradero (tipo: ${currentStep.type})');
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
      print('🏁 [MARKERS] Creando marcador del destino final en ${lastStep.location}');
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
    print('🗺️ [MARKERS] ═══════════════════════════════════════════════════════');
    print('🗺️ [MARKERS] TOTAL DE MARCADORES CREADOS: ${newMarkers.length}');
    print('🗺️ [MARKERS] Paso actual: ${currentStep?.type}');
    print('🗺️ [MARKERS] ═══════════════════════════════════════════════════════');
    _log('🗺️ [MARKERS] TOTAL DE MARCADORES CREADOS: ${newMarkers.length}');
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
      
      // Vibración de confirmación al calcular ruta
      final hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator == true) {
        Vibration.vibrate(duration: 200);
      }
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
      
      // Vibración de error (patrón largo-corto-largo)
      final hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator == true) {
        Vibration.vibrate(duration: 300);
        await Future.delayed(const Duration(milliseconds: 200));
        Vibration.vibrate(duration: 100);
        await Future.delayed(const Duration(milliseconds: 200));
        Vibration.vibrate(duration: 300);
      }
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
        mainAxisSize: MainAxisSize.min,
        children: [
          // Animación de carga mejorada
          SizedBox(
            width: 40,
            height: 40,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2.5,
                ),
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.route,
                    color: Colors.white,
                    size: 14,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Procesando ruta...',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ],
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Lado izquierdo: Brújula
        if (_currentPosition?.heading != null)
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Transform.rotate(
                  angle: _currentPosition!.heading * 3.14159 / 180,
                  child: const Icon(
                    Icons.navigation,
                    color: Colors.white,
                    size: 20,
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
          )
        else
          const Expanded(child: SizedBox.shrink()),

        // Centro: Ícono del micrófono (grande y claro)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Icon(
            _isListening ? Icons.mic : Icons.mic_none,
            color: Colors.white,
            size: 40,
          ),
        ),

        // Lado derecho: Espacio para futura información
        const Expanded(child: SizedBox.shrink()),
      ],
    );
  }
  @override
  @override
  void dispose() {
    _resultDebounce?.cancel();
    _feedbackTimer?.cancel();
    _confirmationTimer?.cancel();
    _walkSimulationTimer?.cancel();

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
                      // onPositionChanged eliminado - el mapa siempre sigue al usuario
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
                        // Optimizaciones de rendimiento
                        tileSize: 256,
                        panBuffer: 1, // Reduce tiles cargados fuera de pantalla
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
                'assets/icons.png',
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
    
    // Mantener navegación activa visible incluso si isComplete == true
    // Esto permite que el usuario vea la ruta después de llegar al destino
    // y pueda iniciar una nueva navegación desde allí
    final bool hasActiveNav = activeNav != null;

    // INTERFAZ MINIMAL durante navegación activa
    if (hasActiveNav && !isCalculating) {
      return _buildMinimalNavigationPanel(context, isListening, activeNav);
    }

    // INTERFAZ COMPLETA cuando NO hay navegación
    return _buildFullBottomPanel(context, isListening, isCalculating);
  }

  /// Interfaz minimal durante navegación: solo micrófono + info de ruta
  Widget _buildMinimalNavigationPanel(BuildContext context, bool isListening, dynamic activeNav) {
    final currentStep = activeNav.currentStep;
    
    // PANEL ESPECIAL para wait_bus: Solo micrófono y tiempo de llegada
    if (currentStep?.type == 'wait_bus') {
      final busRoute = currentStep.busRoute ?? '';
      final arrivalTime = currentStep.arrivalTime ?? 0; // minutos
      
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                // Lado izquierdo: Icono y número del bus
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.directions_bus,
                        size: 32,
                        color: const Color(0xFFE30613),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        busRoute,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Bus',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
                // Centro: Botón de micrófono
                GestureDetector(
                  onTap: isListening ? _stopListening : _startListening,
                  child: Container(
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isListening ? const Color(0xFFEF4444) : const Color(0xFF0F172A),
                        width: 3,
                      ),
                    ),
                    child: Icon(
                      isListening ? Icons.mic : Icons.mic_none,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
                // Lado derecho: Tiempo de llegada
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.access_time,
                        size: 32,
                        color: const Color(0xFF2563EB),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${arrivalTime}min',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Llegada',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    
    // PANEL ESPECIAL para ride_bus: Muestra progreso del viaje en bus
    if (currentStep?.type == 'ride_bus' || currentStep?.type == 'bus') {
      final busRoute = currentStep.busRoute ?? '';
      final stopName = currentStep.stopName ?? 'Destino';
      final totalStops = currentStep.totalStops ?? 0;
      final currentStopIndex = _currentSimulatedBusStopIndex >= 0 ? _currentSimulatedBusStopIndex : 0;
      final remainingStops = totalStops > currentStopIndex ? totalStops - currentStopIndex : 0;
      
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Panel principal del bus con información
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFE30613), Color(0xFFB71C1C)],
                  ),
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFE30613).withValues(alpha: 0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // Fila superior: Número del bus y destino
                    Row(
                      children: [
                        // Icono y número del bus
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.directions_bus,
                                color: Color(0xFFE30613),
                                size: 24,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                busRoute,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Destino
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Hacia',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(
                                stopName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // Fila inferior: Progreso de paradas
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          // Parada actual
                          Column(
                            children: [
                              const Text(
                                'Parada',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${currentStopIndex + 1}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                          // Separador
                          Container(
                            width: 1,
                            height: 30,
                            color: Colors.white30,
                          ),
                          // Total de paradas
                          Column(
                            children: [
                              const Text(
                                'Total',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '$totalStops',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                          // Separador
                          Container(
                            width: 1,
                            height: 30,
                            color: Colors.white30,
                          ),
                          // Paradas restantes
                          Column(
                            children: [
                              const Text(
                                'Faltan',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '$remainingStops',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
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
              // Botón de micrófono flotante
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: isListening ? _stopListening : _startListening,
                    child: Container(
                      width: 70,
                      height: 70,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isListening ? const Color(0xFFEF4444) : const Color(0xFF0F172A),
                          width: 3,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 15,
                            offset: const Offset(0, 5),
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
                  const SizedBox(width: 16),
                  // Botón de simulación (discreto)
                  TextButton.icon(
                    onPressed: _simulateArrivalAtStop,
                    icon: const Icon(Icons.bug_report, size: 16),
                    label: Text(
                      _getSimulationButtonLabel(),
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF64748B),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    
    // PANEL NORMAL para otros casos
    // Calcular tiempo y distancia de forma segura
    final int durationMin = activeNav.estimatedDuration; // Ya está en minutos
    double distanceKm = 0.0;
    for (var leg in activeNav.itinerary.legs) {
      distanceKm += leg.distanceKm;
    }
    
    // Determinar el tipo de actividad actual (walk o bus)
    final isWalking = currentStep?.type == 'walk';
    final isBus = currentStep?.type == 'bus' || currentStep?.type == 'wait_bus';

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Mensajes de ruta (pegado arriba del panel principal)
            if (_messageHistory.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 4), // Espacio mínimo con el panel
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.campaign, color: Colors.amber, size: 16),
                        SizedBox(width: 6),
                        Text(
                          'Mensajes de ruta',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ...(_messageHistory.reversed.take(2).map((msg) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        msg,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          height: 1.3,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ))),
                  ],
                ),
              ),
            
            // Panel minimal con micrófono
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // Lado izquierdo: Tiempo con ícono contextual
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          isWalking ? Icons.directions_walk : isBus ? Icons.directions_bus : Icons.access_time,
                          size: 20,
                          color: const Color(0xFF64748B),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${durationMin}min',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Centro: Botón de micrófono
                  GestureDetector(
                    onTap: isListening ? _stopListening : _startListening,
                    child: Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isListening ? const Color(0xFFEF4444) : const Color(0xFF0F172A),
                          width: 3,
                        ),
                      ),
                      child: Icon(
                        isListening ? Icons.mic : Icons.mic_none,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
                  // Lado derecho: Distancia
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.straighten, size: 18, color: Color(0xFF64748B)),
                        const SizedBox(width: 6),
                        Text(
                          '${distanceKm.toStringAsFixed(1)}km',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // Botón debug para desarrolladores (discreto)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _simulateArrivalAtStop,
                icon: const Icon(Icons.bug_report, size: 16),
                label: const Text(
                  'Simular',
                  style: TextStyle(fontSize: 12),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF64748B),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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

  /// Simplifica nombres de paraderos para TTS
  /// Convierte "PA1234 / Av. Providencia" en "Paradero" cuando es destino
  /// o simplemente remueve el código manteniendo la calle
}

/// Widget optimizado para el marcador de ubicación del usuario
/// Usa const para evitar reconstrucciones innecesarias
class _UserLocationMarkerWidget extends StatelessWidget {
  const _UserLocationMarkerWidget();

  @override
  Widget build(BuildContext context) {
    return Stack(
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
            color: const Color(0xFF1976D2), // Colors.blue.shade700
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
            Icons.person_pin_circle_rounded,
            color: Colors.white,
            size: 28,
          ),
        ),
      ],
    );
  }
}