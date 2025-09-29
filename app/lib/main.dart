import 'package:flutter/material.dart';
import 'services/auth_storage.dart';
import 'services/server_config.dart';
import 'screens/login_screen.dart';
import 'screens/register_screen.dart';
import 'screens/home_screen.dart';
import 'screens/map_screen.dart';
import 'screens/settings_screen.dart';

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
    final token = await AuthStorage.readToken();
    if (!mounted) return;
    setState(() {
      _initialRoute = token != null
          ? MapScreen.routeName
          : LoginScreen.routeName;
    });
  }

  Widget _getHomeWidget() {
    if (_initialRoute == MapScreen.routeName) {
      return const MapScreen();
    } else {
      return const LoginScreen();
    }
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
          default:
            return MaterialPageRoute(builder: (_) => const LoginScreen());
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
