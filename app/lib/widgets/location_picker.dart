import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../services/geocoding_service.dart';

class LocationPicker extends StatefulWidget {
  const LocationPicker({
    super.key,
    required this.sourceLabel,
    this.currentLocation,
    required this.onDestinationSelected,
    required this.onRetryLocation,
  });

  final String sourceLabel;
  final LatLng? currentLocation;
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
    if (value.trim().length < 2) {
      setState(() => _suggestions = <PlaceSuggestion>[]);
      return;
    }
    // Debounce 300ms for responsive as-you-type autocomplete
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      setState(() => _loading = true);
      try {
        final results = await _service.search(
          value.trim(),
          proximity: widget.currentLocation,
        );
        if (mounted) setState(() => _suggestions = results);
      } catch (_) {
        if (mounted) setState(() => _suggestions = <PlaceSuggestion>[]);
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  void _clear() {
    HapticFeedback.selectionClick();
    _controller.clear();
    setState(() => _suggestions = <PlaceSuggestion>[]);
  }

  void _select(PlaceSuggestion suggestion) {
    HapticFeedback.selectionClick();
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

  IconData _getIconForType(String? type) {
    if (type == null) return Icons.place_rounded;
    switch (type.toLowerCase()) {
      case 'restaurant':
      case 'cafe':
      case 'fast_food':
        return Icons.restaurant_rounded;
      case 'hospital':
      case 'pharmacy':
      case 'clinic':
        return Icons.local_hospital_rounded;
      case 'fuel':
        return Icons.local_gas_station_rounded;
      case 'hotel':
        return Icons.hotel_rounded;
      case 'shop':
      case 'supermarket':
      case 'mall':
        return Icons.shopping_bag_rounded;
      case 'bank':
      case 'atm':
        return Icons.account_balance_rounded;
      case 'school':
      case 'college':
      case 'university':
        return Icons.school_rounded;
      case 'place_of_worship':
        return Icons.temple_hindu_rounded;
      default:
        return Icons.place_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A).withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.14),
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.30),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 0),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0A84FF).withValues(alpha: 0.20),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.my_location_rounded, size: 16, color: Color(0xFF0A84FF)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.sourceLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.white,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () {
                        HapticFeedback.selectionClick();
                        widget.onRetryLocation();
                      },
                      tooltip: 'Use my current location',
                      icon: const Icon(Icons.refresh_rounded, color: Color(0xFF94A3B8), size: 20),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF453A).withValues(alpha: 0.20),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.location_on_rounded, size: 16, color: Color(0xFFFF453A)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        onChanged: _changed,
                        textInputAction: TextInputAction.search,
                        style: const TextStyle(color: Colors.white, fontSize: 14.5),
                        decoration: InputDecoration(
                          hintText: 'Where to?',
                          hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 14.5),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 8),
                          suffixIcon: _loading
                              ? const Padding(
                                  padding: EdgeInsets.all(10),
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0A84FF)),
                                  ),
                                )
                              : (_controller.text.isEmpty
                                  ? null
                                  : IconButton(
                                      onPressed: _clear,
                                      icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8), size: 18),
                                    )),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_suggestions.isNotEmpty)
                Container(
                  height: 0.5,
                  color: Colors.white.withValues(alpha: 0.10),
                ),
              ..._suggestions.map(_suggestionTile),
            ],
          ),
        ),
      ),
    );
  }

  Widget _suggestionTile(PlaceSuggestion suggestion) {
    final distStr = suggestion.distanceMeters != null
        ? (suggestion.distanceMeters! >= 1000
            ? '${(suggestion.distanceMeters! / 1000).toStringAsFixed(1)} km'
            : '${suggestion.distanceMeters!.toInt()} m')
        : null;

    final subtitle = distStr != null
        ? (suggestion.address.isNotEmpty ? '$distStr • ${suggestion.address}' : distStr)
        : suggestion.address;

    return InkWell(
      onTap: () => _select(suggestion),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: <Widget>[
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(_getIconForType(suggestion.type), size: 17, color: const Color(0xFF38BDF8)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    suggestion.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      fontSize: 14,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
