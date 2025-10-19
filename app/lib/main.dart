import 'package:flutter/material.dart';
import 'services/server_config.dart';
import 'screens/login_screen.dart';
import 'screens/login_screen_v2.dart'; // ✅ Login UI clásica Figma con badge IA
import 'screens/biometric_login_screen.dart';
import 'screens/register_screen.dart';
import 'screens/home_screen.dart';
import 'screens/map_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/contribute_screen.dart';
import 'screens/bus_status_report_screen.dart';
import 'screens/route_issue_report_screen.dart';
import 'screens/stop_info_report_screen.dart';
import 'screens/general_suggestion_screen.dart';
import 'screens/tts_settings_screen.dart'; // ✅ Configuración de voz TTS

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ServerConfig.instance.init();
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
    // ✅ Ir directo al login - selección de voz integrada dentro
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
          case '/login_v2': // Nueva ruta para login UI clásica
            return MaterialPageRoute(builder: (_) => const LoginScreenV2());
          case BiometricLoginScreen.routeName:
            return MaterialPageRoute(
              builder: (_) => const BiometricLoginScreen(),
            );
          case LoginScreen.routeName:
            return MaterialPageRoute(builder: (_) => const LoginScreen());
          case RegisterScreen.routeName:
            return MaterialPageRoute(builder: (_) => const RegisterScreen());
          case HomeScreen.routeName:
            return MaterialPageRoute(builder: (_) => const HomeScreen());
          case MapScreen.routeName:
            return MaterialPageRoute(builder: (_) => const MapScreen());
          case SettingsScreen.routeName:
            return MaterialPageRoute(builder: (_) => const SettingsScreen());
          case '/tts_settings': // Nueva ruta configuración TTS
            return MaterialPageRoute(builder: (_) => const TtsSettingsScreen());
          case ContributeScreen.routeName:
            return MaterialPageRoute(builder: (_) => const ContributeScreen());
          case BusStatusReportScreen.routeName:
            return MaterialPageRoute(
              builder: (_) => const BusStatusReportScreen(),
            );
          case RouteIssueReportScreen.routeName:
            return MaterialPageRoute(
              builder: (_) => const RouteIssueReportScreen(),
            );
          case StopInfoReportScreen.routeName:
            return MaterialPageRoute(
              builder: (_) => const StopInfoReportScreen(),
            );
          case GeneralSuggestionScreen.routeName:
            return MaterialPageRoute(
              builder: (_) => const GeneralSuggestionScreen(),
            );
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
