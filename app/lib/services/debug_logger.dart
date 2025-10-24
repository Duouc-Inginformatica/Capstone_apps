import 'package:flutter/foundation.dart';

/// Servicio de logging centralizado que respeta el flag de debug global
/// Usa debugPrint() que es controlable y aparece en la consola de flutter run
class DebugLogger {
  static bool _debugEnabled = true; // Por defecto activado en desarrollo
  
  /// Habilita o deshabilita todos los logs de la aplicación
  static void setDebugEnabled(bool enabled) {
    _debugEnabled = enabled;
    // Usar debugPrint() para que aparezca en la consola de flutter run
    debugPrint('═══════════════════════════════════════════════════════');
    debugPrint('🔧 [DEBUG-LOGGER] Logging ${enabled ? "✅ ACTIVADO" : "🔇 DESACTIVADO"}');
    debugPrint('═══════════════════════════════════════════════════════');
  }
  
  /// Verifica si el debug está habilitado
  static bool get isDebugEnabled => _debugEnabled;
  
  /// Log genérico con contexto
  static void log(String message, {String? name, Object? error, StackTrace? stackTrace}) {
    if (!_debugEnabled) return;
    
    final prefix = name != null ? '[$name] ' : '';
    debugPrint('$prefix$message');
    if (error != null) debugPrint('ERROR: $error');
    if (stackTrace != null) debugPrint('STACK: $stackTrace');
  }
  
  /// Log de información (azul)
  static void info(String message, {String? context}) {
    if (!_debugEnabled) return;
    
    final prefix = context != null ? '[$context] ' : '';
    debugPrint('ℹ️  $prefix$message');
  }
  
  /// Log de advertencia (amarillo)
  static void warning(String message, {String? context}) {
    if (!_debugEnabled) return;
    
    final prefix = context != null ? '[$context] ' : '';
    debugPrint('⚠️  $prefix$message');
  }
  
  /// Log de error (rojo)
  static void error(String message, {String? context, Object? error, StackTrace? stackTrace}) {
    if (!_debugEnabled) return;
    
    final prefix = context != null ? '[$context] ' : '';
    debugPrint('❌ $prefix$message');
    if (error != null) debugPrint('   ERROR: $error');
    if (stackTrace != null) debugPrint('   STACK: $stackTrace');
  }
  
  /// Log de éxito (verde con checkmark)
  static void success(String message, {String? context}) {
    if (!_debugEnabled) return;
    
    final prefix = context != null ? '[$context] ' : '';
    debugPrint('✅ $prefix$message');
  }
  
  /// Log de navegación
  static void navigation(String message) {
    if (!_debugEnabled) return;
    
    debugPrint('🧭 [Navigation] $message');
  }
  
  /// Log de API/Network
  static void network(String message, {Object? data}) {
    if (!_debugEnabled) return;
    
    debugPrint('🌐 [Network] $message');
    if (data != null) debugPrint('   Data: $data');
  }
  
  /// Log de base de datos
  static void database(String message) {
    if (!_debugEnabled) return;
    
    debugPrint('💾 [Database] $message');
  }
  
  /// Log de UI
  static void ui(String message) {
    if (!_debugEnabled) return;
    
    debugPrint('🎨 [UI] $message');
  }
  
  /// Log de servicios
  static void service(String message, String serviceName) {
    if (!_debugEnabled) return;
    
    debugPrint('⚙️  [$serviceName] $message');
  }
  
  /// Log de voz/TTS
  static void voice(String message) {
    if (!_debugEnabled) return;
    
    debugPrint('🎤 [Voice] $message');
  }
  
  /// Log de geolocalización
  static void location(String message) {
    if (!_debugEnabled) return;
    
    debugPrint('📍 [Location] $message');
  }
  
  /// Imprime separador visual en logs
  static void separator({String? title}) {
    if (!_debugEnabled) return;
    
    final line = '═' * 60;
    debugPrint('');
    debugPrint(line);
    if (title != null) {
      debugPrint('  $title');
      debugPrint(line);
    }
    debugPrint('');
  }
  
  /// Debug detallado de objetos
  static void debug(String message, {Object? object}) {
    if (!_debugEnabled) return;
    
    debugPrint('🔍 [Debug] $message');
    if (object != null) debugPrint('   Object: $object');
  }
}
