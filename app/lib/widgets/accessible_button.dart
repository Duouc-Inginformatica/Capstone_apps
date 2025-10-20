import 'package:flutter/material.dart';

/// Botón altamente accesible optimizado para personas no videntes
/// Características:
/// - Tamaño grande con toque completo
/// - Retroalimentación háptica
/// - Soporte completo de TalkBack/VoiceOver
/// - Etiquetas semánticas descriptivas
class AccessibleButton extends StatelessWidget {
  final VoidCallback onPressed;
  final String label;
  final String semanticLabel;
  final IconData? icon;
  final Color backgroundColor;
  final double height;
  final double? width;

  const AccessibleButton({
    super.key,
    required this.onPressed,
    required this.label,
    required this.semanticLabel,
    this.icon,
    this.backgroundColor = Colors.blue,
    this.height = 70,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      onTapHint: 'Doble toque para $label',
      child: SizedBox(
        height: height,
        width: width ?? double.infinity,
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: backgroundColor,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            elevation: 8,
            shadowColor: backgroundColor.withValues(alpha: 0.5),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 32, semanticLabel: ''),
                const SizedBox(width: 16),
              ],
              Flexible(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
