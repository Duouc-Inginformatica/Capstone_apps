import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import '../services/biometric_auth_service.dart';
import '../services/tts_service.dart';
import '../services/npu_detector_service.dart';
import '../services/api_client.dart';
import 'map_screen.dart';
import 'biometric_register_screen.dart';

/// Login Screen V2 - UI Clásica de Figma con Badge IA
/// Flujo: 1) Detectar huella PRIMERO, 2) Si existe → login, 3) Si no existe → register
/// El badge IA se activa cuando se detecta NPU/NNAPI (para futuros modelos IA)
class LoginScreenV2 extends StatefulWidget {
  const LoginScreenV2({super.key});

  static const routeName = '/login';

  @override
  State<LoginScreenV2> createState() => _LoginScreenV2State();
}

class _LoginScreenV2State extends State<LoginScreenV2>
    with TickerProviderStateMixin {
  final BiometricAuthService _biometricService = BiometricAuthService.instance;
  final TtsService _ttsService = TtsService();
  final ApiClient _apiClient = ApiClient();

  bool _isLoading = true;
  bool _biometricAvailable = false;
  bool _npuAvailable = false;
  bool _npuLoading = false;
  bool _isAuthenticating = false;
  String _statusMessage = '';

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  late AnimationController _badgeController;
  late Animation<double> _badgeAnimation;

  @override
  void initState() {
    super.initState();

    // Animación de pulso para icono de huella
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.9, end: 1.1).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Animación de badge IA
    _badgeController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    _badgeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _badgeController, curve: Curves.elasticOut),
    );

    _initializeApp();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _badgeController.dispose();
    super.dispose();
  }

  Future<void> _initializeApp() async {
    try {
      // 1. Inicializar TTS básico primero (para mensajes inmediatos)
      await _ttsService.initialize();

      // 2. Verificar disponibilidad biométrica
      _biometricAvailable = await _biometricService.isAvailable();

      setState(() {
        _isLoading = false;
      });

      // 3. Inicializar detección NPU en paralelo (puede tardar)
      // No bloqueamos el flujo principal, se carga en background
      _initializeNpuDetection();

      // 4. TTS mensaje de bienvenida + instrucción
      if (_biometricAvailable) {
        // Mensaje de bienvenida simple
        await _ttsService.speak(
          'Bienvenido a WayFind CL. Por favor, coloca tu dedo en el sensor de huella digital para continuar.',
        );

        // 5. Iniciar autenticación automáticamente
        await Future.delayed(const Duration(milliseconds: 500));
        _authenticateWithBiometric();
      } else {
        // Si no hay biometría disponible, informar al usuario
        setState(() {
          _statusMessage = 'Autenticación biométrica no disponible';
        });
        await _ttsService.speak(
          'Bienvenido a WayFind CL. Autenticación biométrica no disponible en este dispositivo.',
        );
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _statusMessage = 'Error inicializando aplicación';
      });
      debugPrint('❌ Error inicializando app: $e');
    }
  }

  /// Inicializa la detección de NPU en background
  /// Cuando termine, activa el badge IA con animación (preparado para futuros modelos)
  Future<void> _initializeNpuDetection() async {
    try {
      setState(() {
        _npuLoading = true;
      });

      debugPrint('🧠 [LOGIN] Iniciando detección de capacidades NPU/NNAPI...');

      // Intentar detectar capacidades NPU
      final capabilities = await NpuDetectorService.instance
          .detectCapabilities();

      if (capabilities.hasNnapi && mounted) {
        setState(() {
          _npuAvailable = true;
          _npuLoading = false;
        });

        // Animar el badge IA cuando esté detectado
        _badgeController.forward();

        debugPrint('✅ [LOGIN] NPU/NNAPI detectado - Badge IA activado');
        debugPrint('   Dispositivo preparado para aceleración de modelos IA');

        // Opcional: Notificar al usuario si no está autenticando
        if (!_isAuthenticating) {
          await _ttsService.speak(
            'Aceleración por hardware detectada. Dispositivo optimizado para inteligencia artificial.',
          );
        }
      } else {
        setState(() {
          _npuLoading = false;
        });
        if (mounted) {
          _badgeController.forward();
        }
        debugPrint('⚠️ [LOGIN] NPU no disponible - usando modo estándar');
      }
    } catch (e) {
      setState(() {
        _npuLoading = false;
      });
      debugPrint('❌ [LOGIN] Error detectando NPU: $e');
      // No es crítico, la app funciona normalmente
    }
  }

  Future<void> _syncBackendSession({String? username, String? email}) async {
    final currentUser = await _biometricService.getCurrentUserData();
    final resolvedUsername =
        (username ?? currentUser?['username']?.toString() ?? '').trim();
    final resolvedEmail = (email ?? currentUser?['email']?.toString() ?? '')
        .trim();

    if (resolvedUsername.isEmpty) {
      debugPrint('⚠️ [LOGIN] Usuario local sin nombre, omitiendo sync backend');
      return;
    }

    final biometricToken = await _biometricService.getBiometricDeviceToken();

    try {
      await _apiClient.biometricLogin(biometricToken: biometricToken);
    } on ApiException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 404) {
        try {
          await _apiClient.biometricRegister(
            username: resolvedUsername,
            biometricToken: biometricToken,
            email: resolvedEmail.isEmpty ? null : resolvedEmail,
          );
          debugPrint('✅ [LOGIN] Cuenta creada en backend tras fallback');
        } catch (registerError) {
          debugPrint(
            '❌ [LOGIN] No se pudo registrar en backend: $registerError',
          );
          await _ttsService.speak(
            'Advertencia: no se pudo sincronizar con el servidor. '
            'Algunas funciones pueden no estar disponibles.',
          );
        }
      } else {
        debugPrint('❌ [LOGIN] Error al renovar sesión backend: $e');
        await _ttsService.speak(
          'No se pudo establecer conexión con el servidor.',
        );
      }
    } catch (e) {
      debugPrint('❌ [LOGIN] Error inesperado al sincronizar backend: $e');
    }
  }

  Future<void> _authenticateWithBiometric() async {
    if (_isAuthenticating || !_biometricAvailable) return;

    setState(() {
      _isAuthenticating = true;
      _statusMessage = 'Coloca tu dedo en el sensor...';
    });

    await _ttsService.speak(
      'Por favor, coloca tu dedo en el sensor de huella digital',
    );

    try {
      final LocalAuthentication auth = LocalAuthentication();

      // Pedir huella PRIMERO
      final bool didAuthenticate = await auth.authenticate(
        localizedReason: 'Autenticación requerida para acceder a WayFind CL',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );

      if (!didAuthenticate) {
        setState(() {
          _isAuthenticating = false;
          _statusMessage = 'Autenticación cancelada';
        });
        await _ttsService.speak('Autenticación cancelada');
        return;
      }

      // Huella AUTENTICADA - Ahora decidir: ¿login o register?
      setState(() {
        _statusMessage = 'Verificando usuario...';
      });

      final userExists = await _biometricService.checkUserExists();

      if (userExists) {
        // Usuario YA REGISTRADO → LOGIN
        setState(() {
          _statusMessage = 'Iniciando sesión...';
        });

        final userData = await _biometricService.getCurrentUserData();

        if (userData == null) {
          setState(() {
            _isAuthenticating = false;
            _statusMessage = 'No se encontró información del usuario';
          });
          await _ttsService.speak(
            'No se pudo acceder a tu perfil almacenado. Intenta nuevamente.',
          );
          return;
        }

        // Evitar solicitar la huella por segunda vez, solo actualizamos la sesión local/backend.
        await _biometricService.updateLastLogin();
        await _syncBackendSession(
          username: userData['username']?.toString(),
          email: userData['email']?.toString(),
        );

        await _ttsService.speak(
          'Inicio de sesión exitoso. Bienvenido de vuelta',
        );

        if (mounted) {
          setState(() {
            _isAuthenticating = false;
          });

          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const MapScreen()),
          );
        }
      } else {
        // Usuario NO REGISTRADO localmente → Verificar en backend primero
        setState(() {
          _statusMessage = 'Verificando huella en servidor...';
        });

        // Obtener token único del dispositivo
        final biometricToken = await _biometricService
            .getBiometricDeviceToken();

        // Verificar si ya existe en el backend
        final existsInBackend = await _apiClient.checkBiometricExists(
          biometricToken,
        );

        if (existsInBackend) {
          // Huella ya registrada a otro usuario
          setState(() {
            _isAuthenticating = false;
            _statusMessage = 'Huella ya registrada';
          });

          await _ttsService.speak(
            'Esta huella dactilar ya está registrada a otra cuenta. Por favor, utiliza una huella diferente o contacta a soporte.',
          );

          await Future.delayed(const Duration(seconds: 3));

          // Volver a intentar
          if (mounted) {
            setState(() {
              _isAuthenticating = false;
              _statusMessage = '';
            });
          }
          return;
        }

        // Huella NO registrada → Proceder a registro
        setState(() {
          _statusMessage = 'Nuevo usuario detectado. Iniciando registro...';
        });

        await _ttsService.speak(
          'No hay usuarios registrados con esta huella. Iniciando proceso de registro automático',
        );

        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) =>
                  BiometricRegisterScreen(biometricToken: biometricToken),
            ),
          );
        }
      }
    } catch (e) {
      setState(() {
        _isAuthenticating = false;
        _statusMessage = 'Error en autenticación biométrica';
      });
      await _ttsService.speak(
        'Error en la autenticación. Por favor, intenta de nuevo',
      );
      debugPrint('❌ Error biométrico: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            const Text(
              'WayFindCL',
              style: TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            // Badge "IA" - Se activa cuando se detecta NPU (preparado para futuros modelos)
            if (_npuLoading)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF00BCD4).withValues(alpha: 0.3),
                      const Color(0xFF0097A7).withValues(alpha: 0.3),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    ),
                    SizedBox(width: 6),
                    Text(
                      'IA',
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              )
            else if (_npuAvailable)
              ScaleTransition(
                scale: _badgeAnimation,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF00BCD4), Color(0xFF0097A7)],
                    ),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF00BCD4).withValues(alpha: 0.4),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Text(
                    'IA',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              )
            else
              FadeTransition(
                opacity: _badgeAnimation,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: _npuAvailable
                          ? const [Color(0xFF00BCD4), Color(0xFF0097A7)]
                          : const [Color(0xFFE53935), Color(0xFFD32F2F)],
                    ),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color:
                            (_npuAvailable
                                    ? const Color(0xFF00BCD4)
                                    : const Color(0xFFE53935))
                                .withValues(alpha: 0.4),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    _npuAvailable ? 'IA' : 'IA OFF',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Icono de mapa (diseño Figma)
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(
                    Icons.map_outlined,
                    size: 60,
                    color: Colors.grey[600],
                  ),
                ),

                const SizedBox(height: 48),

                // Botón grande de huella digital (estilo Figma) - Visual solamente
                // El sistema activa automáticamente el sensor
                AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    final bool hasAi = _npuAvailable;
                    final bool detectionReady = !_npuLoading;
                    final List<Color> gradientColors = !detectionReady
                        ? const [Color(0xFF101010), Color(0xFF1F1F1F)]
                        : hasAi
                        ? const [Color(0xFF00BCD4), Color(0xFF0097A7)]
                        : const [Color(0xFFE53935), Color(0xFFD32F2F)];

                    final double scaleBase = hasAi
                        ? _pulseAnimation.value
                        : 1 + (_pulseAnimation.value - 1) * 0.6;

                    final double scale = _isAuthenticating
                        ? scaleBase
                        : 1 + (scaleBase - 1) * 0.5;

                    final Color glowColor = gradientColors.last;

                    return Transform.scale(
                      scale: scale,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 350),
                        width: 280,
                        height: 180,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: gradientColors),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: glowColor.withValues(alpha: 0.4),
                              blurRadius: _isAuthenticating ? 26 : 18,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              child: Icon(
                                Icons.fingerprint,
                                key: ValueKey<bool>(hasAi),
                                size: 80,
                                color: _biometricAvailable
                                    ? Colors.white
                                    : Colors.white.withValues(alpha: 0.4),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _isAuthenticating
                                  ? 'Coloca tu huella...'
                                  : detectionReady
                                  ? hasAi
                                        ? 'Modo IA optimizado'
                                        : 'Modo estándar activo'
                                  : 'Detectando capacidades...',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),

                const SizedBox(height: 20),

                // Mensaje de estado
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _statusMessage,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey[800], fontSize: 14),
                  ),
                ),

                const SizedBox(height: 24),

                // Botón de reintentar (solo si autenticación cancelada/fallida)
                if (!_isAuthenticating &&
                    _biometricAvailable &&
                    _statusMessage.contains('cancelada'))
                  ElevatedButton.icon(
                    onPressed: _authenticateWithBiometric,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reintentar'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00BCD4),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 16,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
