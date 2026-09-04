import 'dart:async';

import 'package:flutter/material.dart';

import '../services/geocoding_service.dart';

class LocationPicker extends StatefulWidget {
  const LocationPicker({super.key, required this.sourceLabel, required this.onDestinationSelected, required this.onRetryLocation});

  final String sourceLabel;
  final ValueChanged<PlaceSuggestion> onDestinationSelected;
  final VoidCallback onRetryLocation;

  @override
  State<LocationPicker> createState() => _LocationPickerState();
}

class _LocationPickerState extends State<LocationPicker> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _service = GeocodingService();
  Timer? _debounce;
  List<PlaceSuggestion> _suggestions = <PlaceSuggestion>[];
  bool _loading = false;

  void _changed(String value) {
    _debounce?.cancel();
    if (value.trim().length < 3) {
      setState(() => _suggestions = <PlaceSuggestion>[]);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      setState(() => _loading = true);
      try {
        final results = await _service.search(value.trim());
        if (mounted) setState(() => _suggestions = results);
      } catch (_) {
        if (mounted) setState(() => _suggestions = <PlaceSuggestion>[]);
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  void _clear() {
    _controller.clear();
    setState(() => _suggestions = <PlaceSuggestion>[]);
  }

  void _select(PlaceSuggestion suggestion) {
    _controller.text = suggestion.name;
    _focusNode.unfocus();
    setState(() => _suggestions = <PlaceSuggestion>[]);
    widget.onDestinationSelected(suggestion);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 8,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(22),
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              children: <Widget>[
                const Icon(Icons.my_location_rounded, size: 20, color: Color(0xFF1A73E8)),
                const SizedBox(width: 14),
                Expanded(child: Text(widget.sourceLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF172033)))),
                IconButton(onPressed: widget.onRetryLocation, tooltip: 'Use my current location', icon: const Icon(Icons.refresh_rounded, color: Color(0xFF64748B))),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(
              children: <Widget>[
                const SizedBox(width: 2),
                Column(children: <Widget>[Container(width: 1, height: 10, color: const Color(0xFFCBD5E1)), const Icon(Icons.location_on_rounded, size: 18, color: Color(0xFFE55B4D))]),
                const SizedBox(width: 14),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    onChanged: _changed,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Where to?',
                      hintStyle: const TextStyle(color: Color(0xFF94A3B8)),
                      border: InputBorder.none,
                      suffixIcon: _loading ? const Padding(padding: EdgeInsets.all(13), child: SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2))) : (_controller.text.isEmpty ? null : IconButton(onPressed: _clear, icon: const Icon(Icons.close_rounded))),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_suggestions.isNotEmpty) const Divider(height: 1),
          ..._suggestions.map(_suggestionTile),
        ],
      ),
    );
  }

  Widget _suggestionTile(PlaceSuggestion suggestion) {
    return InkWell(
      onTap: () => _select(suggestion),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          children: <Widget>[
            const Icon(Icons.place_outlined, size: 21, color: Color(0xFF64748B)),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[Text(suggestion.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF172033))), const SizedBox(height: 2), Text(suggestion.address, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)))])),
          ],
        ),
      ),
    );
  }
}
