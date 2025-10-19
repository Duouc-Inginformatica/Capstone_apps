import 'package:flutter/material.dart';
import '../services/api_client.dart';
import '../services/tts_service.dart';
import 'map_screen.dart';

class RegisterScreen extends StatefulWidget {
  final bool biometricVerified;

  const RegisterScreen({super.key, this.biometricVerified = false});

  static const routeName = '/register';

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _userCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmPassCtrl = TextEditingController();
  final _api = ApiClient();
  bool _loading = false;

  @override
  void dispose() {
    _userCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _confirmPassCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleRegister() async {
    // Validación básica
    if (_userCtrl.text.isEmpty ||
        _emailCtrl.text.isEmpty ||
        _passCtrl.text.isEmpty ||
        _confirmPassCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Por favor complete todos los campos'),
          backgroundColor: Colors.red,
        ),
      );
      TtsService.instance.speak('Por favor complete todos los campos');
      return;
    }

    // Validar que las contraseñas coincidan
    if (_passCtrl.text != _confirmPassCtrl.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Las contraseñas no coinciden'),
          backgroundColor: Colors.red,
        ),
      );
      TtsService.instance.speak('Las contraseñas no coinciden');
      return;
    }

    // Validación básica de email
    if (!_emailCtrl.text.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Por favor ingrese un email válido'),
          backgroundColor: Colors.red,
        ),
      );
      TtsService.instance.speak('Por favor ingrese un email válido');
      return;
    }
    setState(() => _loading = true);
    try {
      await _api.register(
        username: _userCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
        password: _passCtrl.text,
        name: _userCtrl.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cuenta creada exitosamente'),
          backgroundColor: Colors.green,
        ),
      );
      TtsService.instance.speak('Cuenta creada exitosamente');
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

  String _humanErrorMessage(Object error) {
    if (error is ApiException) {
      if (error.statusCode == 409) {
        return 'El usuario o correo ya se encuentra registrado.';
      }
      if (error.statusCode >= 500) {
        return 'El servidor no está disponible. Intenta más tarde.';
      }
      if (error.message.isNotEmpty) return error.message;
    }
    return 'No se pudo crear la cuenta. Revisa los datos e inténtalo de nuevo.';
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
                  const SizedBox(height: 40),
                  // Título WayFindCL centrado
                  const Text(
                    'WayFindCL',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Subtítulo
                  const Text(
                    'Crear nueva cuenta',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                      color: Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 40), // Reducido de 60
                  // Campo Usuario
                  _buildTextField(controller: _userCtrl, label: 'Usuario'),
                  const SizedBox(height: 16), // Reducido de 20
                  // Campo Email
                  _buildTextField(
                    controller: _emailCtrl,
                    label: 'Email',
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 16), // Reducido de 20
                  // Campo Contraseña
                  _buildTextField(
                    controller: _passCtrl,
                    label: 'Contraseña',
                    obscureText: true,
                  ),
                  const SizedBox(height: 16), // Reducido de 20
                  // Campo Confirmar Contraseña
                  _buildTextField(
                    controller: _confirmPassCtrl,
                    label: 'Confirmar Contraseña',
                    obscureText: true,
                  ),

                  const Expanded(child: SizedBox()), // Flexible spacer
                  // Botón de registro con flecha
                  Container(
                    width: double.infinity,
                    height: 70, // Reducido de 80
                    margin: const EdgeInsets.only(bottom: 16), // Reducido
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(35),
                        ),
                        elevation: 0,
                      ),
                      onPressed: _handleRegister,
                      child: _loading
                          ? const SizedBox(
                              width: 24, // Reducido
                              height: 24, // Reducido
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(
                              Icons.arrow_forward,
                              size: 24, // Reducido
                              color: Colors.white,
                            ),
                    ),
                  ),

                  // Link para volver al login
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                    child: const Text(
                      '¿Ya tienes cuenta? Inicia sesión',
                      style: TextStyle(
                        color: Colors.black54,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
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

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    bool obscureText = false,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
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
            controller: controller,
            obscureText: obscureText,
            keyboardType: keyboardType,
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
    );
  }
}
