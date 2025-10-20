import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/neural_tts_service.dart';
import 'login_screen_v2.dart';

/// Pantalla inicial para selección de voz TTS
/// Se muestra ANTES del login para que usuarios no videntes elijan su asistente preferido
class VoiceSelectionScreen extends StatefulWidget {
  const VoiceSelectionScreen({super.key});

  @override
  State<VoiceSelectionScreen> createState() => _VoiceSelectionScreenState();
}

class _VoiceSelectionScreenState extends State<VoiceSelectionScreen> {
  final _neuralTts = NeuralTtsService.instance;
  bool _isInitializing = true;
  bool _isAvailable = false;
  String? _selectedVoiceId;
  bool _isTesting = false;

  // Mapeo de voces con nombres amigables para usuarios no videntes
  static const Map<String, Map<String, dynamic>> assistantVoices = {
    'F1': {
      'name': 'Asistente Clara',
      'description': 'Voz femenina clara y dulce',
      'emoji': '👩',
      'sample': 'Hola, soy Clara. Estaré guiándote en WayFind CL.',
    },
    'F2': {
      'name': 'Asistente María',
      'description': 'Voz femenina suave y cálida',
      'emoji': '👩‍🦰',
      'sample': 'Hola, soy María. Puedo ayudarte a navegar por la ciudad.',
    },
    'F3': {
      'name': 'Asistente Ana',
      'description': 'Voz femenina natural y amigable',
      'emoji': '👩‍🦱',
      'sample': 'Hola, soy Ana. Estoy aquí para asistirte en tu viaje.',
    },
    'M1': {
      'name': 'Asistente Carlos',
      'description': 'Voz masculina profunda y clara',
      'emoji': '👨',
      'sample': 'Hola, soy Carlos. Te guiaré en tus recorridos.',
    },
    'M2': {
      'name': 'Asistente David',
      'description': 'Voz masculina profesional',
      'emoji': '👨‍💼',
      'sample': 'Hola, soy David. Estoy listo para ayudarte.',
    },
    'M3': {
      'name': 'Asistente Miguel',
      'description': 'Voz masculina equilibrada y versátil',
      'emoji': '👨‍🦱',
      'sample': 'Hola, soy Miguel. Será un placer acompañarte.',
    },
  };

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    setState(() => _isInitializing = true);

    // Verificar si ya eligió una voz anteriormente
    final prefs = await SharedPreferences.getInstance();
    final savedVoice = prefs.getString('assistant_voice');

    // Si ya seleccionó, ir directo al login
    if (savedVoice != null) {
      if (!mounted) return;
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreenV2()),
      );
      return;
    }

    // Primera vez: mostrar selección de voz
    // Inicializar TTS Neural
    final success = await _neuralTts.initialize();

    if (success) {
      // PRIMERO: Dar bienvenida con voz (mantener UI bloqueada)
      await Future.delayed(const Duration(milliseconds: 500));
      await _neuralTts.speak(
        'Bienvenido a WayFind CL. Por favor, elige tu asistente de voz.',
        voiceId: 'F1',
      );

      // LUEGO: Esperar que termine de hablar antes de mostrar opciones
      await Future.delayed(const Duration(milliseconds: 800));

      // AHORA SÍ: Mostrar UI interactiva
      if (mounted) {
        setState(() {
          _isAvailable = true;
          _selectedVoiceId = 'F1'; // Selección por defecto
          _isInitializing = false;
        });
      }
    } else {
      // Fallback a voz nativa del sistema
      setState(() {
        _isAvailable = false;
        _isInitializing = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('TTS Neural no disponible. Usando voz del sistema.'),
            duration: Duration(seconds: 3),
          ),
        );
      }

      // Continuar al login sin selección
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const LoginScreenV2()),
        );
      }
    }
  }

  Future<void> _testVoice(String voiceId) async {
    if (_isTesting) return;

    setState(() {
      _isTesting = true;
      _selectedVoiceId = voiceId;
    });

    final voiceData = assistantVoices[voiceId]!;
    await _neuralTts.speak(voiceData['sample'] as String, voiceId: voiceId);

    setState(() => _isTesting = false);
  }

  Future<void> _confirmSelection() async {
    if (_selectedVoiceId == null) return;

    // Guardar selección
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('assistant_voice', _selectedVoiceId!);

    // Confirmación
    final voiceData = assistantVoices[_selectedVoiceId]!;
    await _neuralTts.speak(
      '${voiceData['name']} seleccionada. Continuando al inicio de sesión.',
      voiceId: _selectedVoiceId,
    );

    await Future.delayed(const Duration(milliseconds: 1500));

    // Navegar al login
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreenV2()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializing) {
      return Scaffold(
        backgroundColor: const Color(0xFF00BCD4),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 24),
              Text(
                'Inicializando sistema de voz...',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isAvailable) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Elige tu Asistente de Voz'),
        backgroundColor: const Color(0xFF00BCD4),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Column(
        children: [
          // Banner informativo
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              color: Color(0xFF00BCD4),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(32),
                bottomRight: Radius.circular(32),
              ),
            ),
            child: Column(
              children: [
                const Icon(
                  Icons.record_voice_over,
                  size: 64,
                  color: Colors.white,
                ),
                const SizedBox(height: 16),
                Text(
                  'Selecciona el asistente que te acompañará',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Toca una opción para escuchar la voz',
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Lista de voces
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: assistantVoices.length,
              itemBuilder: (context, index) {
                final voiceId = assistantVoices.keys.elementAt(index);
                final voiceData = assistantVoices[voiceId]!;
                final isSelected = _selectedVoiceId == voiceId;
                final isTesting = _isTesting && isSelected;

                return Card(
                  elevation: isSelected ? 8 : 2,
                  margin: const EdgeInsets.only(bottom: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: isSelected
                          ? const Color(0xFF00BCD4)
                          : Colors.transparent,
                      width: 3,
                    ),
                  ),
                  child: InkWell(
                    onTap: () => _testVoice(voiceId),
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        children: [
                          // Emoji del asistente
                          Container(
                            width: 60,
                            height: 60,
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFF00BCD4)
                                  : Colors.grey[200],
                              borderRadius: BorderRadius.circular(30),
                            ),
                            child: Center(
                              child: isTesting
                                  ? const CircularProgressIndicator(
                                      color: Colors.white,
                                      strokeWidth: 3,
                                    )
                                  : Text(
                                      voiceData['emoji'] as String,
                                      style: const TextStyle(fontSize: 32),
                                    ),
                            ),
                          ),

                          const SizedBox(width: 16),

                          // Información del asistente
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  voiceData['name'] as String,
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: isSelected
                                            ? const Color(0xFF00BCD4)
                                            : Colors.black87,
                                      ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  voiceData['description'] as String,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(color: Colors.black54),
                                ),
                              ],
                            ),
                          ),

                          // Icono de selección
                          if (isSelected)
                            const Icon(
                              Icons.check_circle,
                              color: Color(0xFF00BCD4),
                              size: 32,
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          // Botón de confirmación
          Padding(
            padding: const EdgeInsets.all(24),
            child: ElevatedButton(
              onPressed: _selectedVoiceId != null && !_isTesting
                  ? _confirmSelection
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00BCD4),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                minimumSize: const Size(double.infinity, 56),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.check, size: 24),
                  const SizedBox(width: 8),
                  Text(
                    _selectedVoiceId != null
                        ? 'Confirmar y Continuar'
                        : 'Selecciona un asistente',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
