import 'package:flutter/material.dart';
import '../../services/navigation/integrated_navigation_service.dart';

/// Widget para visualizar rutas con metro y trasbordos
/// 
/// Muestra el flujo completo de la ruta:
/// 🚶 Usuario → 🚏 Paradero → 🚌 Bus → 🚶 Caminar → 🚇 Metro (L1→L2) → 🚌 Bus → 🎯 Destino
/// 
/// Características:
/// - Detección automática de segmentos de metro (type: 'metro', mode: 'Metro')
/// - Visualización de líneas de metro (L1-L6 con colores)
/// - Indicación de trasbordos entre líneas de metro
/// - Iconos accesibles para cada tipo de transporte
/// - Tiempo estimado por segmento
/// - TalkBack/VoiceOver compatible
class MetroRoutePanelWidget extends StatelessWidget {
  final List<NavigationStep> steps;
  final int currentStepIndex;
  final VoidCallback? onClose;
  final Function(int)? onStepTap;
  final double? height;

  const MetroRoutePanelWidget({
    super.key,
    required this.steps,
    required this.currentStepIndex,
    this.onClose,
    this.onStepTap,
    this.height,
  });

  /// Colores oficiales del Metro de Santiago
  static const Map<String, Color> metroLineColors = {
    'L1': Color(0xFFE3000B), // Rojo
    'L2': Color(0xFFFFC20E), // Amarillo
    'L3': Color(0xFF8B5E3C), // Café
    'L4': Color(0xFF0066CC), // Azul
    'L4A': Color(0xFF6495ED), // Azul claro
    'L5': Color(0xFF00A651), // Verde
    'L6': Color(0xFF8B008B), // Morado
  };

  @override
  Widget build(BuildContext context) {
    final bool hasMetro = _hasMetroSegment();
    
    return Container(
      height: height ?? 400,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        children: [
          // Barra superior con título y botón cerrar
          _buildHeader(context, hasMetro),
          
          const Divider(height: 1),
          
          // Lista de pasos con visualización mejorada para metro
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 12),
              itemCount: steps.length,
              itemBuilder: (context, index) {
                final step = steps[index];
                final isCurrentStep = index == currentStepIndex;
                final isCompleted = step.isCompleted;
                
                return _buildStepItem(
                  context,
                  step,
                  index,
                  isCurrentStep,
                  isCompleted,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Construye el header del panel
  Widget _buildHeader(BuildContext context, bool hasMetro) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          // Icono de metro si la ruta incluye metro
          if (hasMetro) ...[
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.purple.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.subway,
                color: Colors.purple,
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
          ],
          
          // Título
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasMetro ? 'Ruta con Metro' : 'Instrucciones de Ruta',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '${steps.length} pasos • ${_getTotalDuration()} min',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
          
          // Botón cerrar
          if (onClose != null)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: onClose,
              tooltip: 'Cerrar instrucciones',
            ),
        ],
      ),
    );
  }

  /// Construye cada paso de la ruta
  Widget _buildStepItem(
    BuildContext context,
    NavigationStep step,
    int index,
    bool isCurrentStep,
    bool isCompleted,
  ) {
    final stepType = step.type.toLowerCase();
    final isMetro = stepType == 'metro' || 
                    stepType == 'wait_metro' || 
                    stepType == 'ride_metro' ||
                    (step.busRoute?.startsWith('L') == true && step.busRoute!.length <= 3);
    
    return InkWell(
      onTap: onStepTap != null ? () => onStepTap!(index) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: isCurrentStep ? Colors.blue.shade50 : Colors.transparent,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Línea vertical de conexión + ícono
            Column(
              children: [
                // Línea superior (excepto primer paso)
                if (index > 0)
                  Container(
                    width: 2,
                    height: 12,
                    color: isCompleted ? Colors.green : Colors.grey.shade300,
                  ),
                
                // Ícono del paso
                _buildStepIcon(step, isCompleted, isCurrentStep, isMetro),
                
                // Línea inferior (excepto último paso)
                if (index < steps.length - 1)
                  Container(
                    width: 2,
                    height: 12,
                    color: isCompleted ? Colors.green : Colors.grey.shade300,
                  ),
              ],
            ),
            
            const SizedBox(width: 16),
            
            // Contenido del paso
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Título del paso con badge de línea de metro
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _getStepTitle(step),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: isCurrentStep ? FontWeight.bold : FontWeight.normal,
                            color: isCompleted ? Colors.grey.shade600 : Colors.black,
                          ),
                        ),
                      ),
                      
                      // Badge de línea de metro
                      if (isMetro && step.busRoute != null)
                        _buildMetroLineBadge(step.busRoute!),
                    ],
                  ),
                  
                  const SizedBox(height: 4),
                  
                  // Instrucción detallada
                  Text(
                    step.instruction,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  
                  const SizedBox(height: 8),
                  
                  // Información adicional (duración, distancia, paradas)
                  _buildStepMetadata(step),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Construye el ícono para cada tipo de paso
  Widget _buildStepIcon(NavigationStep step, bool isCompleted, bool isCurrentStep, bool isMetro) {
    IconData icon;
    Color color;
    
    if (isCompleted) {
      icon = Icons.check_circle;
      color = Colors.green;
    } else if (isCurrentStep) {
      icon = _getIconForStepType(step.type, isMetro);
      color = Colors.blue;
    } else {
      icon = _getIconForStepType(step.type, isMetro);
      color = Colors.grey.shade400;
    }
    
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 2),
      ),
      child: Icon(icon, color: color, size: 20),
    );
  }

  /// Retorna el ícono apropiado según el tipo de paso
  IconData _getIconForStepType(String type, bool isMetro) {
    switch (type.toLowerCase()) {
      case 'walk':
        return Icons.directions_walk;
      case 'wait_bus':
        return Icons.schedule; // Reloj para esperar bus
      case 'ride_bus':
        return Icons.directions_bus; // Bus en movimiento
      case 'wait_metro':
        return Icons.schedule; // Reloj para esperar metro
      case 'ride_metro':
        return Icons.subway; // Metro en movimiento
      case 'bus':
        return isMetro ? Icons.subway : Icons.directions_bus;
      case 'metro':
        return Icons.subway;
      case 'transfer':
        return Icons.transfer_within_a_station;
      case 'arrival':
        return Icons.place;
      default:
        return Icons.navigation;
    }
  }

  /// Construye el badge de línea de metro (L1, L2, etc.)
  Widget _buildMetroLineBadge(String lineCode) {
    final color = metroLineColors[lineCode] ?? Colors.purple;
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        lineCode,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// Construye la metadata del paso (duración, paradas, etc.)
  Widget _buildStepMetadata(NavigationStep step) {
    final List<Widget> metadata = [];
    
    // Duración
    if (step.estimatedDuration > 0) {
      metadata.add(
        Row(
          children: [
            Icon(Icons.schedule, size: 14, color: Colors.grey.shade600),
            const SizedBox(width: 4),
            Text(
              '${step.estimatedDuration} min',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      );
    }
    
    // Distancia real (para caminar)
    if (step.realDistanceMeters != null && step.type.toLowerCase() == 'walk') {
      metadata.add(
        Row(
          children: [
            Icon(Icons.straighten, size: 14, color: Colors.grey.shade600),
            const SizedBox(width: 4),
            Text(
              '${(step.realDistanceMeters! / 1000).toStringAsFixed(2)} km',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      );
    }
    
    // Número de paradas (para bus/metro)
    if (step.totalStops != null && step.totalStops! > 0) {
      metadata.add(
        Row(
          children: [
            Icon(Icons.location_on, size: 14, color: Colors.grey.shade600),
            const SizedBox(width: 4),
            Text(
              '${step.totalStops} paradas',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      );
    }
    
    if (metadata.isEmpty) {
      return const SizedBox.shrink();
    }
    
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: metadata,
    );
  }

  /// Obtiene el título del paso
  String _getStepTitle(NavigationStep step) {
    switch (step.type.toLowerCase()) {
      case 'walk':
        return 'Caminar';
      case 'wait_bus':
        return 'Esperar Bus ${step.busRoute ?? ""}';
      case 'ride_bus':
        return 'Viajar en Bus ${step.busRoute ?? ""}';
      case 'wait_metro':
        return 'Esperar Metro ${step.busRoute ?? ""}';
      case 'ride_metro':
        return 'Viajar en Metro ${step.busRoute ?? ""}';
      case 'bus':
        final isMetro = step.busRoute?.startsWith('L') == true && step.busRoute!.length <= 3;
        if (isMetro) {
          return 'Tomar Metro ${step.busRoute}';
        }
        return 'Tomar Bus ${step.busRoute ?? ""}';
      case 'metro':
        return 'Tomar Metro ${step.busRoute ?? ""}';
      case 'transfer':
        return 'Trasbordar';
      case 'arrival':
        return 'Has llegado';
      default:
        return step.type;
    }
  }

  /// Calcula la duración total de la ruta
  int _getTotalDuration() {
    return steps.fold(0, (sum, step) => sum + step.estimatedDuration);
  }

  /// Verifica si la ruta incluye segmentos de metro
  bool _hasMetroSegment() {
    return steps.any((step) {
      final isMetroType = step.type.toLowerCase() == 'metro' || 
                         step.type.toLowerCase() == 'wait_metro' || 
                         step.type.toLowerCase() == 'ride_metro';
      final isMetroRoute = step.busRoute?.startsWith('L') == true && step.busRoute!.length <= 3;
      return isMetroType || isMetroRoute;
    });
  }
}

/// Widget compacto para resumen de ruta con metro
/// Muestra solo los modos de transporte principales (útil para vista rápida)
class MetroRouteSummaryWidget extends StatelessWidget {
  final List<NavigationStep> steps;
  final int totalDuration;

  const MetroRouteSummaryWidget({
    super.key,
    required this.steps,
    required this.totalDuration,
  });

  @override
  Widget build(BuildContext context) {
    final modes = _getUniqueModes();
    
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Iconos de modos de transporte
          Expanded(
            child: Row(
              children: modes.asMap().entries.map((entry) {
                final index = entry.key;
                final mode = entry.value;
                
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (index > 0)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(
                          Icons.arrow_forward,
                          size: 16,
                          color: Colors.grey.shade400,
                        ),
                      ),
                    _buildModeIcon(mode),
                  ],
                );
              }).toList(),
            ),
          ),
          
          // Duración total
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.schedule, size: 16, color: Colors.blue),
                const SizedBox(width: 4),
                Text(
                  '$totalDuration min',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Obtiene los modos únicos de transporte en orden
  List<String> _getUniqueModes() {
    final List<String> modes = [];
    
    for (final step in steps) {
      final type = step.type.toLowerCase();
      final isMetro = type == 'metro' || 
                      type == 'wait_metro' || 
                      type == 'ride_metro' ||
                      (step.busRoute?.startsWith('L') == true && step.busRoute!.length <= 3);
      
      String mode;
      if (type == 'walk') {
        mode = 'walk';
      } else if (isMetro) {
        mode = 'metro:${step.busRoute ?? ""}';
      } else if (type == 'bus' || type == 'wait_bus' || type == 'ride_bus') {
        mode = 'bus';
      } else {
        continue;
      }
      
      // Evitar duplicados consecutivos (excepto metro con diferentes líneas)
      if (modes.isEmpty || modes.last != mode) {
        modes.add(mode);
      }
    }
    
    return modes;
  }

  /// Construye el ícono para cada modo
  Widget _buildModeIcon(String mode) {
    IconData icon;
    Color color;
    String? metroLine;
    
    if (mode == 'walk') {
      icon = Icons.directions_walk;
      color = Colors.green;
    } else if (mode.startsWith('metro:')) {
      icon = Icons.subway;
      metroLine = mode.split(':')[1];
      color = MetroRoutePanelWidget.metroLineColors[metroLine] ?? Colors.purple;
    } else if (mode == 'bus') {
      icon = Icons.directions_bus;
      color = Colors.orange;
    } else {
      icon = Icons.navigation;
      color = Colors.grey;
    }
    
    return Stack(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 20, color: color),
        ),
        
        // Badge de línea de metro
        if (metroLine != null && metroLine.isNotEmpty)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white, width: 1),
              ),
              child: Text(
                metroLine,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 8,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
