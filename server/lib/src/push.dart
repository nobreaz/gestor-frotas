import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:frota_core/frota_core.dart';
import 'package:frota_server/src/dispositivos_repository.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:postgres/postgres.dart';

/// Resultado do envio de um push para um celular.
enum PushResult {
  sent,

  /// O token não vale mais (app desinstalado, token trocado): apagar.
  invalidToken,

  /// Falha temporária (rede, FCM fora): tentar de novo depois.
  failed,
}

/// Quem entrega o push. Em produção, o [FcmGateway]; nos testes, um falso.
// ignore: one_member_abstracts
abstract class PushGateway {
  Future<PushResult> send({
    required String token,
    required String title,
    required String body,
    required Map<String, String> data,
  });
}

/// Firebase Cloud Messaging, API HTTP v1, autenticada com a conta de
/// serviço do projeto (JSON baixado do console do Firebase).
class FcmGateway implements PushGateway {
  FcmGateway._(this._credentials, this.projectId);

  /// [serviceAccountJson]: conteúdo do JSON da conta de serviço.
  factory FcmGateway.fromJson(String serviceAccountJson) {
    final json = jsonDecode(serviceAccountJson) as Map<String, dynamic>;
    return FcmGateway._(
      ServiceAccountCredentials.fromJson(json),
      json['project_id'] as String,
    );
  }

  static const _scope = 'https://www.googleapis.com/auth/firebase.messaging';

  final ServiceAccountCredentials _credentials;
  final String projectId;

  /// Cliente HTTP que renova o token de acesso sozinho (criado uma vez).
  Future<AutoRefreshingAuthClient>? _client;

  @override
  Future<PushResult> send({
    required String token,
    required String title,
    required String body,
    required Map<String, String> data,
  }) async {
    try {
      final client = await (_client ??= clientViaServiceAccount(
        _credentials,
        const [_scope],
      ));
      final response = await client
          .post(
            Uri.parse(
              'https://fcm.googleapis.com/v1/projects/$projectId/messages:send',
            ),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'message': {
                'token': token,
                'notification': {'title': title, 'body': body},
                'data': data,
                'android': {
                  'priority': 'HIGH',
                  'notification': {'sound': 'default'},
                },
              },
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) return PushResult.sent;
      // 404 UNREGISTERED: o app foi desinstalado ou o token expirou.
      // 400 com "registration token": token mal formado.
      if (response.statusCode == 404 ||
          (response.statusCode == 400 &&
              response.body.contains('registration token'))) {
        return PushResult.invalidToken;
      }
      stderr.writeln('FCM ${response.statusCode}: ${response.body}');
      return PushResult.failed;
    } on Object catch (e) {
      _client = null; // credencial/rede: recria o cliente na próxima
      stderr.writeln('FCM: falha ao enviar: $e');
      return PushResult.failed;
    }
  }
}

/// Envia para o celular as notificações gravadas no banco.
///
/// Funciona como uma fila: `notificacoes.push_enviado_em` vazio = falta
/// enviar. [trigger] é chamado depois de cada operação que pode ter criado
/// notificações (o envio sai na hora, sem atrasar a resposta da API) e um
/// timer repete a cada minuto para as que falharam.
///
/// Cada notificação é "reservada" com um UPDATE antes do envio
/// (`FOR UPDATE SKIP LOCKED`), então duas instâncias da API não mandam a
/// mesma notificação duas vezes. Só tenta até 5 vezes e só notificações da
/// última hora (um aviso velho no celular confunde mais do que ajuda).
class PushDispatcher {
  PushDispatcher(this._db, this._gateway);

  final Session _db;
  final PushGateway _gateway;

  Timer? _timer;
  Future<int>? _running;
  var _again = false;

  /// Começa a repetição periódica (uma vez por processo).
  void start({Duration every = const Duration(minutes: 1)}) {
    _timer ??= Timer.periodic(every, (_) => trigger());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Pede um envio sem esperar por ele. Se já há um em andamento, roda de
  /// novo quando ele acabar (para pegar o que foi gravado no meio).
  void trigger() {
    if (_running != null) {
      _again = true;
      return;
    }
    _running = _loop().whenComplete(() => _running = null);
  }

  Future<int> _loop() async {
    var total = 0;
    do {
      _again = false;
      try {
        total += await flush();
      } on Object catch (e) {
        stderr.writeln('Push: falha ao processar a fila: $e');
      }
    } while (_again);
    return total;
  }

  /// Envia o que está na fila agora. Devolve quantas notificações foram
  /// entregues a pelo menos um celular.
  Future<int> flush({int batch = 100}) async {
    final claimed = await _db.execute(
      Sql.named('''
        UPDATE notificacoes n
        SET push_enviado_em = now(), push_tentativas = push_tentativas + 1
        WHERE n.id IN (
          SELECT id FROM notificacoes
          WHERE push_enviado_em IS NULL
            AND push_tentativas < 5
            AND criada_em > now() - interval '1 hour'
          ORDER BY id
          LIMIT @batch
          FOR UPDATE SKIP LOCKED
        )
        RETURNING n.id, n.usuario_id, n.solicitacao_id, n.tipo::text,
                  n.destino, n.mensagem'''),
      parameters: {'batch': batch},
    );
    if (claimed.isEmpty) return 0;

    final devices = DispositivosRepository(_db);
    final tokens = await devices.tokensOf(
      claimed.map((row) => row[1]! as int),
    );

    var delivered = 0;
    final retry = <int>[];
    for (final row in claimed) {
      final type = NotificationType.values.byName(row[3]! as String);
      final userTokens = tokens[row[1]! as int] ?? const <String>[];

      var sent = false;
      var failed = false;
      for (final token in userTokens) {
        final result = await _gateway.send(
          token: token,
          title: type.title,
          body: '${row[4]}: ${row[5]}',
          data: {
            'requestId': '${row[2]}',
            'type': type.name,
            'notificationId': '${row[0]}',
          },
        );
        switch (result) {
          case PushResult.sent:
            sent = true;
          case PushResult.invalidToken:
            await devices.removeToken(token);
          case PushResult.failed:
            failed = true;
        }
      }
      if (sent) delivered++;
      // Nenhum celular recebeu por falha temporária: volta para a fila.
      if (failed && !sent) retry.add(row[0]! as int);
    }

    if (retry.isNotEmpty) {
      await _db.execute(
        Sql.named(
          'UPDATE notificacoes SET push_enviado_em = NULL WHERE id = ANY(@ids)',
        ),
        parameters: {'ids': TypedValue(Type.bigIntegerArray, retry)},
      );
    }
    return delivered;
  }
}
