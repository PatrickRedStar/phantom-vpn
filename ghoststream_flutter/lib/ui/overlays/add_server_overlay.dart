import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/ghost_colors.dart';
import '../widgets/ghost_overlay.dart';

class AddServerOverlay extends ConsumerStatefulWidget {
  final bool visible;
  final VoidCallback? onDismiss;
  final void Function(String name, String connString)? onSubmit;
  final VoidCallback? onOpenQrScanner;

  const AddServerOverlay({
    super.key,
    required this.visible,
    this.onDismiss,
    this.onSubmit,
    this.onOpenQrScanner,
  });

  @override
  ConsumerState<AddServerOverlay> createState() => _AddServerOverlayState();
}

class _AddServerOverlayState extends ConsumerState<AddServerOverlay> {
  final _nameCtrl = TextEditingController();
  final _connCtrl = TextEditingController();

  bool get _canSubmit => _connCtrl.text.trim().isNotEmpty;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _connCtrl.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      _connCtrl.text = data.text!;
      setState(() {});
    }
  }

  void _submit() {
    if (!_canSubmit) return;
    widget.onSubmit?.call(_nameCtrl.text.trim(), _connCtrl.text.trim());
    _nameCtrl.clear();
    _connCtrl.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final gc = context.ghostColors;

    return GhostOverlay(
      visible: widget.visible,
      onDismiss: widget.onDismiss,
      title: 'Добавить подключение',
      titleColor: gc.textPrimary,
      gradientStart: gc.settSheetGradStart,
      gradientEnd: gc.settSheetGradEnd,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Импорт хоста',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
                color: gc.accentPurple,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Вставь строку подключения, импортируй её из буфера или подготовь QR-сканирование для мобильного сценария.',
              style: TextStyle(fontSize: 11, color: gc.textTertiary, height: 1.4),
            ),
            const SizedBox(height: 16),
            Text('Подпись подключения', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: gc.textSecondary)),
            const SizedBox(height: 6),
            _Input(controller: _nameCtrl, hint: 'Название (необязательно)', gc: gc, onChanged: (_) => setState(() {})),
            const SizedBox(height: 14),
            Text('Строка подключения', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: gc.textSecondary)),
            const SizedBox(height: 6),
            _Input(controller: _connCtrl, hint: 'Строка подключения', gc: gc, maxLines: 4, onChanged: (_) => setState(() {})),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _GhostBtn(label: 'Из буфера', gc: gc, onTap: _paste)),
                const SizedBox(width: 10),
                Expanded(child: _GhostBtn(label: 'QR-код', gc: gc, onTap: widget.onOpenQrScanner)),
              ],
            ),
            const SizedBox(height: 18),
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
                      'Добавить',
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

class _Input extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final GhostColors gc;
  final int maxLines;
  final ValueChanged<String>? onChanged;

  const _Input({required this.controller, required this.hint, required this.gc, this.maxLines = 1, this.onChanged});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      onChanged: onChanged,
      style: TextStyle(fontSize: 13, color: gc.textPrimary),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(fontSize: 12, color: gc.textTertiary),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: gc.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: gc.border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: gc.accentPurple.withValues(alpha: 0.5))),
      ),
    );
  }
}

class _GhostBtn extends StatelessWidget {
  final String label;
  final GhostColors gc;
  final VoidCallback? onTap;

  const _GhostBtn({required this.label, required this.gc, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: gc.accentPurple.withValues(alpha: 0.35)),
          color: gc.accentPurple.withValues(alpha: 0.08),
        ),
        alignment: Alignment.center,
        child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: gc.accentPurple)),
      ),
    );
  }
}
