import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'services/backend/server_config.dart';
import 'services/debug_logger.dart';
import 'screens/login_screen_v2.dart'; // ✅ Login UI clásica Figma con badge IA
import 'screens/biometric_login_screen.dart';
import 'screens/map_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/debug_setup_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 🔧 Inicializar logger con el flag de debug global
  DebugLogger.setDebugEnabled(debug);
  DebugLogger.separator(title: 'WAYFINDCL APP INICIANDO');
  DebugLogger.info('Modo debug: ${kDebugMode ? "ACTIVADO" : "DESACTIVADO"}', context: 'Main');
  DebugLogger.info('Flag debug global: $debug', context: 'Main');
  
  await ServerConfig.instance.init();
  DebugLogger.success('ServerConfig inicializado', context: 'Main');
  
  runApp(const WayFindCLApp());
}

class WayFindCLApp extends StatefulWidget {
  const WayFindCLApp({super.key});

  @override
  State<WayFindCLApp> createState() => _WayFindCLAppState();
}

class _WayFindCLAppState extends State<WayFindCLApp> {
  String? _initialRoute;

  @override
  void initState() {
    super.initState();
    _resolveInitialRoute();
  }

  Future<void> _resolveInitialRoute() async {
    // Empezar con Splash Screen que muestra badge IA si hay NPU
    if (!mounted) return;
    setState(() {
      _initialRoute = '/'; // Ruta inicial
    });
  }

  Widget _getHomeWidget() {
    if (kDebugMode) {
      return const DebugSetupScreen();
    }
    return const LoginScreenV2();
  }

  @override
  Widget build(BuildContext context) {
    final baseTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.black),
      useMaterial3: true,
      fontFamily: 'Roboto',
      scaffoldBackgroundColor: const Color(0xFFF5F6FF),
    );

    if (_initialRoute == null) {
      return MaterialApp(
        title: 'WayFindCL',
        debugShowCheckedModeBanner: false,
        theme: baseTheme,
        home: const _SplashScreen(),
      );
    }

    return MaterialApp(
      title: 'WayFindCL',
      debugShowCheckedModeBanner: false, // Quita el banner "DEBUG"
      theme: baseTheme.copyWith(
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.black,
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFD9D9D9),
          labelStyle: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w600,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: _getHomeWidget(),
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case LoginScreenV2.routeName:
          case '/login_v2': // Compatibilidad con rutas anteriores
            return MaterialPageRoute(builder: (_) => const LoginScreenV2());
          case DebugSetupScreen.routeName:
            return MaterialPageRoute(builder: (_) => const DebugSetupScreen());
          case BiometricLoginScreen.routeName:
            return MaterialPageRoute(
              builder: (_) => const BiometricLoginScreen(),
            );
          // Eliminado RegisterScreen - usar BiometricRegisterScreen directamente desde login
          case MapScreen.routeName:
            return MaterialPageRoute(builder: (_) => const MapScreen());
          case SettingsScreen.routeName:
            return MaterialPageRoute(builder: (_) => const SettingsScreen());
          // Eliminados: ContributeScreen, BusStatusReportScreen, RouteIssueReportScreen, StopInfoReportScreen
          default:
            return MaterialPageRoute(
              builder: (_) =>
                  const LoginScreenV2(), // ✅ Usar nueva UI por defecto
            );
        }
      },
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
