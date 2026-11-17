import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:frota_core/frota_core.dart';
import 'package:frota_server/src/api_exception.dart';
import 'package:frota_server/src/frota_service.dart';
import 'package:frota_server/src/middleware.dart';
import 'package:frota_server/src/supabase_auth.dart';
import 'package:frota_server/src/user_input.dart';
import 'package:frota_server/src/usuarios_repository.dart';

/// `/usuarios/{id}` (só Administrador).
/// - GET: detalhe do usuário.
/// - PATCH: altera dados, perfil ou ativa/desativa o acesso.
///   Desativar bloqueia o login e mantém o histórico. Desativar ou tirar o
///   perfil Padrão cancela as solicitações pendentes e aprovadas dele (com
///   veículo em uso → 409).
/// - DELETE: exclui o cadastro e o login, desde que o usuário não tenha
///   solicitações (pedidas ou decididas). Com histórico, o caminho é desativar.
Future<Response> onRequest(RequestContext context, String id) async {
  final userId = int.tryParse(id);
  if (userId == null) {
    throw const ApiException.notFound('Usuário não encontrado.');
  }

  final repository = context.read<UsuariosRepository>();

  switch (context.request.method) {
    case HttpMethod.get:
      final user = await repository.findById(userId);
      if (user == null) {
        throw const ApiException.notFound('Usuário não encontrado.');
      }
      return Response.json(body: user.toJson());

    case HttpMethod.patch:
      final changes = parseUserUpdate(await readJsonObject(context));

      // O Administrador não pode tirar o próprio acesso nem o próprio perfil:
      // evita que o sistema fique sem ninguém para administrar.
      final me = context.read<UserModel>();
      final selfLockout =
          changes['ativo'] == false ||
          (changes.containsKey('perfil') &&
              changes['perfil'] != UserProfile.administrador.name);
      if (me.id == userId && selfLockout) {
        throw const ApiException.forbidden(
          'Você não pode desativar nem rebaixar o próprio usuário.',
        );
      }

      final before = await repository.findById(userId);
      if (before == null) {
        throw const ApiException.notFound('Usuário não encontrado.');
      }

      // Perdeu o direito de solicitar (desativado ou deixou de ser Padrão):
      // as pendentes e aprovadas dele são canceladas junto (o veículo
      // reservado fica livre). Com veículo em uso, a alteração é recusada.
      final deactivated = changes['ativo'] == false && before.active;
      final leftStandard =
          before.profile == UserProfile.padrao &&
          changes.containsKey('perfil') &&
          changes['perfil'] != UserProfile.padrao.name;
      final updated = deactivated || leftStandard
          ? await context.read<FrotaService>().updateUserClosingRequests(
              userId,
              changes,
              deactivated
                  ? CancellationReason.usuarioDesativado
                  : CancellationReason.perfilAlterado,
            )
          : await repository.update(userId, changes);

      // O banco (coluna `ativo`) é quem manda: a API recusa usuário inativo
      // em toda requisição. Bloquear o login no Supabase impede também que
      // ele obtenha novos tokens.
      final active = changes['ativo'] as bool?;
      if (active != null && active != before.active) {
        final authId = await repository.authIdOf(userId);
        try {
          await context.read<SupabaseAuth>().setBanned(
            authId!,
            banned: !active,
          );
        } on SupabaseAuthException catch (e) {
          stderr.writeln('Aviso: cadastro atualizado, mas $e');
        }
      }

      return Response.json(body: updated!.toJson());

    case HttpMethod.delete:
      if (context.read<UserModel>().id == userId) {
        throw const ApiException.forbidden(
          'Você não pode excluir o próprio usuário.',
        );
      }
      final authId = await repository.authIdOf(userId);
      if (authId == null) {
        throw const ApiException.notFound('Usuário não encontrado.');
      }
      if (await repository.hasHistory(userId)) {
        throw const ApiException.conflict(
          'Este usuário tem solicitações registradas e não pode ser '
          'excluído. Desative o acesso.',
        );
      }
      await repository.delete(userId);
      try {
        await context.read<SupabaseAuth>().deleteUser(authId);
      } on SupabaseAuthException catch (e) {
        // O cadastro já foi apagado; sem ele a API recusa o login mesmo
        // que o Supabase ainda tenha o usuário.
        stderr.writeln('Aviso: usuário excluído, mas $e');
      }
      return Response(statusCode: HttpStatus.noContent);

    // ignore: no_default_cases
    default:
      throw const ApiException.methodNotAllowed();
  }
}
