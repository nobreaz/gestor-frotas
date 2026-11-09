import 'package:dart_frog/dart_frog.dart';
import 'package:frota_core/frota_core.dart';
import 'package:frota_server/src/api_exception.dart';
import 'package:frota_server/src/dispositivos_repository.dart';
import 'package:frota_server/src/json_reader.dart';
import 'package:frota_server/src/middleware.dart';

/// `/me/dispositivos`: celular que recebe push (Firebase Cloud Messaging).
/// - POST `{"token": "...", "platform": "android"}`: registra o celular
///   para o usuário logado (o app chama ao entrar e quando o token muda).
/// - DELETE `{"token": "..."}`: o app chama ao sair da conta.
/// Qualquer perfil logado. Responde 204.
Future<Response> onRequest(RequestContext context) async {
  final me = context.read<UserModel>();
  final devices = context.read<DispositivosRepository>();

  switch (context.request.method) {
    case HttpMethod.post:
      final input = _parse(await readJsonObject(context));
      await devices.register(me.id, input.token, platform: input.platform);
      return Response(statusCode: 204);
    case HttpMethod.delete:
      final input = _parse(await readJsonObject(context));
      await devices.unregister(me.id, input.token);
      return Response(statusCode: 204);
    // ignore: no_default_cases
    default:
      throw const ApiException.methodNotAllowed();
  }
}

({String token, String platform}) _parse(Map<String, dynamic> json) {
  final r = JsonReader(json);
  final token = r.requiredText('token', 'Token');
  final platform = r.optionalText('platform') ?? 'android';
  if (token.length > 4096) r.errors['token'] = 'Token inválido.';
  r.throwIfInvalid();
  return (token: token, platform: platform);
}
