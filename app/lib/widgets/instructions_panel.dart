import 'package:flutter/material.dart';

/// Widget independiente para mostrar instrucciones de navegación
/// 
/// Características:
/// - Lista de instrucciones paso a paso
/// - Resalta instrucción actual
/// - Accesible (TalkBack/VoiceOver)
/// - Swipe para siguiente/anterior
/// - Animaciones suaves
/// 
/// Uso:
/// ```dart
/// InstructionsPanelWidget(
///   instructions: ['Gira a la izquierda', 'Continúa recto'],
///   currentStep: 0,
///   onStepChanged: (step) => setState(() => currentStep = step),
///   onClose: () => setState(() => showPanel = false),
/// )
/// ```
class InstructionsPanelWidget extends StatefulWidget {
  final List<String> instructions;
  final int currentStep;
  final Function(int)? onStepChanged;
  final VoidCallback? onClose;
  final VoidCallback? onRepeat;
  final bool autoRead;
  final Color? backgroundColor;
  final Color? textColor;
  final double? height;

  const InstructionsPanelWidget({
    super.key,
    required this.instructions,
    required this.currentStep,
    this.onStepChanged,
    this.onClose,
    this.onRepeat,
    this.autoRead = true,
    this.backgroundColor,
    this.textColor,
    this.height,
  });

  @override
  State<InstructionsPanelWidget> createState() => _InstructionsPanelWidgetState();
}

class _InstructionsPanelWidgetState extends State<InstructionsPanelWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _slideAnimation;
  late PageController _pageController;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _slideAnimation = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

    _pageController = PageController(initialPage: widget.currentStep);

    _controller.forward();
  }

  @override
  void didUpdateWidget(InstructionsPanelWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Animar a nueva página si cambió el paso
    if (widget.currentStep != oldWidget.currentStep) {
      _pageController.animateToPage(
        widget.currentStep,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _handlePageChanged(int page) {
    widget.onStepChanged?.call(page);
  }

  void _handleClose() {
    _controller.reverse().then((_) {
      widget.onClose?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.instructions.isEmpty) {
      return const SizedBox.shrink();
    }

    final bgColor = widget.backgroundColor ??
        Theme.of(context).colorScheme.surface.withOpacity(0.95);
    final txtColor = widget.textColor ?? Theme.of(context).colorScheme.onSurface;

    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(_slideAnimation),
      child: Container(
        height: widget.height ?? MediaQuery.of(context).size.height * 0.35,
        decoration: BoxDecoration(
          color: bgColor,
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
            // Header
            _buildHeader(context, txtColor),

            // Progress indicator
            _buildProgressIndicator(context),

            // Instructions PageView
            Expanded(
              child: _buildInstructionsView(context, txtColor),
            ),

            // Controls
            _buildControls(context, txtColor),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, Color textColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: textColor.withOpacity(0.1),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.directions,
            color: textColor,
            semanticLabel: 'Instrucciones de navegación',
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Instrucciones',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
          ),
          // Botón de repetir
          if (widget.onRepeat != null)
            IconButton(
              icon: Icon(Icons.replay, color: textColor),
              onPressed: widget.onRepeat,
              tooltip: 'Repetir instrucción',
            ),
          // Botón de cerrar
          if (widget.onClose != null)
            IconButton(
              icon: Icon(Icons.close, color: textColor),
              onPressed: _handleClose,
              tooltip: 'Cerrar instrucciones',
            ),
        ],
      ),
    );
  }

  Widget _buildProgressIndicator(BuildContext context) {
    final progress = widget.instructions.isEmpty
        ? 0.0
        : (widget.currentStep + 1) / widget.instructions.length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Paso ${widget.currentStep + 1} de ${widget.instructions.length}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                '${(progress * 100).toInt()}%',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.grey.withOpacity(0.2),
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstructionsView(BuildContext context, Color textColor) {
    return PageView.builder(
      controller: _pageController,
      onPageChanged: _handlePageChanged,
      itemCount: widget.instructions.length,
      itemBuilder: (context, index) {
        final instruction = widget.instructions[index];
        final isCurrentStep = index == widget.currentStep;

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Ícono de paso
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: isCurrentStep
                        ? Theme.of(context).colorScheme.primary
                        : Colors.grey.withOpacity(0.3),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: isCurrentStep ? Colors.white : textColor,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                
                // Instrucción
                Text(
                  instruction,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: isCurrentStep ? 20 : 18,
                    fontWeight: isCurrentStep ? FontWeight.w600 : FontWeight.normal,
                    color: textColor,
                    height: 1.4,
                  ),
                  semanticsLabel: instruction,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildControls(BuildContext context, Color textColor) {
    final hasPrevious = widget.currentStep > 0;
    final hasNext = widget.currentStep < widget.instructions.length - 1;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: textColor.withOpacity(0.1),
            width: 1,
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Botón anterior
          Expanded(
            child: ElevatedButton.icon(
              onPressed: hasPrevious
                  ? () => _handlePageChanged(widget.currentStep - 1)
                  : null,
              icon: const Icon(Icons.chevron_left),
              label: const Text('Anterior'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 16),

          // Botón siguiente
          Expanded(
            child: ElevatedButton.icon(
              onPressed: hasNext
                  ? () => _handlePageChanged(widget.currentStep + 1)
                  : null,
              icon: const Icon(Icons.chevron_right),
              label: const Text('Siguiente'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Widget compacto de instrucción actual (para mostrar en top del mapa)
class CurrentInstructionBanner extends StatelessWidget {
  final String instruction;
  final int currentStep;
  final int totalSteps;
  final VoidCallback? onTap;
  final VoidCallback? onRepeat;

  const CurrentInstructionBanner({
    super.key,
    required this.instruction,
    required this.currentStep,
    required this.totalSteps,
    this.onTap,
    this.onRepeat,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Paso $currentStep de $totalSteps',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    instruction,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (onRepeat != null) ...[
              const SizedBox(width: 12),
              IconButton(
                icon: const Icon(Icons.replay, color: Colors.white),
                onPressed: onRepeat,
                tooltip: 'Repetir',
              ),
            ],
          ],
        ),
      ),
    );
  }
}
