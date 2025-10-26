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
import '../services/backend/bus_arrivals_service.dart';
import '../services/navigation/route_tracking_service.dart';
import '../services/navigation/transit_boarding_service.dart';
import '../services/navigation/integrated_navigation_service.dart';
import '../services/device/npu_detector_service.dart';
import '../services/debug_logger.dart';
import '../services/ui/timer_manager.dart'; // ✅ Gestor de timers centralizado
import '../services/polyline_compression.dart'; // ✅ Compresión Douglas-Peucker
import '../services/geometry_cache_service.dart'; // ✅ Caché offline de geometrías
import '../widgets/map/accessible_notification.dart';
import 'settings_screen.dart';
import '../widgets/bottom_nav.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  static const routeName = '/map';

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TimerManagerMixin {
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
  // ✅ _resultDebounce gestionado por TimerManagerMixin
  String _pendingWords = '';

  bool _npuAvailable = false;
  bool _npuLoading = false;
  bool _npuChecked = false;

  // Reconocimiento de voz simplificado
  bool _isProcessingCommand = false;
  // ✅ Timers gestionados por TimerManagerMixin: speechTimeout, confirmation, feedback, walkSimulation
  final List<String> _recognitionHistory = [];
  static const Duration _speechTimeout = Duration(seconds: 5);

  // Trip state - solo mostrar información adicional cuando hay viaje activo
  bool _hasActiveTrip = false;

  // CAP-9: Confirmación de destino
  String? _pendingConfirmationDestination;
  // ✅ _confirmationTimer gestionado por TimerManagerMixin

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
  // ✅ _feedbackTimer gestionado por TimerManagerMixin

  // Cache de geometría para optimización
  List<LatLng> _cachedStepGeometry = [];
  int _cachedStepIndex = -1;

  // Control de simulación GPS
  bool _isSimulating = false; // Evita auto-centrado durante simulación
  int _currentSimulatedBusStopIndex = -1; // Índice del paradero actual durante simulación de bus
  
  // ============================================================================
  // SIMULACIÓN REALISTA CON DESVIACIONES (SOLO PARA DESARROLLO/DEBUG)
  // ============================================================================
  // IMPORTANTE: Estas variables son SOLO para el botón "Simular" (desarrollo)
  // Los usuarios finales NO tienen este botón - usan GPS real automático
  // El sistema de detección de desviación funciona AUTOMÁTICAMENTE con GPS real
  // en IntegratedNavigationService._onLocationUpdate()
  // ============================================================================
  bool _simulationDeviationEnabled = true; // Habilitar desviaciones aleatorias en simulación
  int _simulationDeviationStep = -1; // En qué punto índice se desviará (simulación)
  List<LatLng>? _simulationDeviationRoute; // Ruta de desviación temporal (simulación)
  bool _isCurrentlyDeviated = false; // Si está actualmente desviado (simulación)

  // Control de visualización de ruta de bus
  final bool _busRouteShown =
      false; // Rastrea si ya se mostró la ruta del bus en wait_bus

  // ============================================================================
  // TRACKING DE LLEGADAS EN TIEMPO REAL
  // ============================================================================
  StopArrivals? _currentArrivals; // Últimas llegadas recibidas
  bool _isWaitingForBus = false; // Si está esperando el bus en el paradero
  bool _needsRouteRecalculation = false; // Si el bus pasó y necesita recalcular

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
    // ✅ Reducido de 0.28 a 0.20 (20% en lugar de 28%) para dar más visibilidad al mapa
    final double estimate = media.size.height * 0.20 + media.padding.bottom;
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
    DebugLogger.info('💾 Caché de geometrías + Compresión Douglas-Peucker activos', context: 'MapScreen');
    
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
    // ✅ Inicializar caché de geometrías en background
    GeometryCacheService.instance.initialize().catchError((e, st) {
      _log('⚠️ Error inicializando GeometryCache: $e', error: e, stackTrace: st);
    });

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
        cancelTimer('speechTimeout'); // ✅ Usar TimerManagerMixin

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
          cancelTimer('speechTimeout'); // ✅ Usar TimerManagerMixin

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
    // ✅ Eliminado setState vacío innecesario
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
        child: SingleChildScrollView(
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
      ),
    );
  }  Widget _buildMetric(IconData icon, String value, String label) {
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
    if (activeNav?.currentStep?.type == 'ride_bus') {
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
    if (activeNav?.currentStep?.type == 'ride_bus') {
      return const SizedBox.shrink();
    }
    
    final String label = _getSimulationButtonLabel();

    return Semantics(
      button: true,
      label: label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ============================================================
          // TOGGLE PARA DESVIACIONES EN SIMULACIÓN (SOLO DESARROLLO)
          // ============================================================
          // Este toggle controla si la SIMULACIÓN (botón debug) incluye
          // desviaciones aleatorias para testing del sistema de corrección.
          // Los USUARIOS FINALES no ven este botón - usan GPS real que
          // detecta desviaciones automáticamente sin configuración.
          // ============================================================
          GestureDetector(
            onTap: () {
              setState(() {
                _simulationDeviationEnabled = !_simulationDeviationEnabled;
              });
              _showSuccessNotification(
                _simulationDeviationEnabled 
                    ? '🎲 Desviaciones activadas (simulación)' 
                    : '📍 Desviaciones desactivadas (simulación)'
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _simulationDeviationEnabled 
                    ? const Color(0xFFFF8C42)
                    : Colors.grey.shade400,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: (_simulationDeviationEnabled 
                        ? const Color(0xFFFF8C42)
                        : Colors.grey.shade400).withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _simulationDeviationEnabled 
                        ? Icons.shuffle_rounded
                        : Icons.trending_flat_rounded,
                    color: Colors.white,
                    size: 16,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _simulationDeviationEnabled ? 'Desviación ON' : 'Desviación OFF',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
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

  // ✅ Timer para simular caminata gestionado por TimerManagerMixin

  /// Devuelve el texto del botón de simulación según el paso actual
  String _getSimulationButtonLabel() {
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    if (activeNav == null) return 'TEST';

    final currentStep = activeNav.currentStep;
    if (currentStep == null) return 'TEST';

    switch (currentStep.type) {
      case 'walk':
        // Verificar si el siguiente paso es esperar el bus o es la caminata final
        if (activeNav.currentStepIndex < activeNav.steps.length - 1) {
          final nextStep = activeNav.steps[activeNav.currentStepIndex + 1];
          if (nextStep.type == 'wait_bus') {
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

    // ═══════════════════════════════════════════════════════════════
    // CASO ESPECIAL: WAIT_BUS - Usuario confirma que subió al bus
    // ═══════════════════════════════════════════════════════════════
    if (currentStep.type == 'wait_bus') {
      _log('🚌 [SIMULAR] Usuario confirmó que subió al bus desde wait_bus');
      
      // Detener tracking de llegadas (usuario ya subió al bus)
      _log('🛑 [ARRIVALS] Deteniendo tracking - usuario subió al bus');
      BusArrivalsService.instance.stopTracking();
      
      // Verificar que existe un siguiente paso de tipo ride_bus
      if (activeNav.currentStepIndex < activeNav.steps.length - 1) {
        final nextStep = activeNav.steps[activeNav.currentStepIndex + 1];
        
        if (nextStep.type == 'ride_bus') {
          // Dibujar la geometría del bus
          try {
            final busLeg = activeNav.itinerary.legs.firstWhere(
              (leg) => leg.type == 'bus' && leg.isRedBus,
              orElse: () => throw Exception('No bus leg found'),
            );
            
            final busGeometry = busLeg.geometry;
            
            if (busGeometry != null && busGeometry.isNotEmpty) {
              _log('🚌 [BUS] Dibujando ruta del bus: ${busGeometry.length} puntos');
              
              setState(() {
                _polylines = [
                  Polyline(
                    points: busGeometry,
                    color: const Color(0xFF2196F3), // Azul para ruta de bus
                    strokeWidth: 4.0,
                  ),
                ];
                // Actualizar marcadores para mostrar todos los paraderos
                _updateNavigationMarkers(nextStep, activeNav);
              });
            }
          } catch (e) {
            _log('⚠️ [BUS] Error dibujando geometría: $e');
          }
          
          // Vibración de confirmación
          final hasVibrator = await Vibration.hasVibrator();
          if (hasVibrator == true) {
            Vibration.vibrate(duration: 200);
          }
          
          // Anunciar TTS
          await TtsService.instance.speak('Subiendo al bus ${nextStep.busRoute}', urgent: true);
          await Future.delayed(const Duration(milliseconds: 800));
        } else {
          _log('⚠️ [SIMULAR] Siguiente paso no es ride_bus: ${nextStep.type}');
        }
      }
      
      // Avanzar al siguiente paso (ride_bus)
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
      
      // ✅ Planificar desviación aleatoria (40% probabilidad)
      _resetSimulationDeviation();
      _planSimulationDeviation(geometry);
      
      // ✅ Cancelar simulación previa usando TimerManagerMixin
      cancelTimer('walkSimulation');
      
      // Activar modo simulación para evitar auto-centrado
      setState(() {
        _isSimulating = true;
        // ✅ INICIALIZAR MARCADORES antes de comenzar la simulación
        _updateNavigationMarkers(currentStep, activeNav);
      });
      
      int currentPointIndex = 0;
      final totalPoints = geometry.length;
      final totalSimulationPoints = totalPoints + (_simulationDeviationRoute?.length ?? 0);
      final pointsPerInstruction = (totalPoints / (currentStep.streetInstructions?.length ?? 1)).ceil();
      
      // Variable para rastrear la última instrucción anunciada
      int lastAnnouncedInstruction = -1;
      
      // ✅ Timer periódico usando TimerManagerMixin
      createPeriodicTimer(
        const Duration(seconds: 5), // Reducido de 2 a 5 segundos para mejor control
        (timer) async {
        // ═══════════════════════════════════════════════════════════════
        // VERIFICAR SI LLEGAMOS AL DESTINO (últimos 2-3 puntos)
        // ═══════════════════════════════════════════════════════════════
        final isNearEnd = currentPointIndex >= totalSimulationPoints - 2;
        final isAtEnd = currentPointIndex >= totalSimulationPoints;
        
        if (isAtEnd) {
          cancelTimer('walkSimulation');
          _log('✅ [SIMULAR] Caminata completada - Llegamos al destino');
          
          // Resetear desviación
          _resetSimulationDeviation();
          
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
            // ═══════════════════════════════════════════════════════════════
            // DESTINO FINAL - Mantener polilínea visible
            // ═══════════════════════════════════════════════════════════════
            await TtsService.instance.speak('Has llegado a tu destino, ${currentStep.stopName}', urgent: true);
            
            // Mantener la última polilínea visible (no borrarla)
            setState(() {
              _polylines = [
                Polyline(
                  points: [geometry.last], // Solo punto final
                  color: const Color(0xFF10B981), // Verde para destino
                  strokeWidth: 6.0,
                ),
              ];
            });
            
            // Finalizar navegación después de un delay
            await Future.delayed(const Duration(seconds: 2));
            IntegratedNavigationService.instance.stopNavigation();
          } else {
            // ═══════════════════════════════════════════════════════════════
            // LLEGADA AL PARADERO - Proceso más realista
            // ═══════════════════════════════════════════════════════════════
            final nextStep = activeNav.steps[activeNav.currentStepIndex + 1];
            _log('🚏 [SIMULAR] Llegaste al paradero. Siguiente paso: ${nextStep.type}');
            
            if (nextStep.type == 'wait_bus') {
              // PRIMERO: Anunciar llegada ANTES de cambiar el paso
              await TtsService.instance.speak(
                'Has llegado al paradero ${nextStep.stopName}.',
                urgent: true,
              );
              
              await Future.delayed(const Duration(milliseconds: 800));
              
              // SEGUNDO: Avanzar al paso wait_bus
              IntegratedNavigationService.instance.advanceToNextStep();
              
              // ═══════════════════════════════════════════════════════════════
              // OBTENER TIEMPO DE LLEGADA DEL BUS
              // ═══════════════════════════════════════════════════════════════
              String waitMessage;
              final stopCode = nextStep.stopId;
              final routeNumber = nextStep.busRoute;
              
              if (stopCode != null && stopCode.isNotEmpty && routeNumber != null) {
                _log('📡 [ARRIVALS] Consultando llegada del bus $routeNumber en paradero $stopCode');
                final arrivals = await BusArrivalsService.instance.getBusArrivals(stopCode);
                
                if (arrivals != null) {
                  final targetBus = arrivals.findBus(routeNumber);
                  
                  if (targetBus != null) {
                    final minutes = targetBus.estimatedMinutes;
                    _log('� [ARRIVALS] Bus $routeNumber llegaría en $minutes minutos');
                    
                    if (minutes <= 0) {
                      waitMessage = 'El bus $routeNumber está llegando al paradero ahora.';
                    } else if (minutes <= 3) {
                      waitMessage = 'Prepárate, el bus $routeNumber está llegando al paradero.';
                    } else if (minutes <= 10) {
                      waitMessage = 'Espera el bus $routeNumber, llegaría en $minutes minutos.';
                    } else {
                      waitMessage = 'Espera el bus $routeNumber, llegaría en aproximadamente ${targetBus.formattedTime}.';
                    }
                  } else {
                    _log('⚠️ [ARRIVALS] Bus $routeNumber no encontrado en llegadas');
                    waitMessage = 'Espera el bus $routeNumber en este paradero.';
                  }
                } else {
                  _log('⚠️ [ARRIVALS] No se pudieron obtener llegadas para paradero $stopCode');
                  waitMessage = 'Espera el bus $routeNumber en este paradero.';
                }
              } else {
                _log('⚠️ [ARRIVALS] Sin código de paradero o ruta de bus');
                waitMessage = routeNumber != null 
                    ? 'Espera el bus $routeNumber en este paradero.'
                    : 'Espera el bus en este paradero.';
              }
              
              // TERCERO: Anunciar instrucción de espera CON TIEMPO ESTIMADO
              await TtsService.instance.speak(waitMessage, urgent: true);
              
              // CUARTO: Actualizar UI para mostrar paraderos
              if (mounted) {
                setState(() {
                  // Limpiar polilínea de caminata
                  _polylines = [];
                  // Actualizar marcadores para mostrar paraderos de bus
                  _updateNavigationMapState(IntegratedNavigationService.instance.activeNavigation!);
                });
              }
              
              _log('🚏 [SIMULAR] Paso actual ahora: wait_bus. Esperando que el usuario suba al bus.');
            } else {
              // Fallback si no hay wait_bus (no debería pasar)
              await TtsService.instance.speak('Llegaste al paradero', urgent: true);
              _log('⚠️ [SIMULAR] Siguiente paso no es wait_bus: ${nextStep.type}');
            }
          }
          return;
        }
        
        // ═══════════════════════════════════════════════════════════════
        // SIMULACIÓN CONTINUA - Moverse al siguiente punto
        // ═══════════════════════════════════════════════════════════════
        
        // ✅ Obtener siguiente punto (con lógica de desviación incluida)
        final nextPoint = _getNextSimulationPoint(geometry, currentPointIndex);
        
        // Mover GPS al siguiente punto (SIN mover el mapa para permitir interacción)
        _updateSimulatedGPS(nextPoint, moveMap: false);
        
        // ✅ ACTUALIZAR POLILÍNEA: mostrar solo el camino restante desde el punto actual
        // IMPORTANTE: Mantener al menos los últimos 2 puntos para que no desaparezca
        // Y MANTENER LOS MARCADORES (paradero destino, usuario, etc.)
        setState(() {
          final remainingGeometry = currentPointIndex < geometry.length 
              ? geometry.sublist(currentPointIndex)
              : [geometry.last]; // Mantener último punto si llegamos al final
          
          _polylines = [
            Polyline(
              points: remainingGeometry,
              color: isNearEnd 
                  ? const Color(0xFF10B981) // Verde cuando estamos cerca
                  : const Color(0xFFE30613), // Rojo normal
              strokeWidth: 5.0,
            ),
          ];
          
          // ✅ MANTENER MARCADORES: Actualizar marcadores en cada iteración
          // para que no desaparezcan durante la simulación
          _updateNavigationMarkers(currentStep, activeNav);
        });
        
        // Anunciar instrucción cuando se alcanza un nuevo segmento (solo si NO está desviado)
        if (!_isCurrentlyDeviated && 
            currentStep.streetInstructions != null && 
            currentStep.streetInstructions!.isNotEmpty) {
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
        // ✅ No necesita setState aquí porque se actualiza en el bloque anterior
      },
        name: 'walkSimulation',
      );
      
    } else if (currentStep.type == 'ride_bus') {
      // ═══════════════════════════════════════════════════════════════
      // SIMULAR VIAJE EN BUS: Mover GPS por cada parada
      // ═══════════════════════════════════════════════════════════════
      _log('🚌 [SIMULAR] Viaje en bus - Moviendo GPS por paradas');
      
      // Dar un pequeño delay antes de empezar
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
      
      // ✅ Cancelar timer previo usando TimerManagerMixin
      cancelTimer('walkSimulation');
      
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
      
      // ✅ Timer periódico usando TimerManagerMixin  
      createPeriodicTimer(
        const Duration(seconds: 8), // Reducido de 3 a 8 segundos para simular paradas de bus
        (timer) async {
        if (currentStopIndex >= allStops.length) {
          cancelTimer('walkSimulation');
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
          
          await TtsService.instance.speak('Bajaste del bus', urgent: true);
          
          // Pausa para que el usuario procese la información
          await Future.delayed(const Duration(milliseconds: 1500));
          
          // Avanzar al siguiente paso (probablemente walk final)
          if (activeNav.currentStepIndex < activeNav.steps.length - 1) {
            IntegratedNavigationService.instance.advanceToNextStep();
            
            // Anunciar el siguiente paso
            final nextStep = IntegratedNavigationService.instance.activeNavigation?.currentStep;
            if (nextStep?.type == 'walk') {
              await TtsService.instance.speak(
                'Ahora camina hacia tu destino final. Presiona "Simular" para continuar.',
                urgent: true,
              );
            }
            
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
      },
        name: 'walkSimulation',
      );
      
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

    // ✅ Configurar timeout usando TimerManagerMixin
    cancelTimer('speechTimeout');
    createTimer(
      _speechTimeout,
      () {
      if (_isListening) {
        _speech.stop();
        _showWarningNotification('Tiempo de escucha agotado');
      }
    },
      name: 'speechTimeout',
    );

    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;

        // Procesar resultado final
        if (result.finalResult) {
          cancelTimer('speechTimeout'); // ✅ Usar TimerManagerMixin
          _processRecognizedText(result.recognizedWords);
        } else {
          // ✅ Debounce usando TimerManagerMixin
          _pendingWords = result.recognizedWords;
          cancelTimer('resultDebounce');
          createTimer(
            const Duration(milliseconds: 300),
            () {
            if (!mounted) return;
            setState(() {
              _lastWords = _pendingWords;
            });
          },
            name: 'resultDebounce',
          );
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

    // ✅ Usar TimerManagerMixin para timeout de confirmación
    cancelTimer('confirmation');
    createTimer(
      const Duration(seconds: 15),
      () {
      if (_pendingConfirmationDestination != null) {
        _cancelDestinationConfirmation();
      }
    },
      name: 'confirmation',
    );

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
    cancelTimer('confirmation'); // ✅ Usar TimerManagerMixin

    setState(() {
      _pendingConfirmationDestination = null;
    });

    _showSuccessNotification('Destino confirmado', withVibration: true);
    TtsService.instance.speak('Perfecto, buscando ruta a $destination');

    _searchRouteToDestination(destination);
  }

  /// CAP-9: Cancelar confirmación de destino
  void _cancelDestinationConfirmation() {
    cancelTimer('confirmation'); // ✅ Usar TimerManagerMixin

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
  /// Ahora usa IntegratedNavigationService en lugar del sistema legacy
  Future<void> _recalculateRoute() async {
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    
    if (_currentPosition == null || activeNav == null) {
      _showWarningNotification('No hay navegación activa para recalcular');
      return;
    }

    final destName = activeNav.destinationName ?? 'destino';

    setState(() => _isCalculatingRoute = true);
    
    await TtsService.instance.speak('Recalculando ruta a $destName');

    try {
      // Usar IntegratedNavigationService para recalcular
      await _startIntegratedMoovitNavigation(
        destName,
        activeNav.destination.latitude,
        activeNav.destination.longitude,
      );

      _showSuccessNotification('Ruta recalculada exitosamente');
    } catch (e) {
      _log('❌ [RECALCULATE] Error: $e');
      _showErrorNotification('Error recalculando ruta');
    } finally {
      setState(() => _isCalculatingRoute = false);
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

      // ═══════════════════════════════════════════════════════════
      // ✅ INTENTAR CARGAR DESDE CACHÉ OFFLINE
      // ═══════════════════════════════════════════════════════════
      final cacheKey = _generateCacheKey(
        originLat: _currentPosition!.latitude.toStringAsFixed(4),
        originLon: _currentPosition!.longitude.toStringAsFixed(4),
        destLat: destLat.toStringAsFixed(4),
        destLon: destLon.toStringAsFixed(4),
        stepType: 'full_route',
      );

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
      
      // ═══════════════════════════════════════════════════════════
      // ✅ GUARDAR GEOMETRÍAS DE CADA PASO EN CACHÉ
      // ═══════════════════════════════════════════════════════════
      _cacheNavigationGeometries(navigation, cacheKey);
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

      // ===================================================================
      // CALLBACKS PARA TRACKING DE LLEGADAS EN TIEMPO REAL
      // ===================================================================
      IntegratedNavigationService.instance.onBusArrivalsUpdated = (arrivals) {
        if (!mounted) return;
        
        setState(() {
          _currentArrivals = arrivals;
        });
        
        _log('🔄 [ARRIVALS] UI actualizada: ${arrivals.arrivals.length} buses');
      };

      IntegratedNavigationService.instance.onBusMissed = (routeNumber) async {
        if (!mounted) return;
        
        _log('🚨 [RECALCULAR] Bus $routeNumber pasó - iniciando recálculo de ruta');
        
        setState(() {
          _needsRouteRecalculation = true;
        });
        
        // ===================================================================
        // ALERTAS AL USUARIO - MEJORADAS
        // ===================================================================
        // 1. Vibración de alerta (patrón fuerte)
        await Vibration.vibrate(pattern: [0, 300, 100, 300, 100, 300]);
        
        // 2. Mensaje claro y humano
        await TtsService.instance.speak(
          'El bus $routeNumber ya pasó por el paradero. Voy a verificar qué buses te pueden llevar a tu destino.',
          urgent: true,
        );
        
        // 3. Notificación visual
        _showErrorNotification('🚌 Bus $routeNumber pasó - Buscando alternativas...');
        
        // ===================================================================
        // RECÁLCULO DE RUTA
        // ===================================================================
        // Detener navegación actual
        IntegratedNavigationService.instance.stopNavigation();
        
        // Obtener destino actual
        final activeNav = IntegratedNavigationService.instance.activeNavigation;
        if (activeNav != null && _currentPosition != null) {
          final destination = activeNav.itinerary.destination; // Ya es LatLng
          
          // Recalcular ruta desde posición actual al mismo destino
          _log('🔄 [RECALCULAR] Origen: ${_currentPosition!.latitude},${_currentPosition!.longitude}');
          _log('🔄 [RECALCULAR] Destino: ${destination.latitude},${destination.longitude}');
          
          // Delay para que el usuario escuche el mensaje completo
          await Future.delayed(const Duration(seconds: 3));
          
          // TTS: Indicar que está calculando
          await TtsService.instance.speak('Calculando nuevas opciones de ruta...', urgent: false);
          
          // Iniciar nueva navegación
          try {
            final newNav = await IntegratedNavigationService.instance.startNavigation(
              originLat: _currentPosition!.latitude,
              originLon: _currentPosition!.longitude,
              destLat: destination.latitude,
              destLon: destination.longitude,
              destinationName: 'Destino', // Nombre genérico para recalculación
            );
            
            setState(() {
              _updateNavigationMapState(newNav);
              _needsRouteRecalculation = false;
            });
            
            // Verificar si encontró una nueva ruta con bus
            final hasRedBus = newNav.itinerary.redBusRoutes.isNotEmpty;
            String confirmationMessage;
            
            if (hasRedBus) {
              final newBuses = newNav.itinerary.redBusRoutes.join(', ');
              confirmationMessage = 'Encontré una nueva ruta. Puedes tomar el bus $newBuses. Continúa siguiendo las instrucciones.';
            } else {
              confirmationMessage = 'Nueva ruta calculada. Continúa siguiendo las instrucciones.';
            }
            
            await TtsService.instance.speak(confirmationMessage);
            _showSuccessNotification('✅ Nueva ruta encontrada');
            
          } catch (e) {
            _log('❌ [RECALCULAR] Error: $e');
            
            // Mensaje de error más amigable
            await TtsService.instance.speak(
              'Lo siento, no pude encontrar una nueva ruta. Por favor, intenta buscar manualmente.',
              urgent: true,
            );
            
            _showErrorNotification('❌ No se encontró ruta alternativa');
            
            setState(() {
              _needsRouteRecalculation = false;
              _hasActiveTrip = false;
            });
          }
        }
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
      _log('🗺️ [MAP] WAIT_BUS: Polilínea limpia (esperando confirmación)');
    } else if (navigation.currentStep?.type == 'ride_bus') {
      // Mantener la geometría del bus (ya dibujada en wait_bus)
      // NO sobrescribir si ya existe
      if (_polylines.isEmpty || _polylines.first.color != const Color(0xFF2196F3)) {
        // Si no hay polilínea azul, dibujarla ahora (caso de restauración)
        final busGeometry = _cachedStepGeometry;
        if (busGeometry.isNotEmpty) {
          _polylines = [
            Polyline(
              points: busGeometry,
              color: const Color(0xFF2196F3), // Azul para bus
              strokeWidth: 4.0,
            ),
          ];
          _log('🗺️ [MAP] RIDE_BUS: Polilínea azul restaurada (${busGeometry.length} puntos)');
        }
      } else {
        _log('🗺️ [MAP] RIDE_BUS: Polilínea azul mantenida');
      }
    } else {
      // Caminata: mostrar polilínea roja
      _polylines = _cachedStepGeometry.isNotEmpty
          ? [
              Polyline(
                points: _cachedStepGeometry,
                color: const Color(0xFFE30613), // Rojo para walk
                strokeWidth: 5.0,
              ),
            ]
          : [];
      _log('🗺️ [MAP] WALK: Polilínea roja (${_cachedStepGeometry.length} puntos)');
    }

    // Actualizar marcadores
    _updateNavigationMarkers(navigation.currentStep, navigation);
    
    // NO AUTO-CENTRAR - el usuario tiene control total del mapa en todo momento
    // El centrado solo ocurre al cargar el mapa inicialmente
  }

  /// Obtiene la geometría del paso actual usando caché para optimización
  /// ✅ Aplica compresión Douglas-Peucker automáticamente
  List<LatLng> _getCurrentStepGeometryCached() {
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    if (activeNav == null) return [];
    
    final currentStepIndex = activeNav.currentStepIndex;
    
    // Usar caché si el índice no ha cambiado
    if (_cachedStepIndex == currentStepIndex && _cachedStepGeometry.isNotEmpty) {
      return _cachedStepGeometry;
    }
    
    // Obtener geometría del servicio
    var geometry = IntegratedNavigationService.instance.currentStepGeometry;
    
    // ✅ Aplicar compresión Douglas-Peucker si la geometría tiene muchos puntos
    if (geometry.length > 50) {
      final originalLength = geometry.length;
      
      // Epsilon adaptativo según la cantidad de puntos
      // Rutas cortas: más detalle, rutas largas: más compresión
      double epsilon = 0.0001; // ~11 metros por defecto
      if (geometry.length > 200) {
        epsilon = 0.00015; // ~17 metros para rutas muy largas
      } else if (geometry.length > 500) {
        epsilon = 0.0002; // ~22 metros para rutas extensas
      }
      
      geometry = PolylineCompression.compress(
        points: geometry,
        epsilon: epsilon,
      );
      
      final reduction = ((1 - geometry.length / originalLength) * 100);
      _log(
        '🗜️ [COMPRESS] Geometría del paso comprimida: $originalLength → ${geometry.length} pts '
        '(${reduction.toStringAsFixed(1)}% reducción, epsilon=$epsilon)',
      );
    }
    
    // Actualizar caché con geometría comprimida
    _cachedStepGeometry = geometry;
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

    // Marcador de la ubicación del usuario (solo la flecha de navegación)
    if (_currentPosition != null) {
      newMarkers.add(
        Marker(
          point: LatLng(
            _currentPosition!.latitude,
            _currentPosition!.longitude,
          ),
          child: const Icon(
            Icons.navigation,
            color: Colors.blue,
            size: 32,
            shadows: [
              Shadow(
                color: Colors.black54,
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
        ),
      );
    }

    // ═══════════════════════════════════════════════════════════════
    // MOSTRAR PARADEROS DE BUS
    // - Durante WALK hacia el paradero: Mostrar solo el DESTINO (paradero de subida)
    // - Durante WAIT_BUS: Mostrar subida y bajada
    // - Durante RIDE_BUS: Mostrar todas las paradas
    // ═══════════════════════════════════════════════════════════════
    final shouldShowBusStops = currentStep?.type == 'walk' || currentStep?.type == 'wait_bus' || currentStep?.type == 'ride_bus';
    
    if (shouldShowBusStops) {
      _log('🔍 [MARKERS] Buscando leg de bus en itinerario...');
      try {
        final busLeg = navigation.itinerary.legs.firstWhere(
          (leg) => leg.type == 'bus' && leg.isRedBus,
          orElse: () => throw Exception('No bus leg found'),
        );

        _log('✅ [MARKERS] Leg de bus encontrado');

        final isWalking = currentStep?.type == 'walk';
        final isRidingBus = currentStep?.type == 'ride_bus';
        final isWaitingBus = currentStep?.type == 'wait_bus';
        _log('🚌 [MARKERS] Estado: walk=$isWalking, wait=$isWaitingBus, ride=$isRidingBus');

      // ═══════════════════════════════════════════════════════════════
      // DISEÑO ÚNICO DE PARADEROS - Simplificado y consistente
      // ═══════════════════════════════════════════════════════════════
      
      final stops = busLeg.stops;
      if (stops != null && stops.isNotEmpty) {
        _log('📍 [MARKERS] Procesando ${stops.length} paradas del bus');
        
        // Determinar qué paraderos mostrar según el estado
        final List<int> visibleStopIndices = [];
        
        if (isWalking) {
          // CAMINANDO: NO mostrar paraderos aquí
          // El paradero destino se mostrará con un marcador especial más abajo
          _log('🚶 [MARKERS] Modo CAMINATA: NO mostrar paraderos del busLeg');
        } else if (isWaitingBus) {
          // ESPERANDO: Mostrar SUBIDA y BAJADA
          visibleStopIndices.add(0); // Subida
          if (stops.length > 1) {
            visibleStopIndices.add(stops.length - 1); // Bajada
          }
          _log('🚏 [MARKERS] Modo ESPERA: Mostrando paraderos de subida y bajada');
        } else if (isRidingBus) {
          // DURANTE el viaje: Mostrar todas las paradas
          for (int i = 0; i < stops.length; i++) {
            visibleStopIndices.add(i);
          }
          _log('🚌 [MARKERS] Modo VIAJE: Mostrando todas las paradas');
        }
        
        // Crear marcadores con diseño formal y empresarial
        for (final index in visibleStopIndices) {
          final stop = stops[index];
          final isFirst = index == 0;
          final isLast = index == stops.length - 1;
          final isCurrent = _isSimulating && index == _currentSimulatedBusStopIndex;
          
          newMarkers.add(
            Marker(
              point: stop.location,
              width: 150,
              height: 80,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  // Nombre del paradero arriba
                  Positioned(
                    top: 0,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 140),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B), // Gris oscuro profesional
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        stop.name ?? 'Paradero ${index + 1}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                          height: 1.2,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  // Ícono del bus (flat design, sin círculo)
                  Positioned(
                    bottom: 10,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: isCurrent ? const Color(0xFFEF6C00) : const Color(0xFFD84315), // Naranja corporativo
                        borderRadius: BorderRadius.circular(6),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.directions_bus,
                        color: Colors.white,
                        size: isCurrent ? 28 : 24,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
          
          _log('🚏 [MARKERS] Paradero ${index + 1}/${stops.length}: ${stop.name} ${isCurrent ? "(ACTUAL)" : ""}');
        }
        
        _log('🗺️ [MARKERS] Creados ${visibleStopIndices.length} marcadores de paradero');
      }
      } catch (e) {
        _log('⚠️ [MARKERS] No hay leg de bus en este itinerario: $e');
      }
    } else {
      _log('🚫 [MARKERS] No mostrar paraderos - paso actual: ${currentStep?.type}');
    }

    // ═══════════════════════════════════════════════════════════════
    // MARCADOR DE PARADERO DESTINO durante WALK
    // Mostrar el paradero destino con diseño naranja profesional
    // Usa el ÚLTIMO punto de la geometría walk (destino real)
    // ═══════════════════════════════════════════════════════════════
    if (currentStep?.type == 'walk' && currentStep?.location != null) {
      final nextStep = navigation.currentStepIndex < navigation.steps.length - 1
          ? navigation.steps[navigation.currentStepIndex + 1]
          : null;
      
      // Verificar si el siguiente paso es wait_bus (paradero)
      if (nextStep?.type == 'wait_bus' && nextStep?.stopName != null) {
        // Obtener el último punto de la geometría walk (destino exacto)
        final walkGeometry = _getCurrentStepGeometryCached();
        final paraderoLocation = walkGeometry.isNotEmpty 
            ? walkGeometry.last  // Usar último punto de la geometría
            : currentStep!.location!;  // Fallback a currentStep.location
        
        _log('🚏 [MARKERS] Mostrando paradero destino: ${nextStep!.stopName} en $paraderoLocation');
        
        newMarkers.add(
          Marker(
            point: paraderoLocation,
            width: 160,
            height: 100,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.topCenter,
              children: [
                // Nombre del paradero arriba
                Positioned(
                  top: 0,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Text(
                      nextStep.stopName!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                        height: 1.2,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                // Pin de ubicación estilo Google Maps/RED (globo rojo)
                Positioned(
                  top: 35,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Globo del pin
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: const Color(0xFFD84315), // Rojo corporativo RED
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 8,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.directions_bus_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                      // Punta del pin (triángulo hacia abajo)
                      CustomPaint(
                        size: const Size(12, 8),
                        painter: _PinTipPainter(color: const Color(0xFFD84315)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        _log('🚫 [MARKERS] Siguiente paso no es wait_bus: ${nextStep?.type}');
      }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARCADOR DEL DESTINO FINAL
    // Solo mostrar cuando estemos en el ÚLTIMO paso de la navegación
    // ═══════════════════════════════════════════════════════════════
    final isLastStep = navigation.currentStepIndex >= navigation.steps.length - 1;
    if (isLastStep) {
      final lastStep = navigation.steps.last;
      if (lastStep.location != null) {
        _log('🏁 [MARKERS] ÚLTIMO PASO - Mostrando destino final en ${lastStep.location}');
        newMarkers.add(
          Marker(
            point: lastStep.location!,
            width: 150,
            height: 80,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                // Etiqueta "Destino"
                Positioned(
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'Destino',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
                // Pin de ubicación (flat design)
                Positioned(
                  bottom: 10,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2E7D32), // Verde corporativo
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.location_on,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    } else {
      _log('🚫 [MARKERS] NO es el último paso - Destino final NO visible');
    }

    // Actualizar marcadores
    _log('🗺️ [MARKERS] ═══════════════════════════════════════════════════════');
    _log('🗺️ [MARKERS] TOTAL DE MARCADORES CREADOS: ${newMarkers.length}');
    _log('🗺️ [MARKERS] Paso actual: ${currentStep?.type} (${navigation.currentStepIndex + 1}/${navigation.steps.length})');
    _log('🗺️ [MARKERS] Es último paso: $isLastStep');
    _log('🗺️ [MARKERS] ═══════════════════════════════════════════════════════');
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

  // ═══════════════════════════════════════════════════════════════
  // MÉTODOS LEGACY ELIMINADOS
  // ═══════════════════════════════════════════════════════════════
  // ❌ _calculateRoute() - Obsoleto, ahora se usa IntegratedNavigationService
  // ❌ _displayRoute() - Obsoleto, todo viene de IntegratedNavigationService
  // ❌ _displayFallbackRoute() - Obsoleto, no se usa ruta de demostración

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

  // ═══════════════════════════════════════════════════════════════════════
  // MÉTODOS DE CACHÉ Y COMPRESIÓN DE GEOMETRÍAS
  // ═══════════════════════════════════════════════════════════════════════

  /// Intenta cargar geometría desde caché, si no existe la obtiene del servicio
  /// y la guarda comprimida para uso futuro
  Future<List<LatLng>> _getOrCacheGeometry({
    required String cacheKey,
    required Future<List<LatLng>> Function() fetchGeometry,
    bool compress = true,
    double epsilon = 0.0001,
  }) async {
    try {
      // 1. Intentar cargar desde caché
      final cached = await GeometryCacheService.instance.getRoute(cacheKey);
      if (cached != null && cached.isNotEmpty) {
        _log('💾 [CACHE] Geometría cargada desde caché: $cacheKey (${cached.length} pts)');
        return cached;
      }

      // 2. No hay caché, obtener desde servicio
      _log('🌐 [CACHE] No hay caché, obteniendo desde servicio: $cacheKey');
      final geometry = await fetchGeometry();

      if (geometry.isEmpty) {
        _log('⚠️ [CACHE] Geometría vacía desde servicio: $cacheKey');
        return geometry;
      }

      // 3. Guardar en caché (comprimido si es necesario)
      unawaited(
        GeometryCacheService.instance.saveRoute(
          key: cacheKey,
          geometry: geometry,
          compress: compress,
          epsilon: epsilon,
          metadata: {
            'timestamp': DateTime.now().toIso8601String(),
            'source': 'integrated_navigation',
          },
        ),
      );

      // 4. Retornar comprimido si se solicitó
      if (compress) {
        final compressed = PolylineCompression.compress(
          points: geometry,
          epsilon: epsilon,
        );
        _log(
          '🗜️ [COMPRESS] ${geometry.length} → ${compressed.length} pts '
          '(${((1 - compressed.length / geometry.length) * 100).toStringAsFixed(1)}% reducción)',
        );
        return compressed;
      }

      return geometry;
    } catch (e, st) {
      _log('❌ [CACHE] Error en getOrCacheGeometry: $e', error: e, stackTrace: st);
      // Fallback: intentar obtener sin caché
      try {
        return await fetchGeometry();
      } catch (e2) {
        _log('❌ [CACHE] Error en fallback: $e2');
        return [];
      }
    }
  }

  /// Genera una clave de caché única para una geometría de paso
  String _generateCacheKey({
    required String originLat,
    required String originLon,
    required String destLat,
    required String destLon,
    required String stepType,
    int? stepIndex,
  }) {
    // Redondear coordenadas a 4 decimales (aprox. 11m de precisión)
    // para agrupar rutas similares
    final origin = '${originLat}_${originLon}';
    final dest = '${destLat}_${destLon}';
    final step = stepIndex != null ? '${stepType}_$stepIndex' : stepType;
    
    return 'route_${origin}_to_${dest}_$step';
  }

  /// Comprime una lista de puntos usando Douglas-Peucker
  /// Útil para polilíneas ya obtenidas que necesitan optimización
  List<LatLng> _compressPolyline(List<LatLng> points, {double epsilon = 0.0001}) {
    if (points.length <= 2) return points;

    final compressed = PolylineCompression.compress(
      points: points,
      epsilon: epsilon,
    );

    final reduction = (1 - compressed.length / points.length) * 100;
    _log(
      '🗜️ [COMPRESS] Douglas-Peucker: ${points.length} → ${compressed.length} pts '
      '(${reduction.toStringAsFixed(1)}% reducción, epsilon=$epsilon)',
    );

    return compressed;
  }

  /// Obtiene estadísticas del caché para debugging/monitoring
  Future<void> _logCacheStats() async {
    try {
      final stats = await GeometryCacheService.instance.getStats();
      _log('📊 [CACHE STATS] ${stats.toString()}');
    } catch (e) {
      _log('⚠️ [CACHE] Error obteniendo stats: $e');
    }
  }

  /// Cachea las geometrías de todos los pasos de navegación en background
  void _cacheNavigationGeometries(ActiveNavigation navigation, String routeCacheKey) {
    // Ejecutar en background para no bloquear UI
    Future(() async {
      try {
        int cached = 0;
        
        for (int i = 0; i < navigation.steps.length; i++) {
          final step = navigation.steps[i];
          
          // Obtener geometría del paso desde el servicio
          List<LatLng> geometry = [];
          if (step.type == 'walk' || step.type == 'ride_bus') {
            // Buscar geometría en los legs del itinerario
            try {
              if (step.type == 'walk') {
                // Buscar leg de caminata correspondiente
                final walkLegs = navigation.itinerary.legs
                    .where((leg) => leg.type == 'walk')
                    .toList();
                
                if (i < walkLegs.length && walkLegs[i].geometry != null) {
                  geometry = walkLegs[i].geometry!;
                }
              } else if (step.type == 'ride_bus') {
                // Buscar leg de bus
                final busLeg = navigation.itinerary.legs
                    .firstWhere((leg) => leg.type == 'bus');
                
                if (busLeg.geometry != null) {
                  geometry = busLeg.geometry!;
                }
              }
            } catch (e) {
              _log('⚠️ [CACHE] No se pudo obtener geometría para paso $i: $e');
              continue;
            }
          }
          
          if (geometry.isEmpty) continue;
          
          // Generar clave única para este paso
          final stepKey = '${routeCacheKey}_step_$i';
          
          // Guardar en caché comprimido
          final success = await GeometryCacheService.instance.saveRoute(
            key: stepKey,
            geometry: geometry,
            compress: true,
            epsilon: geometry.length > 200 ? 0.00015 : 0.0001,
            ttl: const Duration(days: 7),
            metadata: {
              'stepType': step.type,
              'stepIndex': i,
              'instruction': step.instruction,
              'timestamp': DateTime.now().toIso8601String(),
            },
          );
          
          if (success) cached++;
        }
        
        _log('💾 [CACHE] Guardados $cached/${navigation.steps.length} pasos en caché offline');
        
        // Log de estadísticas
        await _logCacheStats();
      } catch (e, st) {
        _log('❌ [CACHE] Error cacheando geometrías de navegación: $e', error: e, stackTrace: st);
      }
    });
  }

  @override
  @override
  void dispose() {
    // ✅ TimerManagerMixin limpia automáticamente: feedback, confirmation, speechTimeout, walkSimulation, resultDebounce

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
    
    // PANEL ESPECIAL para wait_bus: Mostrar información del bus esperado
    if (currentStep?.type == 'wait_bus') {
      final busRoute = currentStep.busRoute ?? '';
      final stopName = currentStep.stopName ?? 'Destino';
      
      // Obtener información de paradas del siguiente paso (ride_bus)
      int totalStops = 0;
      int remainingStops = 0;
      String destination = stopName;
      
      // Buscar el siguiente paso ride_bus para obtener destino y paradas
      final activeNav = IntegratedNavigationService.instance.activeNavigation;
      if (activeNav != null && activeNav.currentStepIndex < activeNav.steps.length - 1) {
        final nextStep = activeNav.steps[activeNav.currentStepIndex + 1];
        if (nextStep.type == 'ride_bus') {
          totalStops = nextStep.totalStops ?? 0;
          remainingStops = totalStops; // Al inicio, todas las paradas faltan
          destination = nextStep.stopName ?? stopName;
        }
      }
      
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
                                destination,
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
                          // Parada inicial
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
                              const Text(
                                '1',
                                style: TextStyle(
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
                          // Paradas restantes (todas al inicio)
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
              const SizedBox(height: 16),
              // Botón de micrófono (igual que antes pero fuera del panel)
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
            ],
          ),
        ),
      );
    }
    
    // PANEL ESPECIAL para ride_bus: Muestra progreso del viaje en bus
    if (currentStep?.type == 'ride_bus') {
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
    final isBusRelated = currentStep?.type == 'wait_bus' || currentStep?.type == 'ride_bus';

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), // Panel cerca del borde inferior
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                          isWalking ? Icons.directions_walk : isBusRelated ? Icons.directions_bus : Icons.access_time,
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

  // ============================================================================
  // SIMULACIÓN REALISTA CON DESVIACIONES
  // ============================================================================

  /// Planifica una desviación aleatoria en la simulación de caminata
  /// Genera un punto de desviación y una ruta de regreso
  void _planSimulationDeviation(List<LatLng> originalGeometry) {
    if (!_simulationDeviationEnabled || originalGeometry.length < 20) {
      _simulationDeviationStep = -1;
      _simulationDeviationRoute = null;
      return;
    }

    final random = math.Random();
    
    // 40% de probabilidad de desviarse durante la simulación
    if (random.nextDouble() > 0.4) {
      _simulationDeviationStep = -1;
      _simulationDeviationRoute = null;
      return;
    }

    // Desviarse entre el 30% y 70% del recorrido
    final minIndex = (originalGeometry.length * 0.3).toInt();
    final maxIndex = (originalGeometry.length * 0.7).toInt();
    _simulationDeviationStep = minIndex + random.nextInt(maxIndex - minIndex);

    // Generar ruta de desviación (perpendicular a la ruta correcta)
    final deviationPoint = originalGeometry[_simulationDeviationStep];
    final nextPoint = _simulationDeviationStep < originalGeometry.length - 1
        ? originalGeometry[_simulationDeviationStep + 1]
        : originalGeometry[_simulationDeviationStep - 1];

    // Calcular vector perpendicular
    final dx = nextPoint.longitude - deviationPoint.longitude;
    final dy = nextPoint.latitude - deviationPoint.latitude;
    
    // Vector perpendicular (rotar 90 grados)
    final perpDx = -dy;
    final perpDy = dx;
    
    // Normalizar y escalar (desviación de 60-80 metros)
    final length = math.sqrt(perpDx * perpDx + perpDy * perpDy);
    final deviationDistance = 0.0006 + random.nextDouble() * 0.0002; // ~60-80m
    final normDx = (perpDx / length) * deviationDistance;
    final normDy = (perpDy / length) * deviationDistance;

    // Punto de máxima desviación
    final maxDeviationPoint = LatLng(
      deviationPoint.latitude + normDy,
      deviationPoint.longitude + normDx,
    );

    // Crear ruta de desviación: salida gradual (4 puntos) + regreso gradual (5 puntos)
    _simulationDeviationRoute = [
      // Salida gradual de la ruta
      LatLng(
        deviationPoint.latitude + normDy * 0.25,
        deviationPoint.longitude + normDx * 0.25,
      ),
      LatLng(
        deviationPoint.latitude + normDy * 0.5,
        deviationPoint.longitude + normDx * 0.5,
      ),
      LatLng(
        deviationPoint.latitude + normDy * 0.75,
        deviationPoint.longitude + normDx * 0.75,
      ),
      maxDeviationPoint,
      // Regreso gradual a la ruta
      LatLng(
        deviationPoint.latitude + normDy * 0.75,
        deviationPoint.longitude + normDx * 0.75,
      ),
      LatLng(
        deviationPoint.latitude + normDy * 0.5,
        deviationPoint.longitude + normDx * 0.5,
      ),
      LatLng(
        deviationPoint.latitude + normDy * 0.25,
        deviationPoint.longitude + normDx * 0.25,
      ),
      // Punto de regreso (siguiente en la ruta original)
      _simulationDeviationStep < originalGeometry.length - 5
          ? originalGeometry[_simulationDeviationStep + 5]
          : originalGeometry.last,
    ];

    _log('🎲 [SIMULACIÓN] Desviación planificada en punto $_simulationDeviationStep/${originalGeometry.length}');
    _log('   Distancia de desviación: ~${(deviationDistance * 111000).toInt()}m');
  }

  /// Obtiene el siguiente punto GPS para la simulación (con o sin desviación)
  LatLng _getNextSimulationPoint(List<LatLng> originalGeometry, int currentIndex) {
    // Si estamos en el punto de desviación, comenzar a seguir la ruta de desviación
    if (currentIndex == _simulationDeviationStep && _simulationDeviationRoute != null && !_isCurrentlyDeviated) {
      _isCurrentlyDeviated = true;
      _log('⚠️ [SIMULACIÓN] Iniciando desviación de ruta...');
      return _simulationDeviationRoute!.first;
    }

    // Si estamos desviados, seguir la ruta de desviación
    if (_isCurrentlyDeviated && _simulationDeviationRoute != null) {
      final deviationIndex = currentIndex - _simulationDeviationStep;
      
      if (deviationIndex < _simulationDeviationRoute!.length) {
        final deviationPoint = _simulationDeviationRoute![deviationIndex];
        
        // Último punto de desviación = regreso a la ruta
        if (deviationIndex == _simulationDeviationRoute!.length - 1) {
          _log('✅ [SIMULACIÓN] Regresando a la ruta correcta...');
          _isCurrentlyDeviated = false;
        }
        
        return deviationPoint;
      } else {
        // Terminar desviación y continuar con ruta original
        _isCurrentlyDeviated = false;
        final newIndex = _simulationDeviationStep + _simulationDeviationRoute!.length;
        return newIndex < originalGeometry.length 
            ? originalGeometry[newIndex]
            : originalGeometry.last;
      }
    }

    // Navegación normal por la ruta original
    return currentIndex < originalGeometry.length 
        ? originalGeometry[currentIndex]
        : originalGeometry.last;
  }

  /// Resetea el estado de desviación al iniciar nueva simulación
  void _resetSimulationDeviation() {
    _simulationDeviationStep = -1;
    _simulationDeviationRoute = null;
    _isCurrentlyDeviated = false;
  }
}

/// Widget optimizado para el marcador de ubicación del usuario
/// Diseño empresarial con flecha de navegación tipo GPS
class _UserLocationMarkerWidget extends StatelessWidget {
  const _UserLocationMarkerWidget();

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Círculo de precisión (sutil)
        Container(
          width: 70,
          height: 70,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF1565C0).withValues(alpha: 0.1),
            border: Border.all(
              color: const Color(0xFF1565C0).withValues(alpha: 0.2),
              width: 1,
            ),
          ),
        ),
        // Triángulo/Flecha de navegación principal
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF1565C0), // Azul corporativo
            borderRadius: BorderRadius.circular(6),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: const Icon(
            Icons.navigation, // Triángulo de navegación
            color: Colors.white,
            size: 28,
          ),
        ),
      ],
    );
  }
}

/// Painter para dibujar la punta triangular del pin de ubicación
class _PinTipPainter extends CustomPainter {
  final Color color;

  _PinTipPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path()
      ..moveTo(size.width / 2, size.height) // Punta del triángulo (abajo centro)
      ..lineTo(0, 0) // Esquina superior izquierda
      ..lineTo(size.width, 0) // Esquina superior derecha
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
