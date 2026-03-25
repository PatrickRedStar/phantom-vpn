import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/ghost_colors.dart';
import '../../providers/admin_provider.dart';
import '../widgets/ghost_overlay.dart';

class AdminClientOverlay extends ConsumerStatefulWidget {
  final bool visible;
  final VoidCallback? onDismiss;

  const AdminClientOverlay({super.key, required this.visible, this.onDismiss});

  @override
  ConsumerState<AdminClientOverlay> createState() => _AdminClientOverlayState();
}

class _AdminClientOverlayState extends ConsumerState<AdminClientOverlay> {
  final _nameCtrl = TextEditingController();
  final _daysCtrl = TextEditingController();

  static final _nameRegex = RegExp(r'^[a-z0-9\-]+$');

  bool get _canSubmit => _nameCtrl.text.trim().isNotEmpty && _nameRegex.hasMatch(_nameCtrl.text.trim());

  @override
  void dispose() {
    _nameCtrl.dispose();
    _daysCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_canSubmit) return;
    final name = _nameCtrl.text.trim();
    final daysText = _daysCtrl.text.trim();
    final days = daysText.isNotEmpty ? int.tryParse(daysText) : null;
    ref.read(adminProvider.notifier).createClient(name, expiresDays: days);
    _nameCtrl.clear();
    _daysCtrl.clear();
    setState(() {});
    widget.onDismiss?.call();
  }

  @override
  Widget build(BuildContext context) {
    final gc = context.ghostColors;

    return GhostOverlay(
      visible: widget.visible,
      onDismiss: widget.onDismiss,
      title: 'Новый клиент',
      titleColor: const Color(0xFFc084fc),
      titleIcon: Icons.person_add,
      gradientStart: gc.adminSheetGradStart,
      gradientEnd: gc.adminSheetGradEnd,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Имя клиента', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: gc.textSecondary)),
            const SizedBox(height: 6),
            TextField(
              controller: _nameCtrl,
              onChanged: (_) => setState(() {}),
              style: TextStyle(fontSize: 13, color: gc.textPrimary),
              decoration: InputDecoration(
                hintText: 'Имя (a-z, 0-9, дефис)',
                hintStyle: TextStyle(fontSize: 12, color: gc.textTertiary),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: gc.border)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: gc.border)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: gc.accentPurple.withValues(alpha: 0.5))),
              ),
            ),
            const SizedBox(height: 14),
            Text('Подписка', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: gc.textSecondary)),
            const SizedBox(height: 6),
            TextField(
              controller: _daysCtrl,
              keyboardType: TextInputType.number,
              style: TextStyle(fontSize: 13, color: gc.textPrimary),
              decoration: InputDecoration(
                hintText: 'Дней подписки (пусто = бессрочно)',
                hintStyle: TextStyle(fontSize: 12, color: gc.textTertiary),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: gc.border)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: gc.border)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: gc.accentPurple.withValues(alpha: 0.5))),
              ),
            ),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                GestureDetector(
                  onTap: widget.onDismiss,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text('Отмена', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: gc.textSecondary)),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _canSubmit ? _submit : null,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                    decoration: BoxDecoration(
                      gradient: _canSubmit ? LinearGradient(colors: [gc.accentPurple, gc.accentPurpleLight]) : null,
                      color: _canSubmit ? null : Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: _canSubmit
                          ? [BoxShadow(color: gc.accentPurple.withValues(alpha: 0.4), blurRadius: 16, offset: const Offset(0, 4))]
                          : null,
                    ),
                    child: Text(
                      'Создать',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _canSubmit ? Colors.white : gc.textTertiary),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
