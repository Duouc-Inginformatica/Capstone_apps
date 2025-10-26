import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../services/device/biometric_auth_service.dart';
import '../services/device/tts_service.dart';
import '../services/backend/api_client.dart';
import '../widgets/accessible_button.dart';
import 'map_screen.dart';

/// Pantalla de Login completamente accesible para personas no videntes
/// Características:
/// - Autenticación biométrica (huella/Face ID)
/// - Registro por voz si no hay usuario
/// - TTS en cada paso del proceso
/// - UI minimalista enfocada en accesibilidad
class BiometricLoginScreen extends StatefulWidget {
  const BiometricLoginScreen({super.key});

  static const routeName = '/biometric-login';

  @override
  State<BiometricLoginScreen> createState() => _BiometricLoginScreenState();
}

class _BiometricLoginScreenState extends State<BiometricLoginScreen> {
  void _log(String message, {Object? error, StackTrace? stackTrace}) {
    developer.log(
      message,
      name: 'BiometricLoginScreen',
      error: error,
      stackTrace: stackTrace,
    );
  }

  final _biometricAuth = BiometricAuthService.instance;
  final _tts = TtsService.instance;
  final _speech = SpeechToText();
  final _apiClient = ApiClient();

  bool _isInitializing = true;
  bool _hasRegisteredUser = false;
  bool _isRegistering = false;
  bool _isListening = false;
  bool _speechAvailable = false;

  // Estado del registro
  String? _registrationUsername;
  String? _registrationEmail;
  RegistrationStep _registrationStep = RegistrationStep.username;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    if (_speechAvailable && _speech.isListening) {
      _speech.stop();
    }
    super.dispose();
  }

  /// Inicializa el sistema biométrico y TTS
  Future<void> _initialize() async {
    try {
      _log('🔐 [BIOMETRIC-LOGIN] Inicializando...');

      // TTS ya se auto-inicializa en la primera llamada a speak()

      // Inicializar reconocimiento de voz
      final speechAvailable = await _speech.initialize(
        onError: (error) => _log('❌ [SPEECH] Error: $error'),
        onStatus: (status) => _log('🎤 [SPEECH] Status: $status'),
      );

      if (!speechAvailable) {
        _log('⚠️ [SPEECH] Reconocimiento de voz no disponible');
        await _tts.speak(
          'Advertencia: reconocimiento de voz no disponible. '
          'Puedes continuar, pero deberás usar asistencia manual.',
        );
      }

      _speechAvailable = speechAvailable;

      // Verificar capacidad biométrica
      final canCheck = await _biometricAuth.canCheckBiometrics();
      if (!canCheck) {
        await _tts.speak(
          'Error: Este dispositivo no tiene autenticación biométrica. '
          'Por favor, usa otro dispositivo.',
        );
        setState(() {
          _isInitializing = false;
        });
        return;
      }

      // Verificar tipos de biometría disponibles
      final biometricTypes = await _biometricAuth.getAvailableBiometrics();
      final biometricDescription = _biometricAuth.getBiometricTypeDescription(
        biometricTypes,
      );

      _log('✅ [BIOMETRIC] Tipos disponibles: $biometricDescription');

      // Verificar si ya hay un usuario registrado
      final hasUser = await _biometricAuth.hasRegisteredUser();

      setState(() {
        _hasRegisteredUser = hasUser;
        _isInitializing = false;
      });

      // Anunciar estado inicial
      await Future.delayed(const Duration(milliseconds: 500));

      if (hasUser) {
        // AUTO-LOGIN: Usuario registrado → Solicitar biometría directamente
        await _tts.speak(
          'Bienvenido a WayFind CL. '
          'Se detectó un usuario registrado. '
          'Autentica con tu $biometricDescription.',
        );

        // Esperar un momento y luego solicitar biometría
        await Future.delayed(const Duration(milliseconds: 1000));
        await _handleAutoLogin();
      } else {
        // AUTO-REGISTRO: No hay usuario → Iniciar registro automáticamente
        await _tts.speak(
          'Bienvenido a WayFind CL. '
          'No hay usuarios registrados en este dispositivo. '
          'Iniciando proceso de registro automático.',
        );

        // Esperar un momento y luego iniciar registro
        await Future.delayed(const Duration(milliseconds: 1000));
        await _startRegistration();
      }
    } catch (e) {
      _log('❌ [BIOMETRIC-LOGIN] Error en inicialización: $e');
      await _tts.speak(
        'Error al inicializar el sistema. Por favor, reinicia la aplicación.',
      );

      setState(() {
        _isInitializing = false;
      });
    }
  }

  /// Auto-login para usuarios registrados
  Future<void> _handleAutoLogin() async {
    try {
      final user = await _biometricAuth.authenticateWithBiometrics(
        localizedReason: 'Autentícate para iniciar sesión en WayFind CL',
      );

      if (user == null) {
        await _tts.speak(
          'No se pudo autenticar. '
          'Verifica que tu huella o rostro estén registrados en el dispositivo.',
        );
        return;
      }

      // Actualizar timestamp de último login
      await _biometricAuth.updateLastLogin();

      await _ensureBackendSession(user);

      final username = user['username'] as String;
      await _tts.speak(
        'Bienvenido de vuelta, $username. Ingresando a la aplicación.',
      );

      // Navegar al mapa
      if (mounted) {
        Navigator.of(
          context,
        ).pushReplacement(MaterialPageRoute(builder: (_) => const MapScreen()));
      }
    } catch (e) {
      _log('❌ [BIOMETRIC-LOGIN] Error en auto-login: $e');
      await _tts.speak('Error al iniciar sesión. Intenta nuevamente.');
    }
  }

  /// Inicia el proceso de registro de nueva cuenta
  Future<void> _startRegistration() async {
    setState(() {
      _isRegistering = true;
      _registrationStep = RegistrationStep.username;
      _registrationUsername = null;
      _registrationEmail = null;
    });

    if (!_speechAvailable) {
      await _tts.speak(
        'El registro por voz no está disponible porque el micrófono no pudo inicializarse.',
      );
      setState(() {
        _isRegistering = false;
      });
      return;
    }

    await _tts.speak(
      'Di tu nombre de usuario. '
      'Cuando termines de hablar, espera 2 segundos y confirmaremos.',
    );

    // Esperar un momento y luego empezar a escuchar
    await Future.delayed(const Duration(seconds: 1));
    _startListening(RegistrationStep.username);
  }

  /// Inicia la escucha de voz para un paso específico
  void _startListening(RegistrationStep step) async {
    if (_isListening) return;
    if (!_speechAvailable) {
      await _tts.speak(
        'No se pudo activar el micrófono. Intenta nuevamente más tarde.',
      );
      return;
    }

    setState(() {
      _isListening = true;
      _registrationStep = step;
    });

    try {
      await _tts.speak('Escuchando...');
      await _tts.waitUntilDone();

      final didStart = await _speech.listen(
        onResult: (SpeechRecognitionResult result) =>
            _handleVoiceResult(result, step),
        listenFor: const Duration(seconds: 10),
        pauseFor: const Duration(seconds: 2),
  listenOptions: SpeechListenOptions(
          partialResults: false,
        ),
        localeId: 'es_ES',
      );

      if (!didStart) {
        setState(() {
          _isListening = false;
        });
        await _tts.speak(
          'No se pudo activar el micrófono. Intenta nuevamente.',
        );
      }
    } catch (e) {
      _log('❌ [SPEECH] Error al iniciar escucha: $e');
      setState(() {
        _isListening = false;
      });
      await _tts.speak('Error al activar el micrófono. Intenta nuevamente.');
    }
  }

  /// Maneja el resultado del reconocimiento de voz
  Future<void> _handleVoiceResult(
    SpeechRecognitionResult result,
    RegistrationStep step,
  ) async {
    if (!_isListening || !result.finalResult) return;

    final recognizedText = result.recognizedWords.trim();
    if (recognizedText.isEmpty) {
      setState(() {
        _isListening = false;
      });
      return;
    }

    setState(() {
      _isListening = false;
    });

    if (_speech.isListening) {
      await _speech.stop();
    }

    _log('🎤 [SPEECH] Reconocido: "$recognizedText" para paso: $step');

    // Procesar según el paso actual
    switch (step) {
      case RegistrationStep.usernameConfirmation:
        await _handleUsernameConfirmation(recognizedText);
        break;

      case RegistrationStep.username:
        await _handleUsernameInput(recognizedText);
        break;

      case RegistrationStep.email:
        await _handleEmailInput(recognizedText);
        break;

      case RegistrationStep.confirmation:
        await _handleConfirmation(recognizedText);
        break;
    }
  }

  /// Procesa la confirmación inicial del nombre
  Future<void> _handleUsernameConfirmation(String response) async {
    final responseLower = response.toLowerCase().trim();

    if (responseLower.contains('sí') ||
        responseLower.contains('si') ||
        responseLower.contains('correcto') ||
        responseLower.contains('está bien')) {
      // Nombre confirmado, pasar al email
      await _tts.speak(
        'Perfecto. Ahora, di tu correo electrónico si deseas registrarlo, '
        'o di "saltar" para omitir este paso.',
      );

      setState(() {
        _registrationStep = RegistrationStep.email;
      });

      await Future.delayed(const Duration(seconds: 2));
      _startListening(RegistrationStep.email);
    } else if (responseLower.contains('no') ||
        responseLower.contains('incorrecto') ||
        responseLower.contains('reintentar')) {
      // Reintentar nombre
      await _tts.speak('De acuerdo. Di tu nombre de usuario nuevamente.');

      setState(() {
        _registrationUsername = null;
        _registrationStep = RegistrationStep.username;
      });

      await Future.delayed(const Duration(seconds: 1));
      _startListening(RegistrationStep.username);
    } else {
      // No entendió
      await _tts.speak(
        'No entendí. Di "sí" si el nombre es correcto, o "no" para reintentarlo.',
      );

      await Future.delayed(const Duration(seconds: 2));
      _startListening(RegistrationStep.usernameConfirmation);
    }
  }

  /// Procesa la entrada del nombre de usuario
  Future<void> _handleUsernameInput(String username) async {
    setState(() {
      _registrationUsername = username.trim();
      _registrationStep = RegistrationStep.usernameConfirmation;
    });

    await _tts.speak(
      'Nombre de usuario: $username. '
      '¿Es correcto? Di "sí" o "no".',
    );

    await Future.delayed(const Duration(seconds: 2));
    _startListening(RegistrationStep.usernameConfirmation);
  }

  /// Procesa la entrada del correo electrónico
  Future<void> _handleEmailInput(String emailVoice) async {
    final emailLower = emailVoice.toLowerCase().trim();

    // Verificar si quiere saltar
    if (emailLower.contains('saltar') ||
        emailLower.contains('omitir') ||
        emailLower.contains('no')) {
      setState(() {
        _registrationEmail = null;
      });

      await _tts.speak(
        'Correo omitido. '
        'Confirma tu registro. '
        'Usuario: $_registrationUsername. '
        'Sin correo electrónico. '
        'Di "confirmar" para continuar, o "cancelar" para empezar de nuevo.',
      );

      await Future.delayed(const Duration(seconds: 2));
      _startListening(RegistrationStep.confirmation);
      return;
    }

    // Convertir voz a formato de email
    // Ejemplo: "juan punto pérez arroba gmail punto com" → "juan.perez@gmail.com"
    String email = emailLower
        .replaceAll(' punto ', '.')
        .replaceAll(' arroba ', '@')
        .replaceAll(' guion ', '-')
        .replaceAll(' ', '');

    setState(() {
      _registrationEmail = email;
    });

    await _tts.speak(
      'Correo registrado: $email. '
      'Confirma tu registro. '
      'Usuario: $_registrationUsername. '
      'Correo: $email. '
      'Di "confirmar" para continuar, o "cancelar" para empezar de nuevo.',
    );

    await Future.delayed(const Duration(seconds: 2));
    _startListening(RegistrationStep.confirmation);
  }

  /// Procesa la confirmación del registro
  Future<void> _handleConfirmation(String confirmation) async {
    final confirmLower = confirmation.toLowerCase().trim();

    // Verificar si quiere cancelar
    if (confirmLower.contains('cancelar') ||
        confirmLower.contains('no') ||
        confirmLower.contains('empezar')) {
      setState(() {
        _isRegistering = false;
        _registrationUsername = null;
        _registrationEmail = null;
      });

      await _tts.speak('Registro cancelado. Volviendo al inicio.');
      return;
    }

    // Verificar si quiere confirmar
    if (confirmLower.contains('confirmar') ||
        confirmLower.contains('sí') ||
        confirmLower.contains('si') ||
        confirmLower.contains('acepto')) {
      await _completeRegistration();
      return;
    }

    // No entendió la respuesta
    await _tts.speak(
      'No entendí tu respuesta. '
      'Di "confirmar" para registrarte, o "cancelar" para empezar de nuevo.',
    );

    await Future.delayed(const Duration(seconds: 2));
    _startListening(RegistrationStep.confirmation);
  }

  Future<void> _ensureBackendSession(Map<String, dynamic> localUser) async {
  final username = localUser['username']?.toString() ?? '';
  final rawEmail = localUser['email'];
  final emailCandidate =
    rawEmail is String && rawEmail.trim().isNotEmpty
      ? rawEmail.trim()
      : null;

    try {
      final biometricToken = await _biometricAuth.getBiometricDeviceToken();
      await _apiClient.biometricLogin(biometricToken: biometricToken);
    } on ApiException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 404) {
        try {
          final biometricToken = await _biometricAuth.getBiometricDeviceToken();
          await _apiClient.biometricRegister(
            username: username,
            biometricToken: biometricToken,
            email: emailCandidate,
          );
        } catch (registerError) {
          _log('❌ [BACKEND] Falló registro de respaldo: $registerError');
          await _tts.speak(
            'Advertencia: no se pudo sincronizar con el servidor. '
            'Funcionalidades en línea podrían no estar disponibles.',
          );
        }
      } else {
        _log('❌ [BACKEND] Login biométrico falló: $e');
        await _tts.speak(
          'No se pudo conectar con el servidor. '
          'Revisa tu conexión si necesitas funciones en línea.',
        );
      }
    } catch (e) {
      _log('❌ [BACKEND] Error inesperado en login biométrico: $e');
      await _tts.speak(
        'Error inesperado al sincronizar con el servidor.',
      );
    }
  }

  Future<void> _registerBackendUser({
    required String username,
    String? email,
  }) async {
    try {
      final biometricToken = await _biometricAuth.getBiometricDeviceToken();
      await _apiClient.biometricRegister(
        username: username,
        biometricToken: biometricToken,
        email: email != null && email.trim().isNotEmpty ? email.trim() : null,
      );
    } on ApiException catch (e) {
      _log('❌ [BACKEND] Registro biométrico falló: $e');
      await _tts.speak(
        'Registro completado localmente, pero no se pudo contactar al servidor.',
      );
    } catch (e) {
      _log('❌ [BACKEND] Error inesperado registrando: $e');
      await _tts.speak(
        'Ocurrió un error inesperado al comunicarse con el servidor.',
      );
    }
  }

  /// Completa el registro con biometría
  Future<void> _completeRegistration() async {
    if (_registrationUsername == null) {
      await _tts.speak('Error: No se ha capturado el nombre de usuario.');
      return;
    }

    await _tts.speak(
      'Perfecto. Ahora autentica con tu biometría para completar el registro. '
      'Esto será tu contraseña para futuras sesiones.',
    );

    final success = await _biometricAuth.registerUserWithBiometrics(
      username: _registrationUsername!,
      email: _registrationEmail,
      localizedReason: 'Registra tu biometría como contraseña para WayFind CL',
    );

    if (!success) {
      await _tts.speak(
        'No se pudo completar el registro. '
        'Verifica que tu huella o rostro estén configurados en el dispositivo.',
      );
      return;
    }

    await _registerBackendUser(
      username: _registrationUsername!,
      email: _registrationEmail,
    );

    await _tts.speak(
      'Registro completado exitosamente. '
      'Bienvenido a WayFind CL, $_registrationUsername. '
      'Ingresando a la aplicación.',
    );

    setState(() {
      _isRegistering = false;
      _hasRegisteredUser = true;
    });

    // Navegar al mapa
    await Future.delayed(const Duration(seconds: 1));
    if (mounted) {
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const MapScreen()));
    }
  }

  /// Cancela el proceso de registro
  Future<void> _cancelRegistration() async {
    setState(() {
      _isRegistering = false;
      _registrationUsername = null;
      _registrationEmail = null;
    });

    await _tts.speak('Registro cancelado. Volviendo al inicio.');
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializing) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 32),
              Text(
                'Inicializando sistema biométrico...',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (_isRegistering) {
      return _buildRegistrationScreen();
    }

    // Pantalla de espera mientras se procesa biometría automáticamente
    return _buildWaitingScreen();
  }

  /// Pantalla de espera durante proceso automático
  Widget _buildWaitingScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Logo/Título
              Icon(
                Icons.fingerprint,
                size: 120,
                color: Colors.white,
                semanticLabel: 'Icono de huella dactilar',
              ),
              const SizedBox(height: 32),

              Text(
                'WayFind CL',
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 16),

              Text(
                'Autenticación Biométrica',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: Colors.white70),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 64),

              // Indicador de carga
              CircularProgressIndicator(
                color: Colors.white,
                semanticsLabel: 'Procesando autenticación',
              ),

              const SizedBox(height: 32),

              Text(
                _hasRegisteredUser
                    ? 'Esperando autenticación...'
                    : 'Iniciando registro...',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Pantalla de registro por voz
  Widget _buildRegistrationScreen() {
    String stepDescription = '';
    IconData stepIcon = Icons.mic;

    switch (_registrationStep) {
      case RegistrationStep.username:
        stepDescription = 'Di tu nombre de usuario';
        stepIcon = Icons.person;
        break;
      case RegistrationStep.usernameConfirmation:
        stepDescription = '¿Es correcto el nombre?';
        stepIcon = Icons.question_mark;
        break;
      case RegistrationStep.email:
        stepDescription = 'Di tu correo (opcional)';
        stepIcon = Icons.email;
        break;
      case RegistrationStep.confirmation:
        stepDescription = 'Confirma tus datos';
        stepIcon = Icons.check_circle;
        break;
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Indicador de paso actual
              Icon(
                stepIcon,
                size: 100,
                color: _isListening ? Colors.red : Colors.white,
              ),

              const SizedBox(height: 32),

              Text(
                stepDescription,
                style: Theme.of(
                  context,
                ).textTheme.headlineSmall?.copyWith(color: Colors.white),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 16),

              if (_isListening) ...[
                const CircularProgressIndicator(color: Colors.red),
                const SizedBox(height: 16),
                Text(
                  'Escuchando...',
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(color: Colors.red),
                  textAlign: TextAlign.center,
                ),
              ],

              const SizedBox(height: 64),

              // Mostrar datos capturados
              if (_registrationUsername != null) ...[
                _buildDataRow('Usuario', _registrationUsername!),
                const SizedBox(height: 16),
              ],

              if (_registrationEmail != null) ...[
                _buildDataRow('Correo', _registrationEmail!),
                const SizedBox(height: 32),
              ],

              // Botón de cancelar
              AccessibleButton(
                onPressed: _cancelRegistration,
                label: 'Cancelar Registro',
                semanticLabel: 'Cancelar proceso de registro',
                icon: Icons.cancel,
                backgroundColor: Colors.red,
                height: 70,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Widget para mostrar un dato capturado
  Widget _buildDataRow(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white30),
      ),
      child: Row(
        children: [
          Icon(
            label == 'Usuario' ? Icons.person : Icons.email,
            color: Colors.white70,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Pasos del proceso de registro
enum RegistrationStep {
  username, // Capturar nombre de usuario
  usernameConfirmation, // Confirmar si el nombre es correcto
  email, // Capturar email (opcional)
  confirmation, // Confirmación final
}
