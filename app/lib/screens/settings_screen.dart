import 'package:flutter/material.dart';

import '../services/auth_storage.dart';
import '../services/tts_service.dart';
import 'login_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  static const routeName = '/settings';

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _processingLogout = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(''),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            _ActionTile(
              icon: Icons.record_voice_over_outlined,
              title: 'Cambiar Voz',
              onTap: () {},
            ),
            const SizedBox(height: 16),
            _ActionTile(
              icon: Icons.warning_amber_rounded,
              title: 'Reportar Errores',
              onTap: () {},
            ),
            const SizedBox(height: 16),
            _ActionTile(
              icon: Icons.logout,
              title: _processingLogout ? 'Cerrando sesión...' : 'Cerrar Sesión',
              onTap: _processingLogout ? null : _handleLogout,
              destructive: true,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleLogout() async {
    setState(() => _processingLogout = true);
    try {
      await AuthStorage.clearToken();
      await TtsService.instance.speak('Sesión cerrada');
      if (!mounted) return;
      Navigator.of(
        context,
      ).pushNamedAndRemoveUntil(LoginScreen.routeName, (route) => false);
    } finally {
      if (mounted) {
        setState(() => _processingLogout = false);
      }
    }
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: destructive
              ? const Color(0xFFFFEAEA)
              : const Color(0xFFF6F5F6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: destructive ? Colors.red.shade200 : Colors.black12,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: destructive ? Colors.redAccent : Colors.black87),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: destructive ? Colors.redAccent : Colors.black,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: destructive ? Colors.redAccent : Colors.black54,
            ),
          ],
        ),
      ),
    );
  }
}
