import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'services/backend/server_config.dart';
import 'services/backend/dio_api_client.dart';
import 'services/debug_logger.dart';
import 'screens/login_screen_v2.dart';
import 'screens/biometric_login_screen.dart';
import 'screens/map_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/debug_setup_screen.dart';
import 'blocs/location/location_bloc.dart';
import 'blocs/navigation/navigation_bloc.dart';
import 'blocs/map/map_bloc.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ============================================================================
  // INICIALIZAR HIVE (requerido para cache de Dio)
  // ============================================================================
  await Hive.initFlutter();

  // 🔧 Inicializar logger con el flag de debug global
  DebugLogger.setDebugEnabled(debug);
  DebugLogger.separator(title: 'WAYFINDCL APP INICIANDO');
  DebugLogger.info(
    'Modo debug: ${kDebugMode ? "ACTIVADO" : "DESACTIVADO"}',
    context: 'Main',
  );
  DebugLogger.info('Flag debug global: $debug', context: 'Main');

  // ============================================================================
  // INICIALIZAR BACKEND SERVICES
  // ============================================================================
  await ServerConfig.instance.init();
  DebugLogger.success('ServerConfig inicializado', context: 'Main');

  // ✅ Inicializar Dio HTTP Client con connection pooling
  await DioApiClient.init(
    baseUrl: ServerConfig.instance.baseUrl,
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 30),
  );
  DebugLogger.success(
    'DioApiClient inicializado con connection pooling',
    context: 'Main',
  );

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

    // =========================================================================
    // BLOC PROVIDERS - Proveer BLoCs globales a toda la app
    // =========================================================================
    return MultiBlocProvider(
      providers: [
        // LocationBloc: Gestión de ubicación GPS
        BlocProvider<LocationBloc>(
          create: (context) => LocationBloc(),
          lazy: false, // Inicializar inmediatamente
        ),

        // NavigationBloc: Gestión de navegación turn-by-turn
        BlocProvider<NavigationBloc>(
          create: (context) => NavigationBloc(),
          lazy: true, // Lazy: solo se crea cuando se usa navegación
        ),

        // MapBloc: Gestión del estado del mapa (markers, polylines, zoom)
        BlocProvider<MapBloc>(
          create: (context) => MapBloc(),
          lazy: false, // Inicializar inmediatamente (mapa es UI principal)
        ),
      ],
      child: MaterialApp(
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
              return MaterialPageRoute(
                builder: (_) => const DebugSetupScreen(),
              );
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
      ),
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
