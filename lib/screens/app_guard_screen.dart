import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_guard_service.dart';
import '../state/app_controller.dart';
import '../utils/guard_app_presets.dart';

/// "Choose apps to guard" — lets the user pick which installed apps get
/// covered with the "Allah is calling" screen for 15 minutes after each
/// prayer enters. Android only (see [AppController.guardSupported]).
class AppGuardScreen extends StatefulWidget {
  const AppGuardScreen({super.key});

  @override
  State<AppGuardScreen> createState() => _AppGuardScreenState();
}

class _AppGuardScreenState extends State<AppGuardScreen> {
  late Future<List<GuardableApp>> _appsFuture;
  late Set<String> _selected;
  String _query = '';
  List<GuardableApp> _allApps = const [];

  @override
  void initState() {
    super.initState();
    final controller = context.read<AppController>();
    _selected = controller.guardedPackages.toSet();
    _appsFuture = controller.guardableApps().then((apps) {
      _allApps = apps;
      return apps;
    });
  }

  Future<void> _persist() async {
    await context.read<AppController>().setGuardedPackages(_selected.toList());
  }

  Future<void> _toggle(String package, bool value) async {
    setState(() {
      if (value) {
        _selected.add(package);
      } else {
        _selected.remove(package);
      }
    });
    await _persist();
  }

  Future<void> _applyPreset(Set<String> packages) async {
    setState(() => _selected = packages);
    await _persist();
    if (!mounted) return;
    final count = packages.length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          count == 0
              ? 'Cleared — no apps guarded.'
              : 'Guarding $count app${count == 1 ? '' : 's'}.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Apps to guard'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search apps',
                prefixIcon: Icon(Icons.search),
                filled: true,
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.toLowerCase()),
            ),
          ),
        ),
      ),
      body: FutureBuilder<List<GuardableApp>>(
        future: _appsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final apps =
              (snapshot.data ?? const [])
                  .where((a) => a.label.toLowerCase().contains(_query))
                  .toList();
          if (snapshot.data == null || snapshot.data!.isEmpty) {
            return const Center(child: Text('No apps found.'));
          }
          return Column(
            children: [
              _PresetBar(
                selectedCount: _selected.length,
                onBlockAllExceptMessaging: () => _applyPreset(
                  GuardAppPresets.everythingExceptPhoneAndMessaging(_allApps),
                ),
                onBlockSocial: () => _applyPreset(
                  GuardAppPresets.socialAndEntertainment(_allApps),
                ),
                onClear: () => _applyPreset({}),
              ),
              const Divider(height: 1),
              Expanded(
                child: apps.isEmpty
                    ? const Center(child: Text('No apps match that search.'))
                    : ListView.builder(
                        itemCount: apps.length,
                        itemBuilder: (context, index) {
                          final app = apps[index];
                          return CheckboxListTile(
                            title: Text(app.label),
                            subtitle: Text(
                              app.package,
                              style: const TextStyle(fontSize: 11),
                            ),
                            value: _selected.contains(app.package),
                            onChanged: (v) => _toggle(app.package, v ?? false),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PresetBar extends StatelessWidget {
  const _PresetBar({
    required this.selectedCount,
    required this.onBlockAllExceptMessaging,
    required this.onBlockSocial,
    required this.onClear,
  });

  final int selectedCount;
  final VoidCallback onBlockAllExceptMessaging;
  final VoidCallback onBlockSocial;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            selectedCount == 0
                ? 'Quick pick — or tick apps below'
                : '$selectedCount selected — quick pick still replaces the list',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).hintColor,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.block, size: 18),
                label: const Text('All except calls & messages'),
                onPressed: onBlockAllExceptMessaging,
              ),
              ActionChip(
                avatar: const Icon(Icons.public, size: 18),
                label: const Text('Social & entertainment'),
                onPressed: onBlockSocial,
              ),
              ActionChip(
                avatar: const Icon(Icons.clear_all, size: 18),
                label: const Text('Clear all'),
                onPressed: onClear,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
