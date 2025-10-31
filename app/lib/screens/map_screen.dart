import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../blocs/location/location_bloc.dart';
import '../blocs/location/location_state.dart';
import '../blocs/location/location_event.dart';
import '../blocs/navigation/navigation_bloc.dart';
import '../blocs/navigation/navigation_state.dart';
import '../blocs/navigation/navigation_event.dart';
import '../blocs/map/map_bloc.dart';
import '../blocs/map/map_state.dart';
import '../blocs/map/map_event.dart';
import '../services/debug_logger.dart';
import '../services/device/tts_service.dart';
import '../services/navigation_route_service.dart';
import '../services/backend/server_config.dart';
import '../widgets/bottom_nav.dart';

// EventChannel para botón de volumen (Android nativo)
const EventChannel _volumeChannel = EventChannel('com.wayfindcl/volume_button');

/// ============================================================================
/// MAP SCREEN REFACTORIZADO - Usando BLoC Pattern
/// ============================================================================
/// Antes: 5,409 líneas (God Object)
/// Después: ~500 líneas (Solo UI)
///
/// Arquitectura:
/// - LocationBloc: Gestión GPS
/// - NavigationBloc: Rutas y navegación
/// - TtsService: Texto a voz (singleton)
/// - MapBloc: Estado visual del mapa
///
/// Beneficios:
/// - 90% menos código en MapScreen
/// - Testeable (BLoCs separados)
/// - Mantenible (separación de responsabilidades)
/// - Rendimiento (rebuilds selectivos)

class MapScreen extends StatefulWidget {
  final String? welcomeMessage;

  const MapScreen({super.key, this.welcomeMessage});

  static const routeName = '/map';

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  bool _isFollowingUser = true; // Flag para evitar spam de logs
  bool _hasInitialCentering = false; // Flag para centrar en usuario al inicio

  // Variables para reconocimiento de voz
  final SpeechToText _speech = SpeechToText();
  bool _speechAvailable = false;
  bool _isListening = false;
  String _lastWords = '';

  @override
  void initState() {
    super.initState();
    _initializeScreen();
    _initializeSpeech();
    _setupVolumeButtonListener();
  }

  /// Configurar listener para botón de volumen (Android nativo)
  void _setupVolumeButtonListener() {
    _volumeChannel.receiveBroadcastStream().listen((event) {
      if (event == 'volume_up_down') {
        _startListening();
      } else if (event == 'volume_up_up') {
        _stopListening();
      }
    });
  }

  /// Inicializar reconocimiento de voz
  Future<void> _initializeSpeech() async {
    try {
      _speechAvailable = await _speech.initialize(
        onError: (error) =>
            DebugLogger.error('Error de voz: $error', context: 'MapScreen'),
        onStatus: (status) {
          DebugLogger.info('Estado de voz: $status', context: 'MapScreen');
        },
      );

      if (_speechAvailable) {
        setState(() {});
      }
    } catch (e) {
      DebugLogger.error('Error inicializando voz: $e', context: 'MapScreen');
    }
  }

  /// Inicializar pantalla
  void _initializeScreen() {
    DebugLogger.info('Inicializando MapScreen', context: 'MapScreen');

    // Inicializar GPS primero
    context.read<LocationBloc>().add(const LocationStarted());

    // Inicializar mapa con centro en Santiago por defecto
    // Se actualizará automáticamente cuando GPS obtenga ubicación
    context.read<MapBloc>().add(
      MapInitialized(
        initialCenter: const LatLng(-33.4489, -70.6693),
        initialZoom: 15.0,
      ),
    );

    // Habilitar seguimiento de usuario automáticamente
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<MapBloc>().add(const MapCenterOnUserRequested());
    });

    // Mostrar mensaje de bienvenida si existe - CON RETRASO para que el usuario escuche bien
    if (widget.welcomeMessage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        // Esperar 1 segundo para que la pantalla se estabilice y el usuario esté listo
        await Future.delayed(const Duration(milliseconds: 1500));
        _speak(widget.welcomeMessage!);
      });
    }
  }

  /// Hablar con TTS
  void _speak(String text) {
    TtsService.instance.speak(text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ===================================================================
          // MAPA BASE CON MARCADOR GPS DEL USUARIO
          // ===================================================================
          _buildMap(),

          // ===================================================================
          // PÍLDORA SUPERIOR (Nombre de usuario + Badge IA)
          // ===================================================================
          _buildUserPill(),

          // ===================================================================
          // PANEL DE NAVEGACIÓN (si hay navegación activa)
          // ===================================================================
          _buildNavigationPanel(),

          // ===================================================================
          // CONTROLES DEL MAPA (zoom, centrar en usuario)
          // ===================================================================
          _buildMapControls(),

          // ===================================================================
          // BOTÓN DE SETTINGS (bottom-right) - Diseño Figma
          // ===================================================================
          _buildSettingsButton(),

          // ===================================================================
          // PANEL "PROCESANDO RUTA..." (bottom) - Diseño Figma
          // ===================================================================
          _buildProcessingPanel(),

          // ===================================================================
          // BOTÓN DE VOZ (crítico para comandos de voz)
          // ===================================================================
          _buildVoiceButton(),

          // ===================================================================
          // INDICADOR DE GPS (oculto en diseño Figma)
          // ===================================================================
          _buildLocationIndicator(),
        ],
      ),
      bottomNavigationBar: const BottomNavBar(currentIndex: 0),
    );
  }

  /// Construir mapa con BlocBuilder
  Widget _buildMap() {
    return BlocBuilder<MapBloc, MapState>(
      builder: (context, mapState) {
        if (mapState is MapLoading) {
          return const Center(child: CircularProgressIndicator());
        }

        if (mapState is MapError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text(mapState.message),
              ],
            ),
          );
        }

        if (mapState is! MapLoaded) {
          return const SizedBox.shrink();
        }

        return BlocListener<LocationBloc, LocationState>(
          listener: (context, locationState) {
            if (locationState is LocationLoaded) {
              final userLatLng = LatLng(
                locationState.position.latitude,
                locationState.position.longitude,
              );

              // Centrar en usuario la primera vez que obtenemos ubicación
              if (!_hasInitialCentering) {
                _hasInitialCentering = true;
                _isFollowingUser = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _mapController.move(userLatLng, mapState.zoom);
                });
                DebugLogger.info(
                  'Mapa centrado en usuario por primera vez',
                  context: 'MapScreen',
                );
                return;
              }

              // Seguir al usuario solo si el seguimiento está activo
              final currentMapState = context.read<MapBloc>().state;
              if (currentMapState is MapLoaded &&
                  currentMapState.followUserLocation &&
                  _isFollowingUser) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _mapController.move(userLatLng, mapState.zoom);
                });
              }
            }
          },
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: mapState.center,
              initialZoom: mapState.zoom,
              minZoom: 11, // Zoom mínimo para mantener Santiago visible
              maxZoom: 18,
              // Límites geográficos de Santiago de Chile
              cameraConstraint: CameraConstraint.contain(
                bounds: LatLngBounds(
                  const LatLng(-33.65, -70.85), // Suroeste (Maipú, San Bernardo)
                  const LatLng(-33.35, -70.45), // Noreste (Las Condes, Colina)
                ),
              ),
              onPositionChanged: (position, hasGesture) {
                // Solo desactivar seguimiento si el usuario mueve el mapa manualmente
                // Y solo disparar el evento UNA VEZ para evitar spam
                if (hasGesture && _isFollowingUser) {
                  _isFollowingUser = false;
                  context.read<MapBloc>().add(
                    const MapFollowUserLocationToggled(follow: false),
                  );
                }

                // NO actualizar centro si el usuario está navegando manualmente
                // Esto evita que el blip se mueva cuando tocas el mapa
                // Solo actualizar si NO es gesto manual
                if (!hasGesture) {
                  context.read<MapBloc>().add(
                    MapCenterChanged(center: position.center, animate: false),
                  );
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.wayfindcl.app',
              ),

              if (mapState.polylines.isNotEmpty)
                PolylineLayer(polylines: mapState.polylines),

              if (mapState.circles.isNotEmpty)
                CircleLayer(circles: mapState.circles),

              if (mapState.markers.isNotEmpty)
                MarkerLayer(markers: mapState.markers),

              // ================================================================
              // MARCADOR GPS DEL USUARIO - Independiente, ubicación REAL
              // ================================================================
              BlocBuilder<LocationBloc, LocationState>(
                builder: (context, locationState) {
                  if (locationState is! LocationLoaded) {
                    return const SizedBox.shrink();
                  }

                  final userPosition = LatLng(
                    locationState.position.latitude,
                    locationState.position.longitude,
                  );

                  return MarkerLayer(
                    markers: [
                      Marker(
                        point: userPosition,
                        width: 80,
                        height: 80,
                        child: Transform.rotate(
                          angle: locationState.position.heading * 
                                 (3.14159 / 180), // Convertir a radianes
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // Círculo exterior con pulso
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeInOut,
                                width: 80,
                                height: 80,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2563EB).withOpacity(0.15),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              
                              // Círculo medio
                              Container(
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2563EB).withOpacity(0.3),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              
                              // Círculo principal con sombra
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFF3B82F6),
                                      Color(0xFF2563EB),
                                    ],
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                  ),
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF2563EB).withOpacity(0.5),
                                      blurRadius: 16,
                                      spreadRadius: 2,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 3,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.navigation,
                                  color: Colors.white,
                                  size: 26,
                                ),
                              ),
                              
                              // Punto de precisión en el centro
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.3),
                                      blurRadius: 4,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// Panel de navegación activa
  Widget _buildNavigationPanel() {
    return BlocBuilder<NavigationBloc, NavigationState>(
      builder: (context, state) {
        if (state is! NavigationActive) {
          return const SizedBox.shrink();
        }

        return Positioned(
          top: 60,
          left: 16,
          right: 16,
          child: AnimatedOpacity(
            opacity: 1.0,
            duration: const Duration(milliseconds: 300),
            child: Card(
              elevation: 8,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (state.currentInstruction != null) ...[
                      Row(
                        children: [
                          Image.asset(
                            state.currentInstruction!.iconAsset,
                            width: 48,
                            height: 48,
                            errorBuilder: (context, error, stackTrace) =>
                                const Icon(Icons.navigation, size: 48),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  state.currentInstruction!.text,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'En ${state.distanceToNextStepFormatted}',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 24),
                    ],

                    // Información de viaje
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildTripInfo(
                          icon: Icons.straighten,
                          label: 'Distancia',
                          value: state.totalDistanceRemainingFormatted,
                        ),
                        _buildTripInfo(
                          icon: Icons.access_time,
                          label: 'Tiempo',
                          value: state.estimatedTimeRemainingFormatted,
                        ),
                        _buildTripInfo(
                          icon: Icons.trending_up,
                          label: 'Progreso',
                          value: '${(state.progressPercentage * 100).toInt()}%',
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // Botón cancelar navegación
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          context.read<NavigationBloc>().add(
                            const NavigationStopped(reason: 'Usuario canceló'),
                          );
                        },
                        icon: const Icon(Icons.close),
                        label: const Text('Cancelar Navegación'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTripInfo({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Column(
      children: [
        Icon(icon, size: 20, color: Colors.grey),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }

  /// Controles del mapa - Diseño optimizado (compactos y semi-transparentes)
  Widget _buildMapControls() {
    return Positioned(
      right: 16,
      bottom: 180,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.95),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          children: [
            // Zoom in
            _buildMapControlButton(
              icon: Icons.add,
              onPressed: () {
                context.read<MapBloc>().add(const MapZoomInRequested());
              },
              heroTag: 'zoom_in',
            ),

            // Divider
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              height: 1,
              color: Colors.grey.shade300,
            ),

            // Zoom out
            _buildMapControlButton(
              icon: Icons.remove,
              onPressed: () {
                context.read<MapBloc>().add(const MapZoomOutRequested());
              },
              heroTag: 'zoom_out',
            ),

            // Divider
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              height: 1,
              color: Colors.grey.shade300,
            ),

            BlocBuilder<MapBloc, MapState>(
              builder: (context, state) {
                if (state is! MapLoaded) return const SizedBox.shrink();

                return BlocBuilder<LocationBloc, LocationState>(
                  builder: (context, locationState) {
                    final bool hasLocation = locationState is LocationLoaded;

                    return _buildMapControlButton(
                      icon: Icons.my_location,
                      onPressed: () {
                        if (hasLocation) {
                          _mapController.move(
                            LatLng(
                              locationState.position.latitude,
                              locationState.position.longitude,
                            ),
                            15.0,
                          );
                        }
                        _isFollowingUser = true; // Activar seguimiento
                        context.read<MapBloc>().add(
                          const MapCenterOnUserRequested(),
                        );
                      },
                      heroTag: 'center_user',
                      isActive: state.followUserLocation && hasLocation,
                    );
                  },
                );
              },
            ), // Divider
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              height: 1,
              color: Colors.grey.shade300,
            ),

            // Botón de brújula (norte arriba)
            _buildMapControlButton(
              icon: Icons.explore,
              onPressed: () {
                // Volver a rotación 0 (norte arriba)
                _mapController.rotate(0);
              },
              heroTag: 'compass',
            ),
          ],
        ),
      ),
    );
  }

  /// Construir botón individual de control del mapa
  Widget _buildMapControlButton({
    required IconData icon,
    required VoidCallback onPressed,
    required String heroTag,
    bool isActive = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 48,
          height: 48,
          padding: const EdgeInsets.all(8),
          child: Icon(
            icon,
            size: 24,
            color: isActive ? const Color(0xFF2563EB) : const Color(0xFF1A1A1A),
          ),
        ),
      ),
    );
  }

  /// Botón de voz - Simplificado (el texto se muestra en la píldora superior)
  Widget _buildVoiceButton() {
    return Positioned(
      bottom: 90,
      left: 20,
      child: GestureDetector(
        onLongPress: _startListening,
        onLongPressEnd: (_) => _stopListening(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _isListening
                  ? const [Color(0xFFEF4444), Color(0xFFDC2626)]
                  : const [Color(0xFF2563EB), Color(0xFF1D4ED8)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: (_isListening
                        ? const Color(0xFFEF4444)
                        : const Color(0xFF2563EB))
                    .withOpacity(0.4),
                blurRadius: _isListening ? 24 : 16,
                spreadRadius: _isListening ? 4 : 2,
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _speechAvailable
                  ? () {
                      TtsService.instance.speak(
                        'Mantén presionado el botón o volumen arriba para hablar',
                      );
                    }
                  : () {
                      TtsService.instance.speak(
                        'Reconocimiento de voz no disponible',
                      );
                    },
              customBorder: const CircleBorder(),
              child: Center(
                child: Icon(
                  _isListening ? Icons.mic : Icons.mic_none,
                  color: Colors.white,
                  size: 32,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Iniciar escucha de voz
  Future<void> _startListening() async {
    if (!_speechAvailable || _isListening) return;

    try {
      // 1. PRIMERO: Anunciar que vamos a escuchar (ANTES de activar micrófono)
      await TtsService.instance.speak('Escuchando');
      
      // 2. Pequeña pausa para que termine de hablar
      await Future.delayed(const Duration(milliseconds: 500));

      // 3. DESPUÉS: Activar el micrófono
      setState(() => _isListening = true);

      await _speech.listen(
        onResult: _onSpeechResult,
        listenFor: const Duration(seconds: 10),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        localeId: 'es_CL', // Español de Chile
      );
    } catch (e) {
      DebugLogger.error('Error al iniciar escucha: $e', context: 'MapScreen');
      setState(() => _isListening = false);
    }
  }

  /// Detener escucha de voz
  Future<void> _stopListening() async {
    if (!_isListening) return;

    try {
      await _speech.stop();
      setState(() {
        _isListening = false;
        _lastWords = ''; // Limpiar texto reconocido
      });
    } catch (e) {
      DebugLogger.error('Error al detener escucha: $e', context: 'MapScreen');
    }
  }

  /// Procesar resultado de voz
  void _onSpeechResult(result) {
    setState(() {
      _lastWords = result.recognizedWords.toLowerCase();
    });

    // Si el resultado es final, procesar el comando
    if (result.finalResult) {
      _processVoiceCommand(_lastWords);
    }
  }

  /// Procesar comando de voz
  Future<void> _processVoiceCommand(String command) async {
    DebugLogger.info('📥 Comando recibido: "$command"', context: 'MapScreen');

    // Detectar "ir a [lugar]"
    if (command.contains('ir a') ||
        command.contains('navegar a') ||
        command.contains('llévame a')) {
      DebugLogger.info('🎯 Detectado comando de navegación', context: 'MapScreen');
      final destination = _extractDestination(command);
      DebugLogger.info('📍 Destino extraído: "$destination"', context: 'MapScreen');
      
      if (destination.isNotEmpty) {
        await _navigateToPlace(destination);
      } else {
        DebugLogger.warning('⚠️ No se pudo extraer destino de: "$command"', context: 'MapScreen');
        await TtsService.instance.speak(
          'No entendí el destino. Intenta de nuevo.',
        );
      }
    }
    // Comandos de paradero
    else if (command.contains('paradero') || command.contains('parada')) {
      await _findNearestBusStop();
    }
    // Centrar en usuario
    else if (command.contains('dónde estoy') ||
        command.contains('mi ubicación')) {
      context.read<MapBloc>().add(const MapCenterOnUserRequested());
      await TtsService.instance.speak('Centrando en tu ubicación');
    }
    // Repetir instrucción actual
    else if (command.contains('repite') || command.contains('otra vez')) {
      final navState = context.read<NavigationBloc>().state;
      if (navState is NavigationActive) {
        await _announceCurrentInstruction();
      } else {
        await TtsService.instance.speak('No hay navegación activa');
      }
    }
    // Comando no reconocido
    else {
      DebugLogger.info('❓ Comando no reconocido: "$command"', context: 'MapScreen');
      await TtsService.instance.speak(
        'No entendí el comando. Puedes decir: ir a, paradero cercano, o dónde estoy',
      );
    }
  }

  /// Navegar a un lugar usando geocoding + routing
  Future<void> _navigateToPlace(String placeName) async {
    try {
      await TtsService.instance.speak('Buscando $placeName');
      
      // Obtener ubicación actual
      final locationState = context.read<LocationBloc>().state;
      if (locationState is! LocationLoaded) {
        await TtsService.instance.speak('No tengo tu ubicación GPS');
        return;
      }

      final origin = LatLng(
        locationState.position.latitude,
        locationState.position.longitude,
      );
      
      // Usar la IP configurada dinámicamente en DebugSetupScreen
      final navService = NavigationRouteService(ServerConfig.instance.baseUrl);
      
      // 1. Buscar lugar (geocoding)
      final searchResult = await navService.searchPlace(placeName);
      if (searchResult == null) {
        await TtsService.instance.speak('No encontré $placeName. Intenta con otro nombre');
        return;
      }

      await TtsService.instance.speak('Encontré ${searchResult.displayName}. Calculando ruta accesible');
      
      // 2. Calcular ruta de transporte público (por ahora, solo verifica que exista)
      final route = await navService.getAccessibleRoute(
        origin: origin,
        destination: searchResult.location,
        minimizeTransfers: true,  // Prioridad para personas no videntes
        minimizeWalking: true,
      );

      if (route == null) {
        await TtsService.instance.speak('No pude calcular una ruta. Intenta con otro destino');
        return;
      }

      // 3. Anunciar que encontró la ruta (simplificado por ahora)
      await TtsService.instance.speak(
        'Ruta encontrada. ${route.legs.length} segmentos. Duración aproximada: ${route.durationText}',
      );

      // 4. Iniciar navegación (NavigationBloc calcula ruta internamente)
      context.read<NavigationBloc>().add(
        NavigationStarted(
          destination: searchResult.location,
          destinationName: searchResult.displayName,
          origin: origin,
        ),
      );

      // 5. Zoom al área de la ruta
      _zoomToRouteBounds(origin, searchResult.location);

    } catch (e) {
      DebugLogger.error('Error navegando a lugar: $e', context: 'MapScreen');
      await TtsService.instance.speak('Error al buscar ruta. Intenta de nuevo');
    }
  }

  /// Hacer zoom a los límites de la ruta
  void _zoomToRouteBounds(LatLng origin, LatLng destination) {
    final bounds = LatLngBounds(
      LatLng(
        origin.latitude < destination.latitude 
            ? origin.latitude 
            : destination.latitude,
        origin.longitude < destination.longitude 
            ? origin.longitude 
            : destination.longitude,
      ),
      LatLng(
        origin.latitude > destination.latitude 
            ? origin.latitude 
            : destination.latitude,
        origin.longitude > destination.longitude 
            ? origin.longitude 
            : destination.longitude,
      ),
    );

    // Aplicar bounds al mapa con padding
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.all(80),
      ),
    );
  }

  /// Anunciar ruta de forma accesible para personas no videntes
  /// TODO: Implementar cuando el modelo TransitRoute esté completo
  /*
  Future<void> _announceRoute(TransitRoute route) async {
    // Resumen general
    await TtsService.instance.speak(route.accessibleSummary);
    
    await Future.delayed(const Duration(milliseconds: 800));
    
    // Anunciar cada segmento
    for (int i = 0; i < route.legs.length; i++) {
      final leg = route.legs[i];
      
      if (i == 0) {
        await TtsService.instance.speak('Primero: ${leg.accessibleDescription}');
      } else if (i == route.legs.length - 1) {
        await TtsService.instance.speak('Finalmente: ${leg.accessibleDescription}');
      } else {
        await TtsService.instance.speak('Luego: ${leg.accessibleDescription}');
      }
      
      await Future.delayed(const Duration(milliseconds: 600));
    }
    
    await TtsService.instance.speak('Presiona el botón de inicio para comenzar la navegación');
  }
  */

  /// Anunciar instrucción actual durante navegación
  Future<void> _announceCurrentInstruction() async {
    final navState = context.read<NavigationBloc>().state;
    if (navState is NavigationActive) {
      final currentStep = navState.currentStepIndex;
      if (currentStep < navState.route.steps.length) {
        final step = navState.route.steps[currentStep];
        await TtsService.instance.speak(step.instruction);
      }
    }
  }

  /// Buscar paradero más cercano
  Future<void> _findNearestBusStop() async {
    try {
      await TtsService.instance.speak('Buscando paradero cercano');
      
      final locationState = context.read<LocationBloc>().state;
      if (locationState is! LocationLoaded) {
        await TtsService.instance.speak('No tengo tu ubicación GPS');
        return;
      }

      final origin = LatLng(
        locationState.position.latitude,
        locationState.position.longitude,
      );
      
      // Usar la IP configurada dinámicamente en DebugSetupScreen
      final navService = NavigationRouteService(ServerConfig.instance.baseUrl);
      
      final stops = await navService.getNearbyStops(
        location: origin,
        radiusMeters: 500,
      );

      if (stops.isEmpty) {
        await TtsService.instance.speak('No hay paraderos cercanos en 500 metros');
        return;
      }

      // Anunciar el más cercano
      final nearest = stops.first;
      final distance = stops.first.location != null 
          ? _calculateDistance(origin, stops.first.location!)
          : 0;
          
      await TtsService.instance.speak(
        'El paradero más cercano es ${nearest.accessibleName}, a ${distance.round()} metros',
      );

      // Navegar hacia el paradero
      if (nearest.location != null) {
        final route = await navService.getWalkingRoute(
          origin: origin,
          destination: nearest.location!,
        );

        if (route != null) {
          await TtsService.instance.speak(
            'Son aproximadamente ${route.durationText} caminando',
          );
        }
      }

    } catch (e) {
      DebugLogger.error('Error buscando paradero: $e', context: 'MapScreen');
      await TtsService.instance.speak('Error al buscar paradero');
    }
  }

  /// Calcular distancia entre dos puntos (metros)
  double _calculateDistance(LatLng from, LatLng to) {
    const Distance distance = Distance();
    return distance.as(LengthUnit.Meter, from, to);
  }

  /// Extraer destino del comando
  String _extractDestination(String command) {
    // Normalizar: "ir al" -> "ir a el", "ir a la" -> "ir a la"
    final normalized = command
        .replaceAll(RegExp(r'\bir al\b', caseSensitive: false), 'ir a')
        .replaceAll(RegExp(r'\bir a la\b', caseSensitive: false), 'ir a')
        .replaceAll(RegExp(r'\bir a las\b', caseSensitive: false), 'ir a')
        .replaceAll(RegExp(r'\bir a los\b', caseSensitive: false), 'ir a')
        .replaceAll(RegExp(r'\bnavegar al\b', caseSensitive: false), 'navegar a')
        .replaceAll(RegExp(r'\bllévame al\b', caseSensitive: false), 'llévame a');
    
    final patterns = [
      RegExp(r'ir a (.+)', caseSensitive: false),
      RegExp(r'navegar a (.+)', caseSensitive: false),
      RegExp(r'llévame a (.+)', caseSensitive: false),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(normalized);
      if (match != null && match.groupCount > 0) {
        final destination = match.group(1)!.trim();
        if (destination.isNotEmpty) {
          DebugLogger.info('Destino extraído: "$destination"', context: 'MapScreen');
          return destination;
        }
      }
    }

    DebugLogger.warning('No se pudo extraer destino de: "$command"', context: 'MapScreen');
    return '';
  }

  /// Indicador de estado GPS (oculto según diseño Figma)
  Widget _buildLocationIndicator() {
    // Según diseño Figma, no se muestra el indicador GPS
    return const SizedBox.shrink();
  }

  /// Botón de settings (bottom-right) - Diseño Figma
  Widget _buildSettingsButton() {
    return Positioned(
      bottom: 90,
      right: 20,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: const Color(0xFF2C2C2E),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: IconButton(
          onPressed: () {
            Navigator.pushNamed(context, '/settings');
          },
          icon: const Icon(Icons.settings, color: Colors.white, size: 26),
        ),
      ),
    );
  }

  /// Panel inferior "Procesando ruta..." - Diseño Figma
  Widget _buildProcessingPanel() {
    return BlocBuilder<NavigationBloc, NavigationState>(
      builder: (context, state) {
        if (state is NavigationCalculating) {
          return Positioned(
            bottom: 160,
            left: 16,
            right: 16,
            child: AnimatedOpacity(
              opacity: 1.0,
              duration: const Duration(milliseconds: 300),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 24,
                  horizontal: 32,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF2563EB),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    ),
                    SizedBox(width: 16),
                    Text(
                      'Procesando ruta...',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  /// Píldora superior - Diseño Figma (Logo icons.png + WayFindCL + Badge IA)
  Widget _buildUserPill() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 16,
      left: 16,
      right: 16,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Píldora principal (Logo + WayFindCL + Badge IA)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(30),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Logo icons.png (a la izquierda de WayFindCL)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.asset(
                      'assets/icons.png',
                      width: 32,
                      height: 32,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        // Fallback si no se encuentra la imagen
                        return Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: const Color(0xFFE30613),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.navigation,
                            color: Colors.white,
                            size: 20,
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Texto WayFindCL
                  const Text(
                    'WayFindCL',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1A1A1A),
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Badge IA con rayo - ANIMADO cuando está escuchando
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: _isListening
                            ? [
                                const Color(0xFFEF4444), // Rojo brillante
                                const Color(0xFFDC2626),
                              ]
                            : [
                                const Color(0xFF00BCD4), // Cyan/Turquesa
                                const Color(0xFF00ACC1),
                              ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: _isListening
                          ? [
                              BoxShadow(
                                color: const Color(0xFFEF4444).withOpacity(0.6),
                                blurRadius: 12,
                                spreadRadius: 2,
                              ),
                            ]
                          : null,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Ícono animado
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: Icon(
                            _isListening ? Icons.graphic_eq : Icons.flash_on,
                            key: ValueKey<bool>(_isListening),
                            color: Colors.white,
                            size: 16,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          'IA',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          // Píldora de texto reconocido (solo visible cuando está escuchando)
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            child: _isListening || _lastWords.isNotEmpty
                ? Container(
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.85),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: _isListening
                            ? const Color(0xFFEF4444)
                            : const Color(0xFF00BCD4),
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: (_isListening
                                  ? const Color(0xFFEF4444)
                                  : const Color(0xFF00BCD4))
                              .withOpacity(0.3),
                          blurRadius: 16,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _isListening ? Icons.mic : Icons.check_circle,
                          color: _isListening
                              ? const Color(0xFFEF4444)
                              : const Color(0xFF00BCD4),
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            _lastWords.isEmpty 
                                ? 'Escuchando...' 
                                : _lastWords,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.3,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    if (_speech.isListening) {
      _speech.stop();
    }
    _mapController.dispose();
    super.dispose();
  }
}
