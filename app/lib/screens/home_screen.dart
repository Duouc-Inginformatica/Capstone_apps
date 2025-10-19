import 'package:flutter/material.dart';
import '../widgets/bottom_nav.dart';
import 'contribute_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  static const routeName = '/home';

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isListening = false;

  void _toggleMicrophone() {
    setState(() {
      _isListening = !_isListening;
    });

    // Aquí puedes agregar lógica de reconocimiento de voz
    if (_isListening) {
      // Iniciar reconocimiento de voz
      debugPrint('Iniciando reconocimiento de voz...');
    } else {
      // Detener reconocimiento de voz
      debugPrint('Deteniendo reconocimiento de voz...');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[300],
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const SizedBox(),
        title: const Text(
          'WayFindCL',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          // Área del mapa
          Positioned.fill(
            child: Container(
              color: Colors.grey[400],
              child: const Center(
                child: Icon(Icons.map_outlined, size: 120, color: Colors.grey),
              ),
            ),
          ),

          // Botón de brújula (izquierda)
          Positioned(
            left: 20,
            bottom: 300, // Movido más arriba desde 200 a 350
            child: Container(
              width: 50,
              height: 50,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 4,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(
                Icons.explore_outlined,
                color: Colors.black,
                size: 24,
              ),
            ),
          ),

          // Botón de configuración (derecha)
          Positioned(
            right: 20,
            bottom: 300, // Movido más arriba desde 200 a 350
            child: GestureDetector(
              onTap: () => Navigator.pushNamed(context, '/settings'),
              child: Container(
                width: 50,
                height: 50,
                decoration: const BoxDecoration(
                  color: Colors.black,
                  shape: BoxShape.rectangle,
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 4,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.settings,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ),
          ),

          // Botón de configuración de VOZ TTS (nuevo - arriba del de settings)
          Positioned(
            right: 20,
            bottom: 360, // Justo arriba del botón de settings
            child: GestureDetector(
              onTap: () => Navigator.pushNamed(context, '/tts_settings'),
              child: Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF00BCD4), Color(0xFF0097A7)],
                  ),
                  shape: BoxShape.rectangle,
                  borderRadius: const BorderRadius.all(Radius.circular(12)),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF00BCD4).withOpacity(0.4),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.record_voice_over,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ),
          ),

          // Panel inferior
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Handle del panel
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[400],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Texto "Pulsa para hablar"
                  const Text(
                    'Pulsa para hablar',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Botón del micrófono
                  GestureDetector(
                    onTap: _toggleMicrophone,
                    child: Container(
                      width: double.infinity,
                      height: 120,
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Icon(
                        _isListening ? Icons.mic : Icons.mic_off,
                        color: Colors.white,
                        size: 48,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Barra de navegación inferior
                  BottomNavBar(
                    currentIndex: 0,
                    onTap: (index) {
                      switch (index) {
                        case 0:
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Explorar')),
                          );
                          break;
                        case 1:
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Guardados (no implementado)'),
                            ),
                          );
                          break;
                        case 2:
                          Navigator.pushNamed(
                            context,
                            ContributeScreen.routeName,
                          );
                          break;
                        case 3:
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Negocios (no implementado)'),
                            ),
                          );
                          break;
                      }
                    },
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
