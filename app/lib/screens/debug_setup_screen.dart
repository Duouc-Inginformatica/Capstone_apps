import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/server_config.dart';
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
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _portController = TextEditingController();

  bool _manualBusy = false;
  bool _manualSuccess = false;
  String? _manualError;

  @override
  void initState() {
    super.initState();
    _syncManualFieldsWithConfig();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  void _syncManualFieldsWithConfig() {
    final uri = Uri.tryParse(ServerConfig.instance.baseUrl);

    _hostController.text = uri?.host ?? '';
    _portController.text = (uri?.hasPort ?? false)
        ? uri!.port.toString()
        : '8080';

    _manualError = null;
    _manualSuccess = false;

    if (mounted) {
      setState(() {});
    }
  }

  void _clearManualStatus() {
    if (!_manualBusy) {
      setState(() {
        _manualError = null;
        _manualSuccess = false;
      });
    }
  }

  Future<void> _onTestAndSaveManual() async {
    if (_manualBusy) return;

    setState(() {
      _manualBusy = true;
      _manualError = null;
      _manualSuccess = false;
    });

    final host = _hostController.text.trim();
    final portText = _portController.text.trim();

    if (host.isEmpty) {
      setState(() {
        _manualBusy = false;
        _manualError = 'Debes ingresar una dirección IP o dominio.';
      });
      return;
    }

    final port = int.tryParse(portText);
    if (port == null || port <= 0 || port > 65535) {
      setState(() {
        _manualBusy = false;
        _manualError = 'El puerto debe ser un número entre 1 y 65535.';
      });
      return;
    }

    final uri = Uri(scheme: 'http', host: host, port: port).toString();

    try {
      final ok = await ApiClient(baseUrl: uri).testConnection();
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _manualBusy = false;
          _manualError = 'No se obtuvo respuesta del backend en $uri';
        });
        return;
      }

      await ServerConfig.instance.updateBaseUrl(uri);
      if (!mounted) return;
      setState(() {
        _manualBusy = false;
        _manualSuccess = true;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Backend configurado en $uri')));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _manualBusy = false;
        _manualError = 'Ocurrió un error al probar la conexión.';
      });
    }
  }

  Future<void> _resetToDefault() async {
    await ServerConfig.instance.resetToDefault();
    _syncManualFieldsWithConfig();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Se restauró la configuración detectada.')),
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
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 36,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(context),
                    const SizedBox(height: 20),
                    const _InfoBanner(),
                    const SizedBox(height: 20),
                    ValueListenableBuilder<String>(
                      valueListenable: ServerConfig.instance.baseUrlListenable,
                      builder: (context, baseUrl, _) {
                        return _buildBackendCard(context, baseUrl);
                      },
                    ),
                    const SizedBox(height: 20),
                    _buildQuickActionsCard(context),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 22,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFF00BCD4).withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.construction,
              color: Color(0xFF00BCD4),
              size: 26,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'Panel de herramientas',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Ajusta el backend detectado o salta a flujos críticos antes del login.',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackendCard(BuildContext context, String baseUrl) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Backend actual',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const LinearGradient(
                  colors: [Color(0xFFE0F2F1), Color(0xFFB2EBF2)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.cloud_outlined, color: Color(0xFF006064)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SelectableText(
                      baseUrl,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: Color(0xFF004D40),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _resetToDefault,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF0F172A),
              ),
              icon: const Icon(Icons.refresh),
              label: const Text('Restaurar detectado'),
            ),
            const Divider(height: 32),
            const Text(
              'Personalizar IP y puerto',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _hostController,
                    decoration: const InputDecoration(
                      labelText: 'Host / IP',
                      hintText: '192.168.1.20',
                      filled: true,
                      fillColor: Color(0xFFF1F5F9),
                    ),
                    onChanged: (_) => _clearManualStatus(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Puerto',
                      hintText: '8080',
                      filled: true,
                      fillColor: Color(0xFFF1F5F9),
                    ),
                    onChanged: (_) => _clearManualStatus(),
                  ),
                ),
              ],
            ),
            if (_manualError != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFEBEE),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline, color: Color(0xFFD32F2F)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _manualError!,
                        style: const TextStyle(color: Color(0xFFD32F2F)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (_manualSuccess) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: const [
                    Icon(Icons.check_circle_outline, color: Color(0xFF2E7D32)),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Conexión verificada y guardada.',
                        style: TextStyle(color: Color(0xFF2E7D32)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _manualBusy ? null : _onTestAndSaveManual,
                    icon: _manualBusy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2.2),
                          )
                        : const Icon(Icons.cloud_sync),
                    label: const Text('Probar y guardar'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00BCD4),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _goToLogin,
                    icon: const Icon(Icons.login),
                    label: const Text('Volver al login'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF0F172A),
                      side: const BorderSide(color: Color(0xFFCBD5F5)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActionsCard(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Accesos rápidos',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            const Text(
              'Salta directamente a los flujos clave durante las pruebas.',
              style: TextStyle(fontSize: 13, color: Color(0xFF475569)),
            ),
            const SizedBox(height: 18),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF34D399), Color(0xFF059669)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF059669).withValues(alpha: 0.28),
                    blurRadius: 18,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.map_outlined, color: Colors.white),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text(
                          'Ir directo al mapa',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Carga la vista principal sin pasar por el onboarding.',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  ElevatedButton(
                    onPressed: _goDirectToMap,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF064E3B),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('Abrir'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colorScheme.secondaryContainer,
            colorScheme.secondaryContainer.withValues(alpha: 0.8),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Text(
            'Debug toolkit',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 4),
          Text(
            'Define a qué backend apuntas antes de iniciar sesión y accede a accesos directos para QA.',
            style: TextStyle(fontSize: 13, color: Color(0xFF334155)),
          ),
        ],
      ),
    );
  }
}
