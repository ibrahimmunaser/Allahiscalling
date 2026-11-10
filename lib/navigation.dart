import 'package:flutter/material.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Used by Settings (and other routes) to restore system UI when a pushed
/// immersive screen (e.g. Preview reminder) pops back.
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();
