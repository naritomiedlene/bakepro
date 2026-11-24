import 'package:flutter/material.dart';

/// Global route observer used to detect when a page becomes visible again
/// after another route is popped.
///
/// This is especially useful with go_router when we need to refresh data when
/// returning from nested screens (e.g. Receita -> Ingredientes/Materiais).
final RouteObserver<ModalRoute<void>> appRouteObserver = RouteObserver<ModalRoute<void>>();
