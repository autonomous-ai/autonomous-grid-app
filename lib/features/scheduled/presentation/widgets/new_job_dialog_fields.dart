part of 'new_job_dialog.dart';

class _TaskField extends StatelessWidget {
  const _TaskField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.onChanged,
    this.autofocus = false,
    this.minLines = 1,
    this.maxLines = 1,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final VoidCallback onChanged;
  final bool autofocus;
  final int minLines;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      minLines: minLines,
      maxLines: maxLines,
      onChanged: (_) => onChanged(),
      style: const TextStyle(fontSize: 15, height: 1.3),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        alignLabelWithHint: maxLines > 1,
        filled: true,
        fillColor: AppPalette.cardBg,
        contentPadding: EdgeInsets.fromLTRB(14, maxLines > 1 ? 14 : 12, 14, 12),
        border: _fieldBorder(AppPalette.divider),
        enabledBorder: _fieldBorder(AppPalette.divider),
        focusedBorder: _fieldBorder(AppPalette.accent),
      ),
    );
  }

  OutlineInputBorder _fieldBorder(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: BorderSide(color: color),
  );
}
