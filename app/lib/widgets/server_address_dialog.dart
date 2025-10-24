import 'package:flutter/material.dart';

import '../services/backend/api_client.dart';
import '../services/backend/server_config.dart';

Future<bool> showServerAddressDialog(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => const _ServerAddressDialog(),
  );
  return result ?? false;
}

class _ServerAddressDialog extends StatefulWidget {
  const _ServerAddressDialog();

  @override
  State<_ServerAddressDialog> createState() => _ServerAddressDialogState();
}

class _ServerAddressDialogState extends State<_ServerAddressDialog> {
  final ServerConfig _config = ServerConfig.instance;
  late final TextEditingController _controller;
  String? _errorMessage;
  bool _testing = false;
  bool _testSucceeded = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _config.baseUrl);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onTestConnection() async {
    setState(() {
      _testing = true;
      _errorMessage = null;
      _testSucceeded = false;
    });

    try {
      final normalized = _config.normalizeOrFallback(_controller.text);
      final ok = await ApiClient(baseUrl: normalized).testConnection();
      if (!mounted) return;
      setState(() {
        _testSucceeded = ok;
        if (!ok) {
          _errorMessage = 'No se obtuvo respuesta del backend en $normalized';
        }
      });
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Ocurrió un error al probar la conexión.');
    } finally {
      if (mounted) {
        setState(() => _testing = false);
      }
    }
  }

  Future<void> _onReset() async {
    await _config.resetToDefault();
    if (!mounted) return;
    setState(() {
      _controller.text = _config.baseUrl;
      _errorMessage = null;
      _testSucceeded = false;
    });
  }

  Future<void> _onSave() async {
    try {
      await _config.updateBaseUrl(_controller.text);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _errorMessage = 'No fue posible guardar la configuración.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Configurar servidor backend'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Ingresa la URL base del backend accesible desde este dispositivo.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'URL del backend',
              hintText: _config.defaultBaseUrl,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Sugerido: ${_config.defaultBaseUrl}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (_testing) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(minHeight: 3),
          ],
          if (_testSucceeded) ...[
            const SizedBox(height: 12),
            Row(
              children: const [
                Icon(Icons.check_circle, color: Colors.green),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Conexión exitosa con el backend.',
                    style: TextStyle(color: Colors.green),
                  ),
                ),
              ],
            ),
          ],
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error, color: Colors.red),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _testing ? null : _onReset,
          child: const Text('Restablecer'),
        ),
        TextButton(
          onPressed: _testing ? null : _onTestConnection,
          child: const Text('Probar'),
        ),
        FilledButton(
          onPressed: _testing ? null : _onSave,
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
