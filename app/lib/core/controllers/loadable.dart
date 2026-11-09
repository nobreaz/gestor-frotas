import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:project/core/services/api_client.dart';

/// Estado de carregamento de uma lista vinda da API.
/// As telas mostram o indicador enquanto [loading] e a lista ainda está
/// vazia, e [error] (com "Tentar de novo") se a primeira carga falhar.
mixin Loadable on ChangeNotifier {
  bool loading = false;
  String? error;

  /// Executa [fetch] controlando [loading] e [error]. Nunca lança.
  Future<void> guardLoad(Future<void> Function() fetch) async {
    loading = true;
    error = null;
    _notifySafely();
    try {
      await fetch();
    } on ApiError catch (e) {
      error = e.message;
    } finally {
      loading = false;
      _notifySafely();
    }
  }

  /// As telas chamam `load()` no `initState`, que roda durante o build.
  /// Avisar os ouvintes nessa hora (ex.: o contador de não lidas em
  /// Configurações) dispara "setState() called during build". Então,
  /// se estivermos no meio de um build, o aviso fica para o fim do frame.
  void _notifySafely() {
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      scheduler.addPostFrameCallback((_) => notifyListeners());
    } else {
      notifyListeners();
    }
  }
}
