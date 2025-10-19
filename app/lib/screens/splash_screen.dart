import 'package:flutter/material.dart';
import 'dart:async';
import '../services/npu_detector_service.dart';
import '../services/tts_service.dart';
import 'login_screen_v2.dart'; // ✅ Nueva UI clásica de Figma

/// Pantalla de carga inicial con animación y badge IA
/// Muestra indicador "IA" si el dispositivo soporta aceleración neural
class SplashScreen extends StatefulWidget {
  const SplashScreen({Key? key}) : super(key: key);

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  late Animation<Offset> _slideAnimation;

  NpuCapabilities? _npuCapabilities;
  bool _isInitializing = true;
  String _statusMessage = 'Iniciando WayfindCL...';
  double _progress = 0.0;

  @override
  void initState() {
    super.initState();

    // Configurar animaciones
    _controller = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
      ),
    );

    _scaleAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.6, curve: Curves.elasticOut),
      ),
    );

    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _controller,
            curve: const Interval(0.3, 0.8, curve: Curves.easeOut),
          ),
        );

    _controller.forward();

    // Iniciar detección y configuración
    _initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Inicializa servicios y detecta capacidades del dispositivo
  Future<void> _initialize() async {
    try {
      // Paso 1: Detectar NPU (30%)
      setState(() {
        _statusMessage = 'Detectando capacidades de IA...';
        _progress = 0.1;
      });

      await Future.delayed(const Duration(milliseconds: 300));

      final npuCapabilities = await NpuDetectorService.instance
          .detectCapabilities();

      setState(() {
        _npuCapabilities = npuCapabilities;
        _progress = 0.3;
      });

      // Paso 2: Inicializar TTS (60%)
      setState(() {
        _statusMessage = npuCapabilities.hasNpuDelegate
            ? 'Cargando motor de voz neural...'
            : 'Iniciando sistema de voz...';
        _progress = 0.4;
      });

      await Future.delayed(const Duration(milliseconds: 500));

      // TODO: Inicializar NeuralTtsService si está disponible
      // Por ahora solo inicializar TTS normal
      await TtsService.instance.initialize();

      setState(() {
        _progress = 0.6;
      });

      // Paso 3: Cargar recursos (90%)
      setState(() {
        _statusMessage = 'Preparando interfaz...';
        _progress = 0.7;
      });

      await Future.delayed(const Duration(milliseconds: 400));

      setState(() {
        _progress = 0.9;
      });

      // Paso 4: Finalizar (100%)
      setState(() {
        _statusMessage = '¡Listo!';
        _progress = 1.0;
        _isInitializing = false;
      });

      await Future.delayed(const Duration(milliseconds: 600));

      // Navegar a login
      if (mounted) {
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) =>
                const LoginScreenV2(), // ✅ Nueva UI
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
                  return FadeTransition(opacity: animation, child: child);
                },
            transitionDuration: const Duration(milliseconds: 500),
          ),
        );
      }
    } catch (e) {
      print('❌ [SPLASH] Error en inicialización: $e');
      setState(() {
        _statusMessage = 'Error: $e';
        _isInitializing = false;
      });

      // Navegar de todas formas después de un delay
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => const LoginScreenV2(),
          ), // ✅ Nueva UI
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e), // Azul oscuro elegante
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Logo con animación
                  FadeTransition(
                    opacity: _fadeAnimation,
                    child: ScaleTransition(
                      scale: _scaleAnimation,
                      child: _buildLogo(),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Badge IA (solo si NPU disponible)
                  if (_npuCapabilities?.hasNpuDelegate == true)
                    SlideTransition(
                      position: _slideAnimation,
                      child: _buildAiBadge(),
                    ),

                  const SizedBox(height: 48),

                  // Indicador de progreso
                  FadeTransition(
                    opacity: _fadeAnimation,
                    child: _buildProgressIndicator(),
                  ),

                  const SizedBox(height: 16),

                  // Mensaje de estado
                  SlideTransition(
                    position: _slideAnimation,
                    child: _buildStatusMessage(),
                  ),

                  if (_npuCapabilities != null) ...[
                    const SizedBox(height: 24),
                    _buildCapabilitiesInfo(),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return Container(
      width: 120,
      height: 120,
      decoration: BoxDecoration(
        color: const Color(0xFF0f3460),
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF16213e).withOpacity(0.5),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: const Icon(
        Icons.navigation,
        size: 60,
        color: Color(0xFF00d9ff), // Cyan brillante
      ),
    );
  }

  Widget _buildAiBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF00d9ff), Color(0xFF00b4d8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00d9ff).withOpacity(0.4),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.psychology_outlined, color: Colors.white, size: 20),
          const SizedBox(width: 8),
          Text(
            'IA',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(width: 4),
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: Colors.greenAccent,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.greenAccent.withOpacity(0.6),
                  blurRadius: 8,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressIndicator() {
    return Column(
      children: [
        SizedBox(
          width: 250,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: _progress,
              backgroundColor: const Color(0xFF16213e),
              valueColor: AlwaysStoppedAnimation<Color>(
                _npuCapabilities?.hasNpuDelegate == true
                    ? const Color(0xFF00d9ff)
                    : const Color(0xFF00b4d8),
              ),
              minHeight: 6,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${(_progress * 100).toInt()}%',
          style: TextStyle(
            color: Colors.white.withOpacity(0.6),
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildStatusMessage() {
    return Text(
      _statusMessage,
      style: TextStyle(
        color: Colors.white.withOpacity(0.8),
        fontSize: 16,
        fontWeight: FontWeight.w400,
      ),
      textAlign: TextAlign.center,
    );
  }

  Widget _buildCapabilitiesInfo() {
    if (_npuCapabilities == null) return const SizedBox.shrink();

    final description = NpuDetectorService.instance.getCapabilitiesDescription(
      _npuCapabilities!,
    );

    return Opacity(
      opacity: _fadeAnimation.value,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF16213e).withOpacity(0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _npuCapabilities!.hasNpuDelegate
                      ? Icons.speed
                      : Icons.info_outline,
                  color: const Color(0xFF00d9ff),
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  description,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            if (_npuCapabilities!.chipset != null) ...[
              const SizedBox(height: 4),
              Text(
                _npuCapabilities!.chipset!,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.4),
                  fontSize: 10,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
