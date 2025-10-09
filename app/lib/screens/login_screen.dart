import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../services/auth_storage.dart';
import '../services/api_client.dart';
import '../services/server_config.dart';
import '../services/tts_service.dart';
import '../widgets/server_address_dialog.dart';
import 'map_screen.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  static const routeName = '/login';

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _api = ApiClient();
  bool _loading = false;
  final SpeechToText _speech = SpeechToText();
  bool _speechAvailable = false;
  bool _isListening = false;
  String _lastVoiceSnippet = '';
  Timer? _listenTimeout;
  static const Duration _voiceSessionTimeout = Duration(seconds: 12);
  final LocalAuthentication _localAuth = LocalAuthentication();
  bool _biometricSupported = false;
  StoredCredentials? _storedCredentials;

  @override
  void initState() {
    super.initState();
    _initVoiceSupport();
    _initBiometrics();
    WidgetsBinding.instance.addPostFrameCallback((_) => _announceVoiceHelp());
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    _listenTimeout?.cancel();
    _speech.stop();
    super.dispose();
  }

  bool get _canUseBiometrics =>
      _biometricSupported && _storedCredentials != null;

  Future<void> _initVoiceSupport() async {
    final available = await _speech.initialize(
      onStatus: _onSpeechStatus,
      onError: _onSpeechError,
      debugLogging: false,
    );

    if (!mounted) return;
    setState(() => _speechAvailable = available);

    if (!available) {
      TtsService.instance.speak(
        'Control por voz no disponible por ahora. Puedes intentar de nuevo más tarde.',
      );
    }
  }

  Future<void> _initBiometrics() async {
    try {
      final supported = await _localAuth.isDeviceSupported();
      final canCheck = await _localAuth.canCheckBiometrics;
      final creds = await AuthStorage.readCredentials();
      if (!mounted) return;
      setState(() {
        _biometricSupported = supported && canCheck;
        _storedCredentials = creds;
      });
      if (_biometricSupported) {
        if (creds != null) {
          TtsService.instance.speak(
            'Huella disponible. Puedes decir "usar huella" para acceder rápidamente.',
          );
        } else {
          TtsService.instance.speak(
            'Puedes activar el acceso con huella después de iniciar sesión una vez.',
          );
        }
      }
    } on PlatformException {
      if (!mounted) return;
      setState(() => _biometricSupported = false);
    }
  }

  void _onSpeechStatus(String status) {
    if (!mounted) return;
    if (status == 'listening') {
      setState(() => _isListening = true);
    } else if (status == 'notListening') {
      _listenTimeout?.cancel();
      setState(() => _isListening = false);
    }
  }

  void _onSpeechError(SpeechRecognitionError error) {
    _listenTimeout?.cancel();
    if (!mounted) return;
    setState(() => _isListening = false);
    TtsService.instance.speak('Error de reconocimiento: ${error.errorMsg}');
  }

  Future<void> _startVoiceCapture() async {
    if (!_speechAvailable) {
      TtsService.instance.speak('Control por voz no disponible.');
      return;
    }

    final permission = await Permission.microphone.request();
    if (!permission.isGranted) {
      TtsService.instance.speak(
        'Necesito permiso de micrófono para escucharte.',
      );
      return;
    }

    _listenTimeout?.cancel();
    _listenTimeout = Timer(_voiceSessionTimeout, () {
      if (_isListening) {
        _stopVoiceCapture(force: true);
      }
    });

    await _speech.listen(
      onResult: _handleSpeechResult,
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 2),
      localeId: 'es-CL',
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
        sampleRate: 16000,
      ),
    );

    if (!mounted) return;
    setState(() => _isListening = true);
    TtsService.instance.speak(
      'Escuchando. Usa comandos como usuario, contraseña o iniciar sesión.',
    );
  }

  Future<void> _stopVoiceCapture({bool force = false}) async {
    _listenTimeout?.cancel();
    await _speech.stop();
    if (!mounted) return;
    setState(() => _isListening = false);
    if (force) {
      TtsService.instance.speak('Tiempo de escucha agotado.');
    }
  }

  void _handleSpeechResult(SpeechRecognitionResult result) {
    if (!mounted) return;

    if (result.finalResult) {
      _listenTimeout?.cancel();
      final spoken = result.recognizedWords.trim();
      if (spoken.isEmpty) {
        TtsService.instance.speak('No escuché ningún comando.');
        return;
      }
      setState(() => _lastVoiceSnippet = spoken);
      unawaited(_processVoiceCommand(spoken));
    } else {
      setState(() => _lastVoiceSnippet = result.recognizedWords);
    }
  }

  void _announceVoiceHelp() {
    TtsService.instance.speak(
      'Pantalla de inicio. Di usuario seguido de tu nombre de usuario, contraseña seguida de tu clave y luego iniciar sesión para acceder. Pide ayuda cuando la necesites.',
    );
  }

  String? _extractValue(String command, List<String> keywords) {
    for (final keyword in keywords) {
      final index = command.toLowerCase().indexOf(keyword.toLowerCase());
      if (index != -1) {
        final value = command.substring(index + keyword.length).trim();
        if (value.isNotEmpty) {
          return value;
        }
      }
    }
    return null;
  }

  Future<void> _processVoiceCommand(String command) async {
    final normalized = command.toLowerCase();

    if (normalized.contains('ayuda')) {
      _announceVoiceHelp();
      return;
    }

    final usernameValue = _extractValue(command, [
      'usuario es',
      'usuario',
      'mi usuario es',
    ]);
    if (usernameValue != null) {
      _userCtrl.text = usernameValue;
      TtsService.instance.speak('Usuario establecido en $usernameValue.');
      return;
    }

    final passwordValue = _extractValue(command, [
      'contraseña es',
      'contraseña',
      'mi contraseña es',
      'clave',
    ]);
    if (passwordValue != null) {
      _passCtrl.text = passwordValue;
      TtsService.instance.speak('Contraseña ingresada.');
      return;
    }

    if (normalized.contains('iniciar sesión') ||
        normalized.contains('iniciar sesion')) {
      await _stopVoiceCapture();
      TtsService.instance.speak('Intentando iniciar sesión.');
      await _handleLogin();
      return;
    }

    if (normalized.contains('registr') || normalized.contains('crear cuenta')) {
      await _stopVoiceCapture();
      if (!mounted) return;
      TtsService.instance.speak('Abriendo registro.');
      Navigator.of(context).pushNamed(RegisterScreen.routeName);
      return;
    }

    if (normalized.contains('probar conexión') ||
        normalized.contains('probar conexion')) {
      await _stopVoiceCapture();
      await _testConnection();
      return;
    }

    if (normalized.contains('configurar servidor') ||
        normalized.contains('servidor')) {
      await _stopVoiceCapture();
      await _openServerDialog();
      return;
    }

    if (normalized.contains('limpiar datos') ||
        normalized.contains('borrar campos')) {
      _userCtrl.clear();
      _passCtrl.clear();
      TtsService.instance.speak('Campos borrados.');
      return;
    }

    if (normalized.contains('usar huella') ||
        normalized.contains('huella digital') ||
        normalized.contains('biométric') ||
        normalized.contains('biometrico')) {
      await _stopVoiceCapture();
      await _authenticateBiometric();
      return;
    }

    if (normalized.contains('olvidar credenciales') ||
        normalized.contains('borrar credenciales')) {
      await AuthStorage.clearCredentials();
      if (!mounted) return;
      setState(() => _storedCredentials = null);
      TtsService.instance.speak('Credenciales guardadas eliminadas.');
      return;
    }

    if (normalized.contains('leer usuario')) {
      final message = _userCtrl.text.isEmpty
          ? 'Aún no ingresas un usuario.'
          : 'Usuario actual ${_userCtrl.text}.';
      TtsService.instance.speak(message);
      return;
    }

    if (normalized.contains('estado contraseña') ||
        normalized.contains('contraseña ingresada')) {
      final length = _passCtrl.text.length;
      final message = length == 0
          ? 'Sin contraseña ingresada.'
          : 'Contraseña con $length caracteres.';
      TtsService.instance.speak(message);
      return;
    }

    if (normalized.contains('base') && normalized.contains('servidor')) {
      final url = ServerConfig.instance.baseUrl;
      TtsService.instance.speak('Servidor configurado en $url');
      return;
    }

    TtsService.instance.speak(
      'No reconocí el comando. Puedes decir ayuda para escuchar las opciones.',
    );
  }

  Future<void> _handleLogin() async {
    if (_userCtrl.text.isEmpty || _passCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Por favor complete todos los campos'),
          backgroundColor: Colors.red,
        ),
      );
      TtsService.instance.speak('Por favor complete todos los campos');
      return;
    }
    setState(() => _loading = true);
    try {
      await _api.login(
        username: _userCtrl.text.trim(),
        password: _passCtrl.text,
      );
      await AuthStorage.saveCredentials(_userCtrl.text.trim(), _passCtrl.text);
      if (!mounted) return;
      setState(() {
        _storedCredentials = StoredCredentials(
          username: _userCtrl.text.trim(),
          password: _passCtrl.text,
        );
      });
      if (!mounted) return;
      TtsService.instance.speak('Inicio de sesión correcto');
      Navigator.of(context).pushReplacementNamed(MapScreen.routeName);
    } catch (e) {
      if (!mounted) return;
      final msg = _humanErrorMessage(e);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
      TtsService.instance.speak(msg);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _authenticateBiometric() async {
    if (!_biometricSupported) {
      TtsService.instance.speak(
        'La autenticación biométrica no está disponible.',
      );
      return;
    }

    final creds = await AuthStorage.readCredentials();
    if (creds == null) {
      TtsService.instance.speak(
        'Debes iniciar sesión una vez para guardar tus credenciales antes de usar la huella.',
      );
      return;
    }

    try {
      final result = await _localAuth.authenticate(
        localizedReason: 'Verifica tu identidad para iniciar sesión',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );

      if (!result) {
        TtsService.instance.speak('No se pudo verificar la huella.');
        return;
      }

      if (!mounted) return;
      setState(() {
        _userCtrl.text = creds.username;
        _passCtrl.text = creds.password;
      });
      TtsService.instance.speak('Huella verificada. Iniciando sesión ahora.');
      await _handleLogin();
    } on PlatformException catch (e) {
      TtsService.instance.speak(
        'Error usando la huella: ${e.message ?? 'intenta nuevamente.'}',
      );
    }
  }

  String _humanErrorMessage(Object error) {
    if (error is ApiException) {
      if (error.statusCode == 401) {
        return 'Credenciales inválidas. Verifique usuario y contraseña.';
      }
      if (error.isNetworkError) {
        return '${error.message}\n\n💡 Ayuda: Si estás usando un dispositivo físico, '
            'el servidor debe estar ejecutándose en la misma red WiFi.';
      }
      if (error.message.isNotEmpty) return error.message;
    }
    return 'Ocurrió un problema al iniciar sesión. Inténtelo de nuevo.';
  }

  Future<void> _testConnection() async {
    setState(() => _loading = true);
    try {
      final connected = await _api.testConnection();
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            connected
                ? '✅ Conexión exitosa con el servidor'
                : '❌ No se pudo conectar con el servidor',
          ),
          backgroundColor: connected ? Colors.green : Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );

      TtsService.instance.speak(
        connected
            ? 'Conexión exitosa con el servidor'
            : 'No se pudo conectar con el servidor',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error probando conexión: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showNetworkHelp() {
    final serverUrl = ServerConfig.instance.baseUrl;
    final suggested = ServerConfig.instance.defaultBaseUrl;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.network_check, color: Colors.blue),
            SizedBox(width: 8),
            Text('Configuración de Red'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'URL del servidor actual:',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey[700],
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                serverUrl,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: Colors.blue,
                ),
              ),
              if (suggested != serverUrl) ...[
                const SizedBox(height: 12),
                Text(
                  'Sugerencia automática: $suggested',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Colors.black54,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              const Text(
                '📱 Para dispositivos físicos:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                '1. Conecta tu dispositivo y PC a la misma WiFi\n'
                '2. En el PC, abre cmd y ejecuta: ipconfig\n'
                '3. Busca tu IP (ej: 192.168.1.100)\n'
                '4. El servidor debe estar en: http://TU_IP:8080\n'
                '5. Asegúrate que el backend esté ejecutándose',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              const Text(
                '🖥️ Para emulador:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Android: usa 10.0.2.2:8080\n'
                'iOS: usa 127.0.0.1:8080',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              const Text(
                '🔧 Verificar backend:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Ejecuta en terminal:\n'
                'cd app_backend\n'
                'go run cmd/server/main.go',
                style: TextStyle(fontSize: 13, fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  Future<void> _openServerDialog() async {
    final updated = await showServerAddressDialog(context);
    if (!mounted || !updated) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('URL del servidor actualizada.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FF),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight:
                  MediaQuery.of(context).size.height -
                  MediaQuery.of(context).padding.top -
                  MediaQuery.of(context).padding.bottom,
            ),
            child: IntrinsicHeight(
              child: Column(
                children: [
                  const SizedBox(height: 60),
                  // Título WayFindCL centrado
                  const Text(
                    'WayFindCL',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 60), // Reducido de 80
                  // Campo Usuario
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Usuario',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 56,
                        decoration: BoxDecoration(
                          color: const Color(0xFFD9D9D9),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: TextField(
                          controller: _userCtrl,
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 16,
                            ),
                            hintStyle: TextStyle(color: Colors.black54),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Campo Contraseña
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Contraseña',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 56,
                        decoration: BoxDecoration(
                          color: const Color(0xFFD9D9D9),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: TextField(
                          controller: _passCtrl,
                          obscureText: true,
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 16,
                            ),
                            hintStyle: TextStyle(color: Colors.black54),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Expanded(child: SizedBox()), // Flexible spacer
                  // Botón de login con flecha
                  Container(
                    width: double.infinity,
                    height: 70, // Reducido de 80
                    margin: const EdgeInsets.only(bottom: 20), // Reducido
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(35),
                        ),
                        elevation: 0,
                      ),
                      onPressed: _handleLogin,
                      child: _loading
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(
                              Icons.arrow_forward,
                              size: 24,
                              color: Colors.white,
                            ),
                    ),
                  ),

                  // Link para ir al registro
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pushNamed(RegisterScreen.routeName);
                    },
                    child: const Text(
                      '¿No tienes cuenta? Regístrate',
                      style: TextStyle(
                        color: Colors.black54,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),

                  // Botones auxiliares agrupados sin overflow
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: _testConnection,
                        icon: const Icon(
                          Icons.wifi_outlined,
                          color: Colors.blue,
                          size: 16,
                        ),
                        label: const Text(
                          'Probar conexión',
                          style: TextStyle(
                            color: Colors.blue,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _showNetworkHelp,
                        icon: const Icon(
                          Icons.help_outline,
                          color: Colors.grey,
                          size: 16,
                        ),
                        label: const Text(
                          'Ayuda red',
                          style: TextStyle(
                            color: Colors.grey,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _openServerDialog,
                        icon: const Icon(
                          Icons.settings_ethernet,
                          color: Colors.black54,
                          size: 16,
                        ),
                        label: const Text(
                          'Servidor',
                          style: TextStyle(
                            color: Colors.black54,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 20,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          'Control por voz',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Pulsa el micrófono y di "usuario", "contraseña", "iniciar sesión" o "usar huella".',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _isListening
                                ? _stopVoiceCapture
                                : _startVoiceCapture,
                            icon: Icon(
                              _isListening ? Icons.hearing : Icons.mic,
                            ),
                            label: Text(
                              _isListening
                                  ? 'Escuchando...'
                                  : 'Activar micrófono',
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _isListening
                                  ? Colors.redAccent
                                  : Colors.black,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),
                        ),
                        if (_lastVoiceSnippet.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Último comando: $_lastVoiceSnippet',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.black54,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_biometricSupported) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 20,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            'Acceso con huella',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _storedCredentials != null
                                ? 'Puedes iniciar diciendo "usar huella" o pulsando el botón.'
                                : 'Inicia sesión una vez para guardar tus credenciales y usar la huella.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _canUseBiometrics
                                  ? _authenticateBiometric
                                  : null,
                              icon: const Icon(Icons.fingerprint),
                              label: Text(
                                _canUseBiometrics
                                    ? 'Usar huella para iniciar'
                                    : 'Huella no disponible todavía',
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _canUseBiometrics
                                    ? Colors.black
                                    : Colors.grey,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ),
                          if (_storedCredentials != null) ...[
                            const SizedBox(height: 12),
                            TextButton(
                              onPressed: () async {
                                await AuthStorage.clearCredentials();
                                if (!mounted) return;
                                setState(() => _storedCredentials = null);
                                TtsService.instance.speak(
                                  'Credenciales guardadas eliminadas.',
                                );
                              },
                              child: const Text(
                                'Olvidar credenciales guardadas',
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  ValueListenableBuilder<String>(
                    valueListenable: ServerConfig.instance.baseUrlListenable,
                    builder: (context, url, _) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'Usando backend en: $url',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.black54,
                            fontSize: 11,
                          ),
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
