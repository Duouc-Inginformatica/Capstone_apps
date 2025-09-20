import 'package:flutter/material.dart';
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

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _handleLogin() {
    // Validación básica
    if (_userCtrl.text.isEmpty || _passCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Por favor complete todos los campos'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Navegación al mapa
    Navigator.of(context).pushReplacementNamed(MapScreen.routeName);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FF),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
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
              const SizedBox(height: 80),
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
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                        hintStyle: TextStyle(color: Colors.black54),
                      ),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              // Botón de login con flecha
              Container(
                width: double.infinity,
                height: 80,
                margin: const EdgeInsets.only(bottom: 40),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(40),
                    ),
                    elevation: 0,
                  ),
                  onPressed: _handleLogin,
                  child: const Icon(
                    Icons.arrow_forward,
                    size: 28,
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
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
