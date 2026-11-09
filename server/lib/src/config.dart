import 'dart:io';

import 'package:dotenv/dotenv.dart';

/// Configuração da API, lida das variáveis de ambiente.
///
/// Em desenvolvimento, os valores vêm do arquivo `server/.env`
/// (copie o `.env.example`). Em produção, das variáveis do servidor.
/// Nenhum segredo fica no código nem no repositório.
class Config {
  const Config({
    required this.databaseUrl,
    required this.supabaseUrl,
    required this.supabasePublishableKey,
    required this.supabaseSecretKey,
    this.firebaseServiceAccount,
  });

  factory Config.fromEnvironment() {
    final env = DotEnv(includePlatformEnvironment: true, quiet: true)..load();

    String required(String key) {
      final value = env[key];
      if (value == null || value.trim().isEmpty) {
        throw StateError(
          'Variável de ambiente $key não definida. '
          'Copie server/.env.example para server/.env e preencha.',
        );
      }
      return value.trim();
    }

    return Config(
      databaseUrl: required('DATABASE_URL'),
      supabaseUrl: Uri.parse(required('SUPABASE_URL')),
      supabasePublishableKey: required('SUPABASE_PUBLISHABLE_KEY'),
      supabaseSecretKey: required('SUPABASE_SECRET_KEY'),
      firebaseServiceAccount: _serviceAccount(env['FIREBASE_SERVICE_ACCOUNT']),
    );
  }

  /// Aceita o JSON direto (hospedagem: variável de ambiente) ou o caminho
  /// do arquivo (desenvolvimento). Vazio = push desligado.
  static String? _serviceAccount(String? value) {
    final v = value?.trim();
    if (v == null || v.isEmpty) return null;
    if (v.startsWith('{')) return v;
    final file = File(v);
    if (!file.existsSync()) {
      throw StateError(
        'FIREBASE_SERVICE_ACCOUNT aponta para um arquivo que não existe: $v',
      );
    }
    return file.readAsStringSync();
  }

  /// Conexão direta com o PostgreSQL do Supabase (pooler, modo session).
  final String databaseUrl;

  /// Ex.: https://abcdefgh.supabase.co
  final Uri supabaseUrl;

  /// Chave pública (`sb_publishable_...`), a mesma usada no app.
  final String supabasePublishableKey;

  /// Chave secreta (`sb_secret_...`). Só no servidor: cria e bloqueia logins.
  final String supabaseSecretKey;

  /// JSON da conta de serviço do Firebase (push no celular). Opcional:
  /// sem ela a API funciona normalmente, só não envia push.
  final String? firebaseServiceAccount;
}
