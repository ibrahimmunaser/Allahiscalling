import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/city.dart';
import '../services/city_database.dart';
import '../services/timezone_service.dart';
import '../state/app_controller.dart';
import '../utils/app_theme.dart';

/// Manual location fallback: search the offline global city database
/// (~170k GeoNames places), fall back to online geocoding, or enter raw
/// coordinates. Cities only provide coordinates -- prayer times are always
/// calculated from latitude/longitude.
class ManualLocationScreen extends StatefulWidget {
  /// 0 = city search, 1 = manual coordinates.
  final int initialTab;

  const ManualLocationScreen({super.key, this.initialTab = 0});

  @override
  State<ManualLocationScreen> createState() => _ManualLocationScreenState();
}

class _ManualLocationScreenState extends State<ManualLocationScreen> {
  final _searchController = TextEditingController();
  final _latController = TextEditingController();
  final _lngController = TextEditingController();
  final _tzController = TextEditingController();

  Timer? _debounce;
  String _query = '';
  List<City> _results = const [];
  List<City> _nearby = const [];
  bool _searching = false;
  bool _searchedOnline = false;
  bool _onlineSearching = false;
  bool _databaseReady = false;

  @override
  void initState() {
    super.initState();
    _prepareDatabase();
  }

  Future<void> _prepareDatabase() async {
    await CityDatabase.instance.ensureLoaded();
    if (!mounted) return;
    setState(() => _databaseReady = true);
    _loadNearby();
  }

  Future<void> _loadNearby() async {
    final settings = context.read<AppController>().settings;
    if (!settings.hasLocation) return;
    final nearby = await CityDatabase.instance.nearby(
      settings.latitude!,
      settings.longitude!,
      limit: 12,
    );
    if (!mounted) return;
    setState(() => _nearby = nearby);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _latController.dispose();
    _lngController.dispose();
    _tzController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _query = value;
    _searchedOnline = false;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _runSearch);
  }

  Future<void> _runSearch() async {
    final query = _query.trim();
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    final results = await CityDatabase.instance.search(query);
    if (!mounted || query != _query.trim()) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  Future<void> _searchOnline() async {
    final geocoding = context.read<AppController>().geocodingService;
    setState(() => _onlineSearching = true);
    final results = await geocoding.lookup(_query.trim());
    if (!mounted) return;
    setState(() {
      _onlineSearching = false;
      _searchedOnline = true;
      if (results.isNotEmpty) _results = results;
    });
    if (results.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No matches found online either. Check the spelling, or enter coordinates manually.',
          ),
        ),
      );
    }
  }

  Future<void> _selectCity(City city) async {
    final controller = context.read<AppController>();
    final navigator = Navigator.of(context);
    await controller.setCityLocation(city);
    if (mounted) navigator.pop();
  }

  Future<void> _applyCoordinates() async {
    final messenger = ScaffoldMessenger.of(context);
    final lat = double.tryParse(_latController.text.trim());
    final lng = double.tryParse(_lngController.text.trim());
    if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Please enter a valid latitude (-90 to 90) and longitude (-180 to 180).',
          ),
        ),
      );
      return;
    }

    String? timezone;
    final tzInput = _tzController.text.trim();
    if (tzInput.isNotEmpty) {
      if (!TimezoneService().isValidTimezone(tzInput)) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Unknown timezone. Use an IANA name like "America/New_York", or leave it blank to detect it from the coordinates.',
            ),
          ),
        );
        return;
      }
      timezone = tzInput;
    }

    final controller = context.read<AppController>();
    final navigator = Navigator.of(context);
    await controller.setManualCoordinates(lat, lng, timezone);
    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Set Location'),
          bottom: const TabBar(
            indicatorColor: Colors.amber,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            tabs: [Tab(text: 'Search City'), Tab(text: 'Coordinates')],
          ),
        ),
        body: TabBarView(children: [_buildCityTab(), _buildCoordinatesTab()]),
      ),
    );
  }

  // -------------------------------------------------------------- city tab

  Widget _buildCityTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search your city',
              helperText:
                  'Try "Springfield, Illinois" or "Detroit USA". Works offline.',
              border: const OutlineInputBorder(),
              suffixIcon:
                  _query.isNotEmpty
                      ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _onQueryChanged('');
                        },
                      )
                      : null,
            ),
            onChanged: _onQueryChanged,
          ),
        ),
        Expanded(child: _buildCityResults()),
      ],
    );
  }

  Widget _buildCityResults() {
    if (!_databaseReady) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Loading city database…'),
          ],
        ),
      );
    }

    if (_query.trim().isEmpty) {
      if (_nearby.isEmpty) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Search any city or town worldwide.\nOver 170,000 places available offline.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ),
        );
      }
      return ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'NEARBY',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppTheme.emerald,
                letterSpacing: 1,
              ),
            ),
          ),
          ..._nearby.map(_cityTile),
        ],
      );
    }

    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.search_off, size: 40, color: Colors.grey),
              const SizedBox(height: 12),
              Text(
                'No offline match for "${_query.trim()}".',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              if (!_searchedOnline)
                FilledButton.icon(
                  onPressed: _onlineSearching ? null : _searchOnline,
                  icon:
                      _onlineSearching
                          ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : const Icon(Icons.cloud_outlined),
                  label: const Text('Search online'),
                ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, index) => _cityTile(_results[index]),
    );
  }

  Widget _cityTile(City city) {
    final details = [
      if (city.region.isNotEmpty) city.region,
      if (city.country.isNotEmpty) city.country,
    ].join(', ');
    return ListTile(
      leading: const Icon(Icons.location_city_outlined),
      title: Text(city.name),
      subtitle: Text(
        [
          if (details.isNotEmpty) details,
          if (city.timezone.isNotEmpty) city.timezone,
        ].join(' · '),
      ),
      trailing:
          city.population > 0
              ? Text(
                _formatPopulation(city.population),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              )
              : null,
      onTap: () => _selectCity(city),
    );
  }

  static String _formatPopulation(int population) {
    if (population >= 1000000) {
      return '${(population / 1000000).toStringAsFixed(1)}M';
    }
    if (population >= 1000) return '${(population / 1000).round()}K';
    return '$population';
  }

  // ------------------------------------------------------- coordinates tab

  Widget _buildCoordinatesTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _latController,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: const InputDecoration(
            labelText: 'Latitude',
            hintText: 'e.g. 40.7128',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _lngController,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: const InputDecoration(
            labelText: 'Longitude',
            hintText: 'e.g. -74.0060',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _tzController,
          decoration: const InputDecoration(
            labelText: 'Timezone (optional)',
            hintText: 'e.g. America/New_York',
            helperText:
                'Leave blank to detect the timezone from the coordinates.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _applyCoordinates,
          child: const Text('Save location'),
        ),
      ],
    );
  }
}
