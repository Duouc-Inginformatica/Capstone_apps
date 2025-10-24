import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
        title: const Text(''),
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
                  title: 'Servidor backend',
                  subtitle: baseUrl,
                  onTap: _showServerConfigDialog,
                );
              },
            ),
            const SizedBox(height: 16),
            _ActionTile(
              icon: Icons.record_voice_over_outlined,
              title: 'Cambiar Voz del Asistente',
              subtitle: 'Elige entre 6 voces diferentes',
              onTap: _showVoiceSelector,
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

  /// Muestra selector de voz para usuarios no videntes
  Future<void> _showVoiceSelector() async {
    final voiceMap = {
      'F1': {
        'name': 'Asistente Clara',
        'emoji': '👩',
        'description': 'Voz femenina clara y dulce',
      },
      'F2': {
        'name': 'Asistente María',
        'emoji': '👩‍🦰',
        'description': 'Voz femenina suave y cálida',
      },
      'F3': {
        'name': 'Asistente Ana',
        'emoji': '👩‍🦱',
        'description': 'Voz femenina natural',
      },
      'M1': {
        'name': 'Asistente Carlos',
        'emoji': '👨',
        'description': 'Voz masculina profunda',
      },
      'M2': {
        'name': 'Asistente David',
        'emoji': '👨‍💼',
        'description': 'Voz masculina profesional',
      },
      'M3': {
        'name': 'Asistente Miguel',
        'emoji': '👨‍🦱',
        'description': 'Voz masculina equilibrada',
      },
    };

    // Anunciar que se abre el selector
    await TtsService.instance.speak(
      'Selector de voz. Toca una opción para escuchar y seleccionar tu asistente preferido.',
    );

    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.record_voice_over,
                  color: Color(0xFF00BCD4),
                  size: 28,
                ),
                const SizedBox(width: 12),
                const Text(
                  'Elige tu Asistente',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Toca para escuchar cada voz',
              style: TextStyle(color: Colors.grey[600], fontSize: 14),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 320,
              child: ListView.builder(
                itemCount: voiceMap.length,
                itemBuilder: (context, index) {
                  final voiceId = voiceMap.keys.elementAt(index);
                  final voice = voiceMap[voiceId]!;

                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    elevation: 2,
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      leading: Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: const Color(0xFF00BCD4).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(
                          child: Text(
                            voice['emoji'] as String,
                            style: const TextStyle(fontSize: 28),
                          ),
                        ),
                      ),
                      title: Text(
                        voice['name'] as String,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          voice['description'] as String,
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 13,
                          ),
                        ),
                      ),
                      trailing: const Icon(
                        Icons.play_circle_outline,
                        color: Color(0xFF00BCD4),
                        size: 32,
                      ),
                      onTap: () async {
                        // Probar voz con TTS clásico
                        await TtsService.instance.speak(
                          'Hola, soy ${voice['name']}. Estaré guiándote en WayFind CL.',
                        );

                        // Guardar selección
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setString('assistant_voice', voiceId);

                        if (context.mounted) {
                          Navigator.pop(context);

                          // Confirmar selección
                          await TtsService.instance.speak(
                            '${voice['name']} seleccionada. Regresando a configuración.',
                          );
                        }
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
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
