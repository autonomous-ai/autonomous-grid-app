import 'package:flutter/material.dart';

/// A scrolling, monospace log pane that sticks to the newest line. Used for
/// streamed CLI output (install/provider logs).
class LogView extends StatefulWidget {
  const LogView({super.key, required this.lines});
  final List<String> lines;

  @override
  State<LogView> createState() => _LogViewState();
}

class _LogViewState extends State<LogView> {
  final _controller = ScrollController();

  @override
  void didUpdateWidget(LogView oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_controller.hasClients) {
        _controller.jumpTo(_controller.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(12),
      child: ListView.builder(
        controller: _controller,
        itemCount: widget.lines.length,
        itemBuilder: (context, i) => Text(
          widget.lines[i],
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: Color(0xFFD4D4D4),
            height: 1.4,
          ),
        ),
      ),
    );
  }
}
