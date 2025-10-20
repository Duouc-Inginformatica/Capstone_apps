import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../services/biometric_auth_service.dart';
import '../services/tts_service.dart';
import '../services/api_client.dart';
import 'home_screen.dart';

/// Pantalla de registro asistido por voz con huella dactilar
/// Flujo: Huella verificada → Pedir nombre de usuario (voz) → Email opcional → Guardar en DB
class BiometricRegisterScreen extends StatefulWidget {
  const BiometricRegisterScreen({super.key, required this.biometricToken});

  final String biometricToken;

  @override
  State<BiometricRegisterScreen> createState() =>
      _BiometricRegisterScreenState();
}

class _BiometricRegisterScreenState extends State<BiometricRegisterScreen> {
  void _log(String message, {Object? error, StackTrace? stackTrace}) {
    developer.log(
      message,
      name: 'BiometricRegisterScreen',
      error: error,
      stackTrace: stackTrace,
    );
  }

  final BiometricAuthService _biometricService = BiometricAuthService.instance;
  final TtsService _ttsService = TtsService();
  final ApiClient _apiClient = ApiClient();
  final stt.SpeechToText _speech = stt.SpeechToText();

  // Campos del formulario
  final TextEditingController _usernameCtrl = TextEditingController();
  final TextEditingController _emailCtrl = TextEditingController();

  // Estado del flujo
  int _currentStep = 0;
  bool _isListening = false;
  bool _isProcessing = false;
  String _statusMessage = '';
  bool _speechAvailable = false;

  @override
  void initState() {
    super.initState();
    _initializeSpeech();
    _startRegistrationFlow();
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _initializeSpeech() async {
    _speechAvailable = await _speech.initialize(
      onStatus: (status) => debugPrint('🎤 Speech status: $status'),
      onError: (error) => debugPrint('❌ Speech error: $error'),
    );
  }

  Future<void> _startRegistrationFlow() async {
    setState(() {
      _currentStep = 1;
      _statusMessage = 'Vamos a crear tu cuenta...';
    });

    await _ttsService.speak(
      'Bienvenido al registro de WayFind CL. Tu huella dactilar ha sido verificada. '
      'Ahora vamos a crear tu cuenta. Por favor, di tu nombre de usuario cuando escuches el tono.',
    );

    await Future.delayed(const Duration(seconds: 3));
    _promptForUsername();
  }

  Future<void> _promptForUsername() async {
    setState(() {
      _statusMessage = 'Di tu nombre de usuario...';
    });

    await _ttsService.speak('Por favor, di tu nombre de usuario');
    await Future.delayed(const Duration(milliseconds: 500));

    await _startListening((result) {
      setState(() {
        _usernameCtrl.text = result;
        _statusMessage = 'Nombre de usuario: $result';
      });

      _confirmUsername();
    });
  }

  Future<void> _confirmUsername() async {
    final username = _usernameCtrl.text;

    await _ttsService.speak(
      'Has dicho: $username. ¿Es correcto? Di "sí" para confirmar o "no" para repetir',
    );

    await _startListening((result) {
      final normalized = result.toLowerCase();

      if (normalized.contains('sí') ||
          normalized.contains('si') ||
          normalized.contains('confirmar')) {
        _promptForEmail();
      } else if (normalized.contains('no') || normalized.contains('repetir')) {
        _usernameCtrl.clear();
        _promptForUsername();
      }
    });
  }

  Future<void> _promptForEmail() async {
    setState(() {
      _currentStep = 2;
      _statusMessage = 'Email (opcional)...';
    });

    await _ttsService.speak(
      'Ahora puedes decir tu correo electrónico, o di "omitir" si no deseas agregarlo',
    );

    await Future.delayed(const Duration(milliseconds: 500));

    await _startListening((result) {
      final normalized = result.toLowerCase();

      if (normalized.contains('omitir') ||
          normalized.contains('no') ||
          normalized.contains('ninguno')) {
        _completeRegistration();
      } else {
        setState(() {
          _emailCtrl.text = result;
          _statusMessage = 'Email: $result';
        });
        _confirmEmail();
      }
    });
  }

  Future<void> _confirmEmail() async {
    final email = _emailCtrl.text;

    await _ttsService.speak(
      'Has dicho: $email. ¿Es correcto? Di "sí" para confirmar o "no" para repetir',
    );

    await _startListening((result) {
      final normalized = result.toLowerCase();

      if (normalized.contains('sí') ||
          normalized.contains('si') ||
          normalized.contains('confirmar')) {
        _completeRegistration();
      } else if (normalized.contains('no') || normalized.contains('repetir')) {
        _emailCtrl.clear();
        _promptForEmail();
      }
    });
  }

  Future<void> _completeRegistration() async {
    setState(() {
      _currentStep = 3;
      _isProcessing = true;
      _statusMessage = 'Guardando tu cuenta...';
    });

    await _ttsService.speak('Guardando tu cuenta. Por favor espera');

    try {
      final username = _usernameCtrl.text.trim();
      final email = _emailCtrl.text.trim().isEmpty
          ? null
          : _emailCtrl.text.trim();

      // Registrar localmente con biometría (la huella ya fue verificada al iniciar la pantalla)
      final success = await _biometricService.registerUserWithBiometrics(
        username: username,
        email: email,
        localizedReason: 'Confirma tu huella para completar el registro',
      );

      if (!success) {
        throw Exception('No se pudo registrar la biometría');
      }

      // Registrar en backend para persistencia cross-device
      // Usar el username como identificador único, sin password (biometric only)
      try {
        await _apiClient.biometricRegister(
          username: username,
          biometricToken: widget.biometricToken,
          email: email,
        );
      } catch (backendError) {
        // Si falla el backend, el registro local ya está hecho
        debugPrint('⚠️ Registro backend falló pero local OK: $backendError');
      }

      await _ttsService.speak(
        'Cuenta creada exitosamente. Tu huella dactilar es ahora tu método de autenticación permanente. '
        'Bienvenido, $username.',
      );

      await Future.delayed(const Duration(seconds: 3));

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _statusMessage = 'Error al crear cuenta';
      });

      await _ttsService.speak(
        'Hubo un error al crear tu cuenta. Por favor, intenta de nuevo.',
      );

      debugPrint('❌ Error en registro: $e');
    }
  }

  Future<void> _startListening(Function(String) onResult) async {
    if (!_speechAvailable) {
      await _ttsService.speak(
        'El reconocimiento de voz no está disponible en este dispositivo',
      );
      return;
    }

    // IMPORTANTE: Esperar a que TTS termine completamente antes de activar micrófono
    _log('🔊 [REGISTER] Esperando a que TTS termine de hablar...');
    await _ttsService.waitUntilDone();

    // Delay adicional de seguridad para asegurar que el audio terminó
    await Future.delayed(const Duration(milliseconds: 500));

    _log('🎤 [REGISTER] Activando micrófono ahora');

    if (mounted) {
      setState(() {
        _isListening = true;
      });

      // AHORA SÍ: Activar reconocimiento de voz
      _speech.listen(
        onResult: (result) {
          if (result.finalResult) {
            setState(() {
              _isListening = false;
            });

            onResult(result.recognizedWords);
          }
        },
        listenFor: const Duration(seconds: 10),
        pauseFor: const Duration(seconds: 3),
        localeId: 'es_ES',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Registro por Voz',
          style: TextStyle(color: Colors.black),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Indicador de paso
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildStepIndicator(1, 'Usuario'),
                  const SizedBox(width: 16),
                  _buildStepIndicator(2, 'Email'),
                  const SizedBox(width: 16),
                  _buildStepIndicator(3, 'Guardar'),
                ],
              ),

              const SizedBox(height: 48),

              // Icono animado de micrófono
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isListening
                      ? Colors.red.withValues(alpha: 0.2)
                      : Colors.grey[200],
                  border: Border.all(
                    color: _isListening ? Colors.red : Colors.grey,
                    width: 3,
                  ),
                ),
                child: Icon(
                  _isListening ? Icons.mic : Icons.mic_none,
                  size: 60,
                  color: _isListening ? Colors.red : Colors.grey[600],
                ),
              ),

              const SizedBox(height: 32),

              // Mensaje de estado
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _statusMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16),
                ),
              ),

              const SizedBox(height: 32),

              // Campos visuales (solo lectura)
              if (_usernameCtrl.text.isNotEmpty)
                _buildInfoField('Usuario', _usernameCtrl.text),

              if (_emailCtrl.text.isNotEmpty)
                _buildInfoField('Email', _emailCtrl.text),

              const SizedBox(height: 32),

              // Indicador de procesamiento
              if (_isProcessing) const CircularProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepIndicator(int step, String label) {
    final isActive = _currentStep >= step;
    final isCompleted = _currentStep > step;

    return Column(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isCompleted
                ? Colors.green
                : (isActive ? const Color(0xFF00BCD4) : Colors.grey[300]),
          ),
          child: Center(
            child: isCompleted
                ? const Icon(Icons.check, color: Colors.white, size: 20)
                : Text(
                    '$step',
                    style: TextStyle(
                      color: isActive ? Colors.white : Colors.grey[600],
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isActive ? Colors.black : Colors.grey[600],
          ),
        ),
      ],
    );
  }

  Widget _buildInfoField(String label, String value) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey[300]!),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Text(
            '$label: ',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 16))),
        ],
      ),
    );
  }
}
