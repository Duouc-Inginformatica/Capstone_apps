import 'package:flutter/material.dart';

import '../services/device/auth_storage.dart';
import '../services/backend/server_config.dart';
import '../services/device/tts_service.dart';
import '../widgets/server_address_dialog.dart';
import 'login_screen_v2.dart';

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
        title: const Text('Configuración'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            ValueListenableBuilder<String>(
              valueListenable: ServerConfig.instance.baseUrlListenable,
              builder: (context, baseUrl, _) {
                return _ActionTile(
                  icon: Icons.cloud_outlined,
                  title: 'Servidor Backend',
                  subtitle: baseUrl,
                  onTap: _showServerConfigDialog,
                );
              },
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
      ).pushNamedAndRemoveUntil(LoginScreenV2.routeName, (route) => false);
    } finally {
      if (mounted) {
        setState(() => _processingLogout = false);
      }
    }
  }

  Future<void> _showServerConfigDialog() async {
    final updated = await showServerAddressDialog(context);
    if (!mounted || !updated) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('URL del servidor actualizada.')),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final VoidCallback? onTap;
  final String? subtitle;
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: destructive ? Colors.redAccent : Colors.black,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: destructive ? Colors.redAccent : Colors.black54,
                      ),
                    ),
                  ],
                ],
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
