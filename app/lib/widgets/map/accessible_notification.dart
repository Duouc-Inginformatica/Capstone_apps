import 'package:flutter/material.dart';
import 'dart:async';
import '../../services/device/haptic_feedback_service.dart';

enum NotificationType { success, error, warning, info, navigation, orientation }

class NotificationData {
  final String message;
  final NotificationType type;
  final IconData? icon;
  final Duration duration;
  final bool withSound;
  final bool withVibration;

  const NotificationData({
    required this.message,
    required this.type,
    this.icon,
    this.duration = const Duration(seconds: 3),
    this.withSound = false,
    this.withVibration = false,
  });
}

class AccessibleNotification extends StatefulWidget {
  final NotificationData notification;
  final VoidCallback onDismiss;

  const AccessibleNotification({
    super.key,
    required this.notification,
    required this.onDismiss,
  });

  @override
  State<AccessibleNotification> createState() => _AccessibleNotificationState();
}

class _AccessibleNotificationState extends State<AccessibleNotification>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;
  Timer? _autoDismissTimer;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -0.08),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );

    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeIn,
    );

    _controller.forward();
    _scheduleAutoDismiss();
    _maybeTriggerFeedback();
  }

  @override
  void didUpdateWidget(covariant AccessibleNotification oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.notification != widget.notification) {
      _autoDismissTimer?.cancel();
      _scheduleAutoDismiss();
      _maybeTriggerFeedback();
    }
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _scheduleAutoDismiss() {
    if (widget.notification.duration == Duration.zero) {
      return;
    }

    _autoDismissTimer = Timer(widget.notification.duration, () {
      if (!mounted) return;
      _dismiss();
    });
  }

  Future<void> _maybeTriggerFeedback() async {
    if (!widget.notification.withVibration) return;

    try {
      await HapticFeedbackService.instance.lightNotification();
    } catch (_) {
      // Ignorar fallas de vibración para no interrumpir la notificación.
    }
  }

  void _dismiss() {
    if (!mounted) return;

    _autoDismissTimer?.cancel();
    _controller.reverse().then((_) {
      if (mounted) {
        widget.onDismiss();
      }
    });
  }

  IconData _resolveIcon() {
    if (widget.notification.icon != null) {
      return widget.notification.icon!;
    }

    switch (widget.notification.type) {
      case NotificationType.success:
        return Icons.check_circle_outline;
      case NotificationType.error:
        return Icons.error_outline;
      case NotificationType.warning:
        return Icons.warning_amber_outlined;
      case NotificationType.info:
        return Icons.info_outline;
      case NotificationType.navigation:
        return Icons.navigation;
      case NotificationType.orientation:
        return Icons.explore;
    }
  }

  Color _resolveBackgroundColor() {
    switch (widget.notification.type) {
      case NotificationType.success:
        return const Color(0xFF16A34A);
      case NotificationType.error:
        return const Color(0xFFDC2626);
      case NotificationType.warning:
        return const Color(0xFFF97316);
      case NotificationType.info:
        return const Color(0xFF2563EB);
      case NotificationType.navigation:
        return const Color(0xFF0EA5E9);
      case NotificationType.orientation:
        return const Color(0xFF7C3AED);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _resolveBackgroundColor(),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(
                _resolveIcon(),
                color: Colors.white,
                size: 24,
                semanticLabel: widget.notification.type.name,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.notification.message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  semanticsLabel: widget.notification.message,
                ),
              ),
              GestureDetector(
                onTap: _dismiss,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  child: const Icon(
                    Icons.close,
                    color: Colors.white70,
                    size: 20,
                    semanticLabel: 'Cerrar notificación',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
