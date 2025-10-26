// ============================================================================
// NAVIGATION STATE PANELS - WayFindCL
// ============================================================================
// Widgets modernos para diferentes estados de navegación:
// - Esperando en paradero (wait_bus)
// - Viajando en bus (ride_bus)
// - Caminando (walk)
// ============================================================================

import 'package:flutter/material.dart';
import '../services/navigation/integrated_navigation_service.dart'; // NavigationStep
import '../services/backend/bus_arrivals_service.dart'; // BusArrival, StopArrivals
import 'dart:async';

/// Widget para cuando el usuario está ESPERANDO en el paradero
class WaitingAtStopPanel extends StatefulWidget {
  final NavigationStep step;
  final StopArrivals? busArrivals;
  final String busRoute;
  final VoidCallback? onBoardBus;
  
  const WaitingAtStopPanel({
    super.key,
    required this.step,
    required this.busRoute,
    this.busArrivals,
    this.onBoardBus,
  });

  @override
  State<WaitingAtStopPanel> createState() => _WaitingAtStopPanelState();
}

class _WaitingAtStopPanelState extends State<WaitingAtStopPanel> 
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  Timer? _updateTimer;
  
  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);
    
    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    
    // Actualizar cada 30 segundos para mantener info fresca
    _updateTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }
  
  @override
  void dispose() {
    _pulseController.dispose();
    _updateTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stopName = widget.step.stopName ?? 'Paradero';
    final busArrivals = widget.busArrivals;
    
    // Buscar el bus específico que esperamos
    BusArrival? targetBus;
    if (busArrivals != null && busArrivals.arrivals.isNotEmpty) {
      try {
        targetBus = busArrivals.arrivals.firstWhere(
          (arrival) => arrival.routeNumber == widget.busRoute,
        );
      } catch (_) {
        targetBus = busArrivals.arrivals.first;
      }
    }
    
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF1E40AF), // Azul oscuro
            const Color(0xFF3B82F6), // Azul medio
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header con icono pulsante
          Container(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _pulseAnimation.value,
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.access_time_rounded,
                          color: Colors.white,
                          size: 32,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'ESPERANDO BUS',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        stopName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          // Información del bus esperado
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: targetBus != null
                ? _buildBusArrivalInfo(targetBus)
                : _buildNoBusInfo(),
          ),
          
          // Otros buses disponibles
          if (busArrivals != null && busArrivals.arrivals.length > 1)
            _buildOtherBuses(busArrivals),
          
          // Botón de confirmación
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: widget.onBoardBus,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE30613), // Rojo RED
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.check_circle, size: 24),
                    SizedBox(width: 12),
                    Text(
                      'CONFIRMAR QUE SUBÍ AL BUS',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildBusArrivalInfo(BusArrival bus) {
    final minutes = bus.estimatedMinutes;
    final isArriving = minutes <= 2;
    
    return Column(
      children: [
        // Número de bus con badge grande
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFE30613),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.directions_bus, color: Colors.white, size: 28),
              const SizedBox(width: 12),
              Text(
                widget.busRoute,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        
        const SizedBox(height: 20),
        
        // Tiempo de llegada
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isArriving ? Icons.circle : Icons.schedule,
              color: isArriving ? const Color(0xFFEF4444) : const Color(0xFF3B82F6),
              size: 32,
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isArriving ? '¡LLEGANDO!' : '$minutes min',
                  style: TextStyle(
                    color: isArriving ? const Color(0xFFEF4444) : const Color(0xFF1E293B),
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  isArriving ? 'El bus está por llegar' : 'Tiempo estimado',
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
  
  Widget _buildNoBusInfo() {
    return Column(
      children: [
        const Icon(
          Icons.bus_alert,
          color: Color(0xFF94A3B8),
          size: 48,
        ),
        const SizedBox(height: 16),
        Text(
          'Bus ${widget.busRoute}',
          style: const TextStyle(
            color: Color(0xFF1E293B),
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Buscando información de llegada...',
          style: TextStyle(
            color: Color(0xFF64748B),
            fontSize: 14,
          ),
        ),
      ],
    );
  }
  
  Widget _buildOtherBuses(StopArrivals arrivals) {
    final otherBuses = arrivals.arrivals
        .where((b) => b.routeNumber != widget.busRoute)
        .take(3)
        .toList();
    
    if (otherBuses.isEmpty) return const SizedBox.shrink();
    
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'OTROS BUSES EN ESTE PARADERO',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 12),
          ...otherBuses.map((bus) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    bus.routeNumber,
                    style: const TextStyle(
                      color: Color(0xFF1E293B),
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${bus.estimatedMinutes} min',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }
}

/// Widget para cuando el usuario está VIAJANDO EN EL BUS
class RidingBusPanel extends StatelessWidget {
  final NavigationStep step;
  final List<Map<String, dynamic>>? allStops;
  final int? currentStopIndex;
  final String busRoute;
  
  const RidingBusPanel({
    super.key,
    required this.step,
    required this.busRoute,
    this.allStops,
    this.currentStopIndex,
  });

  @override
  Widget build(BuildContext context) {
    final stopsRemaining = allStops != null && currentStopIndex != null
        ? (allStops!.length - currentStopIndex! - 1)
        : 0;
    final nextStopMap = currentStopIndex != null && 
                      allStops != null && 
                      currentStopIndex! + 1 < allStops!.length
        ? allStops![currentStopIndex! + 1]
        : null;
    final nextStopName = nextStopMap?['stop_name'] ?? nextStopMap?['name'] ?? '';
    final nextStopCode = nextStopMap?['stop_code'] ?? '';
    
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFFDC2626), // Rojo oscuro RED
            const Color(0xFFE30613), // Rojo RED corporativo
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header con icono de bus en movimiento
          Container(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.directions_bus_filled,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'VIAJANDO EN BUS',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              busRoute,
                              style: const TextStyle(
                                color: Color(0xFFE30613),
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          // Información de paradas
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                // Próxima parada DESTACADA
                if (nextStopMap != null) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF3C7),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFFF59E0B),
                        width: 2,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: const BoxDecoration(
                            color: Color(0xFFF59E0B),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.location_on,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'PRÓXIMA PARADA',
                                style: TextStyle(
                                  color: Color(0xFFF59E0B),
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                nextStopName,
                                style: const TextStyle(
                                  color: Color(0xFF0F172A),
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (nextStopCode.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  'Código: $nextStopCode',
                                  style: const TextStyle(
                                    color: Color(0xFF64748B),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                
                // Estadísticas del viaje
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildTripStat(
                      Icons.flag,
                      step.stopName ?? 'Destino',
                      'Bajar en',
                    ),
                    Container(
                      width: 1,
                      height: 40,
                      color: const Color(0xFFE2E8F0),
                    ),
                    _buildTripStat(
                      Icons.alt_route,
                      '$stopsRemaining',
                      stopsRemaining == 1 ? 'Parada restante' : 'Paradas restantes',
                    ),
                  ],
                ),
              ],
            ),
          ),
          
          // Tip de accesibilidad
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.white70, size: 20),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Te avisaremos cuando estés cerca de tu parada',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
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
  
  Widget _buildTripStat(IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, color: const Color(0xFF3B82F6), size: 24),
        const SizedBox(height: 8),
        Text(
          value,
          style: const TextStyle(
            color: Color(0xFF0F172A),
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF64748B),
            fontSize: 12,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
