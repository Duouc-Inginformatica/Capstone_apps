// ============================================================================
// ITINERARY DETAILS WIDGET
// ============================================================================
// Muestra el itinerario paso a paso similar a Moovit
// Compatible con lectores de pantalla y TTS
// ============================================================================

import 'package:flutter/material.dart';
import '../services/combined_routes_service.dart';

class ItineraryDetails extends StatelessWidget {
  final CombinedRoute route;
  final VoidCallback? onClose;
  final Function(int)? onStepTap;

  const ItineraryDetails({
    super.key,
    required this.route,
    this.onClose,
    this.onStepTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          _buildHeader(context),

          // Resumen de la ruta
          _buildRouteSummary(context),

          const Divider(height: 1),

          // Lista de pasos
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: route.segments.length,
              itemBuilder: (context, index) {
                return _buildStepItem(context, route.segments[index], index);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ITINERARIO',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.grey,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${route.totalDuration.inMinutes} min',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          if (onClose != null)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: onClose,
              tooltip: 'Cerrar itinerario',
            ),
        ],
      ),
    );
  }

  Widget _buildRouteSummary(BuildContext context) {
    final busRoutes = route.segments
        .where((s) => s.mode == TransportMode.bus && s.routeName != null)
        .map((s) => s.routeName!)
        .toSet()
        .toList();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Colors.blue.shade50,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Iconos de modos de transporte
                Row(
                  children: [
                    for (var mode in _getUniqueModes())
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _getModeIcon(mode),
                      ),
                  ],
                ),
                const SizedBox(height: 8),

                // Buses Red utilizados
                if (busRoutes.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: busRoutes.map((routeName) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE30613), // Color rojo RED
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.directions_bus,
                              color: Colors.white,
                              size: 16,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              routeName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),

                const SizedBox(height: 8),

                // Información adicional
                Row(
                  children: [
                    Icon(Icons.schedule, size: 16, color: Colors.grey[600]),
                    const SizedBox(width: 4),
                    Text(
                      '${route.totalDuration.inMinutes} min',
                      style: TextStyle(color: Colors.grey[700], fontSize: 13),
                    ),
                    const SizedBox(width: 16),
                    Icon(Icons.straighten, size: 16, color: Colors.grey[600]),
                    const SizedBox(width: 4),
                    Text(
                      route.totalDistanceText,
                      style: TextStyle(color: Colors.grey[700], fontSize: 13),
                    ),
                    if (route.transferCount > 0) ...[
                      const SizedBox(width: 16),
                      Icon(Icons.sync_alt, size: 16, color: Colors.grey[600]),
                      const SizedBox(width: 4),
                      Text(
                        '${route.transferCount} ${route.transferCount == 1 ? 'transbordo' : 'transbordos'}',
                        style: TextStyle(color: Colors.grey[700], fontSize: 13),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepItem(BuildContext context, RouteSegment segment, int index) {
    final isFirst = index == 0;
    final isLast = index == route.segments.length - 1;

    return InkWell(
      onTap: () => onStepTap?.call(index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Línea vertical y círculo
            SizedBox(
              width: 40,
              child: Column(
                children: [
                  if (!isFirst)
                    Container(
                      width: 2,
                      height: 12,
                      color: _getSegmentColor(route.segments[index - 1]),
                    ),

                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: _getSegmentColor(segment),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: _getSegmentIconSmall(segment),
                  ),

                  if (!isLast)
                    Container(
                      width: 2,
                      height: 40,
                      color: _getSegmentColor(segment),
                    ),
                ],
              ),
            ),

            const SizedBox(width: 12),

            // Detalles del paso
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildStepHeader(segment),
                  const SizedBox(height: 4),
                  _buildStepDetails(segment),
                  if (segment.instructions != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      segment.instructions!,
                      style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                    ),
                  ],
                ],
              ),
            ),

            // Duración
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${segment.durationSeconds ~/ 60} min',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (segment.distanceMeters > 0)
                  Text(
                    segment.distanceMeters < 1000
                        ? '${segment.distanceMeters.round()} m'
                        : '${(segment.distanceMeters / 1000).toStringAsFixed(1)} km',
                    style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepHeader(RouteSegment segment) {
    String title = '';

    switch (segment.mode) {
      case TransportMode.walk:
        title = 'Caminar';
        break;
      case TransportMode.bus:
        title = 'Bus Red ${segment.routeName ?? ''}';
        break;
      case TransportMode.metro:
        title = segment.routeName ?? 'Metro';
        break;
      case TransportMode.train:
        title = 'Tren';
        break;
    }

    return Text(
      title,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    );
  }

  Widget _buildStepDetails(RouteSegment segment) {
    final parts = <String>[];

    if (segment.mode == TransportMode.walk) {
      if (segment.stopName != null) {
        parts.add('hacia ${segment.stopName}');
      }
    } else {
      // Solo mostrar paradas si están disponibles (no null)
      if (segment.stopName != null && segment.stopName!.isNotEmpty) {
        parts.add('Subir en: ${segment.stopName}');
      }
      if (segment.nextStopName != null && segment.nextStopName!.isNotEmpty) {
        parts.add('Bajar en: ${segment.nextStopName}');
      }

      // Si no hay paradas específicas, mostrar mensaje genérico
      if (segment.stopName == null && segment.nextStopName == null) {
        parts.add('Ruta aproximada (paradas no disponibles)');
      }
    }

    if (parts.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: parts.map((part) {
        return Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            part,
            style: TextStyle(
              fontSize: 13,
              color: part.contains('no disponibles')
                  ? Colors.orange[700]
                  : Colors.grey[700],
              fontStyle: part.contains('no disponibles')
                  ? FontStyle.italic
                  : FontStyle.normal,
            ),
          ),
        );
      }).toList(),
    );
  }

  List<TransportMode> _getUniqueModes() {
    final modes = <TransportMode>{};
    for (var segment in route.segments) {
      modes.add(segment.mode);
    }
    return modes.toList();
  }

  Widget _getModeIcon(TransportMode mode) {
    IconData icon;
    Color color;

    switch (mode) {
      case TransportMode.walk:
        icon = Icons.directions_walk;
        color = Colors.grey;
        break;
      case TransportMode.bus:
        icon = Icons.directions_bus;
        color = const Color(0xFFE30613);
        break;
      case TransportMode.metro:
        icon = Icons.subway;
        color = Colors.orange;
        break;
      case TransportMode.train:
        icon = Icons.train;
        color = Colors.green;
        break;
    }

    return Icon(icon, color: color, size: 24);
  }

  Widget _getSegmentIconSmall(RouteSegment segment) {
    IconData icon;

    switch (segment.mode) {
      case TransportMode.walk:
        icon = Icons.directions_walk;
        break;
      case TransportMode.bus:
        icon = Icons.directions_bus;
        break;
      case TransportMode.metro:
        icon = Icons.subway;
        break;
      case TransportMode.train:
        icon = Icons.train;
        break;
    }

    return Icon(icon, color: Colors.white, size: 14);
  }

  Color _getSegmentColor(RouteSegment segment) {
    switch (segment.mode) {
      case TransportMode.walk:
        return Colors.grey.shade600;
      case TransportMode.bus:
        return const Color(0xFFE30613); // Rojo RED
      case TransportMode.metro:
        return Colors.orange;
      case TransportMode.train:
        return Colors.green;
    }
  }
}
