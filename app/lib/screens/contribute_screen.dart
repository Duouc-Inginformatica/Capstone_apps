import 'package:flutter/material.dart';
import '../widgets/bottom_nav.dart';

class ContributeScreen extends StatefulWidget {
  const ContributeScreen({super.key});
  static const routeName = '/contribute';

  @override
  State<ContributeScreen> createState() => _ContributeScreenState();
}

class _ContributeScreenState extends State<ContributeScreen> {
  void _handleContribution(String type) {
    switch (type) {
      case 'bus_status':
        Navigator.pushNamed(context, '/contribute/bus-status');
        break;
      case 'route_issues':
        Navigator.pushNamed(context, '/contribute/route-issue');
        break;
      case 'stop_info':
        Navigator.pushNamed(context, '/contribute/stop-info');
        break;
      case 'general':
        Navigator.pushNamed(context, '/contribute/general');
        break;
    }
  }

  Widget _buildContributionCard({
    required IconData icon,
    required String title,
    required String description,
    required String type,
  }) {
    return GestureDetector(
      onTap: () => _handleContribution(type),
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Icon(
                icon,
                color: Colors.white,
                size: 28,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.arrow_forward_ios,
              color: Colors.grey[400],
              size: 16,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[300],
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Contribuir',
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
          // Área principal
          Positioned.fill(
            child: Container(
              color: Colors.grey[300],
              padding: const EdgeInsets.only(top: 20, left: 20, right: 20, bottom: 140),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Título principal
                    const Text(
                      '¿Qué quieres reportar?',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Tu contribución ayuda a mejorar el transporte para todos',
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.grey[700],
                      ),
                    ),
                    const SizedBox(height: 30),

                    // Tarjetas de contribución
                    _buildContributionCard(
                      icon: Icons.directions_bus,
                      title: 'Estado del Bus',
                      description: 'Reportar retrasos, sobrecarga o problemas técnicos',
                      type: 'bus_status',
                    ),
                    _buildContributionCard(
                      icon: Icons.warning_amber,
                      title: 'Problemas de Ruta',
                      description: 'Desvíos, suspensiones o cambios de recorrido',
                      type: 'route_issues',
                    ),
                    _buildContributionCard(
                      icon: Icons.location_on,
                      title: 'Info de Paradas',
                      description: 'Nuevas paradas, errores o problemas de accesibilidad',
                      type: 'stop_info',
                    ),
                    _buildContributionCard(
                      icon: Icons.lightbulb,
                      title: 'Sugerencia General',
                      description: 'Ideas para mejorar la aplicación',
                      type: 'general',
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Panel inferior con botón de voz
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

                  // Texto
                  const Text(
                    'O usa comando de voz',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Ejemplo de comandos
                  Text(
                    'Di: "Reportar retraso" o "El bus va lleno"',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),

                  // Barra de navegación
                  BottomNavBar(
                    currentIndex: 2, // Contribuir seleccionado
                    onTap: (index) {
                      switch (index) {
                        case 0:
                          Navigator.pushReplacementNamed(context, '/map');
                          break;
                        case 1:
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Guardados (no implementado)')),
                          );
                          break;
                        case 2:
                          // Ya estamos aquí
                          break;
                        case 3:
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Negocios (no implementado)')),
                          );
                          break;
                      }
                    },
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
