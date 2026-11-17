import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:project/app_widget.dart';
import 'package:project/core/controllers/notification_controller.dart';
import 'package:project/core/controllers/request_controller.dart';
import 'package:project/core/controllers/user_controller.dart';
import 'package:project/core/services/api_client.dart';
import 'package:project/firebase_options.dart';

/// Push no celular (Firebase Cloud Messaging).
///
/// Quem envia é a API, ao gravar cada notificação. O app só:
/// - registra o token deste celular ao entrar (e quando o token muda);
/// - apaga o token ao sair da conta (o próximo usuário não recebe os avisos
///   do anterior);
/// - com o app aberto, atualiza as listas e mostra um aviso na tela (o
///   Android só desenha a notificação sozinho com o app em segundo plano);
/// - ao tocar na notificação, abre a tela de Notificações.
///
/// Só no Android: na web o push exige service worker e chave VAPID, e o
/// Windows não tem suporte do Firebase Messaging.
class PushService {
  PushService._();

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool _ready = false;
  static String? _token;
  static StreamSubscription<String>? _refreshSub;

  /// Chamado uma vez no `main`, antes do `runApp`.
  static Future<void> init() async {
    if (!supported) return;
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      FirebaseMessaging.onMessage.listen(_onForeground);
      FirebaseMessaging.onMessageOpenedApp.listen((_) => _openNotifications());
      _ready = true;
    } catch (e) {
      // Sem Firebase o app continua funcionando, só sem push.
      debugPrint('Push desligado: $e');
    }
  }

  /// App estava fechado e foi aberto pela notificação: vai para a tela de
  /// Notificações. Chamar depois do `runApp`, já logado.
  static Future<void> openFromLaunchNotification() async {
    if (!_ready) return;
    final message = await FirebaseMessaging.instance.getInitialMessage();
    if (message != null) _openNotifications();
  }

  /// Registra este celular para o usuário logado. Não bloqueia o login:
  /// se o usuário negar a permissão ou a rede falhar, segue sem push.
  static Future<void> register() async {
    if (!_ready) return;
    try {
      final messaging = FirebaseMessaging.instance;
      // Android 13+: pede a permissão de notificações na primeira vez.
      final settings = await messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;

      // getToken/onTokenRefresh estão obsoletos desde o firebase_messaging
      // 17 (a troca é register()/onRegistered, com o "Firebase Installation
      // ID"). Seguimos com o token clássico porque o envio por token na API
      // HTTP v1 é documentado e testado; migrar depois da entrega.
      // ignore: deprecated_member_use
      final token = await messaging.getToken();
      if (token == null) return;
      await _send(token);

      // ignore: deprecated_member_use
      _refreshSub ??= messaging.onTokenRefresh.listen((token) {
        if (UserController.instance.isLoggedIn) _send(token);
      });
    } catch (e) {
      debugPrint('Push: não foi possível registrar o celular: $e');
    }
  }

  /// Ao sair da conta (antes de apagar a sessão, pois a API exige login).
  static Future<void> unregister() async {
    final token = _token;
    if (!_ready || token == null) return;
    try {
      await ApiClient.instance.delete('/me/dispositivos', {'token': token});
    } on ApiError {
      // Sem rede: o servidor apaga quando o FCM recusar o token.
    }
    _token = null;
  }

  static Future<void> _send(String token) async {
    await ApiClient.instance.post('/me/dispositivos', {
      'token': token,
      'platform': 'android',
    });
    _token = token;
  }

  static void _onForeground(RemoteMessage message) {
    if (!UserController.instance.isLoggedIn) return;
    NotificationController.instance.load();
    RequestController.instance.load();

    final n = message.notification;
    final text = [?n?.title, ?n?.body].join(' · ');
    if (text.isEmpty) return;
    AppWidget.messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(label: 'Ver', onPressed: _openNotifications),
      ),
    );
  }

  static void _openNotifications() {
    if (!UserController.instance.isLoggedIn) return;
    NotificationController.instance.load();
    AppWidget.navigatorKey.currentState?.pushNamed('/notifications');
  }
}
