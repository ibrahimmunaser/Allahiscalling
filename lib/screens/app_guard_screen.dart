import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_guard_service.dart';
import '../state/app_controller.dart';

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

  @override
  void initState() {
    super.initState();
    final controller = context.read<AppController>();
    _selected = controller.guardedPackages.toSet();
    _appsFuture = controller.guardableApps();
  }

  Future<void> _toggle(String package, bool value) async {
    setState(() {
      if (value) {
        _selected.add(package);
      } else {
        _selected.remove(package);
      }
    });
    await context.read<AppController>().setGuardedPackages(_selected.toList());
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
          if (apps.isEmpty) {
            return const Center(child: Text('No apps found.'));
          }
          return ListView.builder(
            itemCount: apps.length,
            itemBuilder: (context, index) {
              final app = apps[index];
              return CheckboxListTile(
                title: Text(app.label),
                subtitle: Text(app.package, style: const TextStyle(fontSize: 11)),
                value: _selected.contains(app.package),
                onChanged: (v) => _toggle(app.package, v ?? false),
              );
            },
          );
        },
      ),
    );
  }
}
