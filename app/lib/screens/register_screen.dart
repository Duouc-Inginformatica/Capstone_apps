import 'package:flutter/material.dart';
import 'map_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  static const routeName = '/register';

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _userCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmPassCtrl = TextEditingController();

  @override
  void dispose() {
    _userCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _confirmPassCtrl.dispose();
    super.dispose();
  }

  void _handleRegister() {
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
      return;
    }

    // Mostrar éxito y navegar al mapa
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Cuenta creada exitosamente'),
        backgroundColor: Colors.green,
      ),
    );

    // Navegación al mapa después del registro
    Navigator.of(context).pushReplacementNamed(MapScreen.routeName);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FF),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32),
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
              const SizedBox(height: 60),
              
              // Campo Usuario
              _buildTextField(
                controller: _userCtrl,
                label: 'Usuario',
              ),
              const SizedBox(height: 20),
              
              // Campo Email
              _buildTextField(
                controller: _emailCtrl,
                label: 'Email',
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 20),
              
              // Campo Contraseña
              _buildTextField(
                controller: _passCtrl,
                label: 'Contraseña',
                obscureText: true,
              ),
              const SizedBox(height: 20),
              
              // Campo Confirmar Contraseña
              _buildTextField(
                controller: _confirmPassCtrl,
                label: 'Confirmar Contraseña',
                obscureText: true,
              ),
              const SizedBox(height: 40),
              
              // Botón de registro con flecha
              Container(
                width: double.infinity,
                height: 80,
                margin: const EdgeInsets.only(bottom: 20),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(40),
                    ),
                    elevation: 0,
                  ),
                  onPressed: _handleRegister,
                  child: const Icon(
                    Icons.arrow_forward,
                    size: 28,
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
              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              hintStyle: TextStyle(color: Colors.black54),
            ),
          ),
        ),
      ],
    );
  }
}