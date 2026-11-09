import 'package:postgres/postgres.dart';

/// Tokens FCM dos celulares logados (tabela `dispositivos`).
class DispositivosRepository {
  DispositivosRepository(this._db);

  final Session _db;

  /// Registra o token para [userId]. Se o token já existia (outra pessoa
  /// entrou no mesmo celular, ou o app reinstalado), passa a ser deste
  /// usuário.
  Future<void> register(
    int userId,
    String token, {
    String platform = 'android',
  }) async {
    await _db.execute(
      Sql.named('''
        INSERT INTO dispositivos (usuario_id, token, plataforma)
        VALUES (@user, @token, @platform)
        ON CONFLICT (token) DO UPDATE
          SET usuario_id = excluded.usuario_id,
              plataforma = excluded.plataforma,
              atualizado_em = now()'''),
      parameters: {'user': userId, 'token': token, 'platform': platform},
    );
  }

  /// Remove o token (ao sair da conta). Só o dono remove.
  Future<void> unregister(int userId, String token) async {
    await _db.execute(
      Sql.named(
        'DELETE FROM dispositivos WHERE usuario_id = @user AND token = @token',
      ),
      parameters: {'user': userId, 'token': token},
    );
  }

  /// Token que o FCM disse não existir mais (app desinstalado etc.).
  Future<void> removeToken(String token) async {
    await _db.execute(
      Sql.named('DELETE FROM dispositivos WHERE token = @token'),
      parameters: {'token': token},
    );
  }

  /// Tokens de cada usuário de [userIds].
  Future<Map<int, List<String>>> tokensOf(Iterable<int> userIds) async {
    final ids = userIds.toSet().toList();
    if (ids.isEmpty) return const {};
    final result = await _db.execute(
      Sql.named(
        'SELECT usuario_id, token FROM dispositivos '
        'WHERE usuario_id = ANY(@ids) ORDER BY id',
      ),
      parameters: {'ids': TypedValue(Type.bigIntegerArray, ids)},
    );
    final map = <int, List<String>>{};
    for (final row in result) {
      (map[row[0]! as int] ??= []).add(row[1]! as String);
    }
    return map;
  }
}
