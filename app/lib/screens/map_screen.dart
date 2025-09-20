import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:permission_handler/permission_handler.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  static const routeName = '/map';

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  bool _isListening = false;
  String _lastWords = '';
  final SpeechToText _speech = SpeechToText();
  bool _speechEnabled = false;

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  void _initSpeech() async {
    _speechEnabled = await _speech.initialize(
      onError: (errorNotification) {
        setState(() {
          _isListening = false;
        });
      },
      onStatus: (status) {
        if (status == 'notListening') {
          setState(() {
            _isListening = false;
          });
        }
      },
    );
    setState(() {});
  }

  void _startListening() async {
    // Verificar permisos de micrófono
    var status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      _showPermissionDialog();
      return;
    }

    await _speech.listen(
      onResult: (result) {
        setState(() {
          _lastWords = result.recognizedWords;
        });
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
      partialResults: true,
      localeId: 'es_ES', // Español
      cancelOnError: true,
      listenMode: ListenMode.confirmation,
    );
    setState(() {
      _isListening = true;
    });
  }

  void _stopListening() async {
    await _speech.stop();
    setState(() {
      _isListening = false;
    });
    
    // Procesar el comando de voz
    if (_lastWords.isNotEmpty) {
      _processVoiceCommand(_lastWords);
    }
  }

  void _processVoiceCommand(String command) {
    // Aquí puedes agregar lógica para procesar comandos de voz
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Comando de Voz'),
        content: Text('Escuché: "$command"'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    
    // Limpiar el texto después de procesar
    setState(() {
      _lastWords = '';
    });
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permiso Requerido'),
        content: const Text('Esta aplicación necesita acceso al micrófono para el reconocimiento de voz.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
            child: const Text('Configuración'),
          ),
        ],
      ),
    );
  }

  void _toggleMicrophone() {
    if (!_speechEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Reconocimiento de voz no disponible'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (_isListening) {
      _stopListening();
    } else {
      _startListening();
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
                child: Icon(
                  Icons.map_outlined,
                  size: 120,
                  color: Colors.grey,
                ),
              ),
            ),
          ),
          
          // Botón de brújula (izquierda)
          Positioned(
            left: 20,
            bottom: 280,
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
            bottom: 280,
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
                  
                  // Texto dinámico según estado
                  Text(
                    _isListening 
                        ? 'Escuchando...' 
                        : _lastWords.isNotEmpty 
                            ? 'Último: $_lastWords'
                            : 'Pulsa para hablar',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: _isListening ? Colors.blue : Colors.black,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 16),
                  
                  // Botón del micrófono
                  GestureDetector(
                    onTap: _toggleMicrophone,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: double.infinity,
                      height: 120,
                      decoration: BoxDecoration(
                        color: _isListening ? Colors.red : Colors.black,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: _isListening ? [
                          BoxShadow(
                            color: Colors.red.withOpacity(0.3),
                            blurRadius: 20,
                            spreadRadius: 5,
                          ),
                        ] : null,
                      ),
                      child: Icon(
                        _isListening ? Icons.mic : Icons.mic_off,
                        color: Colors.white,
                        size: 48,
                      ),
                    ),
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