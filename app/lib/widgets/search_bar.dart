import 'package:flutter/material.dart';

class DestinationSearchBar extends StatefulWidget {
  const DestinationSearchBar({super.key, required this.onSearch});
  final Future<void> Function(String query) onSearch;

  @override
  State<DestinationSearchBar> createState() => _DestinationSearchBarState();
}

class _DestinationSearchBarState extends State<DestinationSearchBar> {
  final _controller = TextEditingController();
  bool _loading = false;

  Future<void> _submit() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    setState(() => _loading = true);
    try {
      await widget.onSearch(query);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Material(
        elevation: 6,
        shadowColor: Colors.black26,
        borderRadius: BorderRadius.circular(18),
        child: TextField(
          controller: _controller,
          onSubmitted: (_) => _submit(),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search for destination...',
            prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF1A73E8)),
            suffixIcon: _loading ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))) : IconButton(onPressed: () { _controller.clear(); }, icon: const Icon(Icons.clear_rounded)),
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      );
}
