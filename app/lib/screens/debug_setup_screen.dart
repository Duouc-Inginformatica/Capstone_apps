import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/server_config.dart';
import '../services/tts_service.dart';
import '../widgets/server_address_dialog.dart';
import 'login_screen_v2.dart';
import 'map_screen.dart';

/// Pantalla de utilidades para desarrolladores
/// Permite ajustar la URL del backend y probar accesos rápidos antes del login.
class DebugSetupScreen extends StatefulWidget {
  const DebugSetupScreen({super.key});

  static const routeName = '/debug/setup';

  @override
  State<DebugSetupScreen> createState() => _DebugSetupScreenState();
}

class _DebugSetupScreenState extends State<DebugSetupScreen> {
  bool _isApplyingPreset = false;

  @override
  void initState() {
    super.initState();
    _announceContext();
  }

  Future<void> _announceContext() async {
    if (!kDebugMode) return;
    await TtsService.instance.speak(
      'Modo desarrollador. Configura el servidor antes de continuar al inicio de sesión.',
    );
  }

  Future<void> _openServerDialog() async {
    final updated = await showServerAddressDialog(context);
    if (!mounted) return;
    if (updated) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('URL del backend actualizada'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _applyPreset(String url) async {
    if (_isApplyingPreset) return;
    setState(() => _isApplyingPreset = true);
    try {
      await ServerConfig.instance.updateBaseUrl(url);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Backend configurado en $url'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No se pudo aplicar la URL: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isApplyingPreset = false);
      }
    }
  }

  Future<void> _resetToDefault() async {
    await ServerConfig.instance.resetToDefault();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Backend restaurado a la configuración detectada'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _goToLogin() {
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreenV2()));
  }

  void _goDirectToMap() {
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => const MapScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FF),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const SizedBox(),
        centerTitle: true,
        title: const Text(
          'Modo desarrollador',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF00BCD4), Color(0xFF006C84)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(
                            0xFF00BCD4,
                          ).withValues(alpha: 0.25),
                          blurRadius: 18,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Debug Toolkit',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Configura el backend, prueba accesos rápidos y ajusta la aplicación antes del login.',
                          style: TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  ValueListenableBuilder<String>(
                    valueListenable: ServerConfig.instance.baseUrlListenable,
                    builder: (context, baseUrl, _) {
                      return Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.05),
                              blurRadius: 18,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Backend actual',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF111827),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.cloud_outlined,
                                    color: Color(0xFF0284C7),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      baseUrl,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF0F172A),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                _PresetButton(
                                  label: 'Localhost',
                                  onTap: () =>
                                      _applyPreset('http://127.0.0.1:8080'),
                                  isBusy: _isApplyingPreset,
                                ),
                                _PresetButton(
                                  label: 'Emulador Android',
                                  onTap: () =>
                                      _applyPreset('http://10.0.2.2:8080'),
                                  isBusy: _isApplyingPreset,
                                ),
                                _PresetButton(
                                  label: 'Prod WayFind CL',
                                  onTap: () =>
                                      _applyPreset('https://api.wayfindcl.dev'),
                                  isBusy: _isApplyingPreset,
                                ),
                                OutlinedButton.icon(
                                  onPressed: _resetToDefault,
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Restaurar detectado'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton.icon(
                              onPressed: _openServerDialog,
                              icon: const Icon(Icons.settings_ethernet),
                              label: const Text('Configurar manualmente'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF111827),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 18,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Accesos rápidos',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF111827),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Usa estas acciones para probar flujos sin tener que pasar por el login cada vez.',
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFF475569),
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: _goToLogin,
                          icon: const Icon(Icons.login),
                          label: const Text('Ir al login principal'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00BCD4),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _goDirectToMap,
                          icon: const Icon(Icons.map_outlined),
                          label: const Text('Ir directo al mapa (debug)'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF111827),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            side: const BorderSide(color: Color(0xFF94A3B8)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PresetButton extends StatelessWidget {
  const _PresetButton({
    required this.label,
    required this.onTap,
    required this.isBusy,
  });

  final String label;
  final VoidCallback onTap;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: isBusy ? null : onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFFE0F2FE),
        foregroundColor: const Color(0xFF0369A1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      ),
      child: Text(label),
    );
  }
}
