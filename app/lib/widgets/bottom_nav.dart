import 'package:flutter/material.dart';

class BottomNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int>? onTap;

  const BottomNavBar({
    super.key,
    this.currentIndex = 0,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _NavItem(
            index: 0,
            selected: currentIndex == 0,
            icon: Icons.explore_outlined,
            selectedIcon: Icons.explore,
            label: 'Explorar',
            onTap: onTap,
          ),
          _NavItem(
            index: 1,
            selected: currentIndex == 1,
            icon: Icons.bookmark_border,
            selectedIcon: Icons.bookmark,
            label: 'Guardados',
            onTap: onTap,
          ),
          _NavItem(
            index: 2,
            selected: currentIndex == 2,
            icon: Icons.add_circle_outline,
            selectedIcon: Icons.add_circle,
            label: 'Contribuir',
            onTap: onTap,
          ),
          _NavItem(
            index: 3,
            selected: currentIndex == 3,
            icon: Icons.storefront_outlined,
            selectedIcon: Icons.storefront,
            label: 'Negocios',
            onTap: onTap,
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final int index;
  final bool selected;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final ValueChanged<int>? onTap;

  const _NavItem({
    required this.index,
    required this.selected,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.black : Colors.grey[600];
    return GestureDetector(
      onTap: () {
        if (onTap != null) onTap!(index);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            selected ? selectedIcon : icon,
            color: color,
            size: 24,
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}