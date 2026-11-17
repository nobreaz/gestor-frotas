import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:frota_core/frota_core.dart';
import 'package:frota_server/src/api_exception.dart';
import 'package:frota_server/src/frota_service.dart';
import 'package:frota_server/src/middleware.dart';
import 'package:frota_server/src/vehicle_input.dart';
import 'package:frota_server/src/veiculos_repository.dart';

/// `/veiculos/{id}`
/// - GET: detalhe (qualquer usuário logado).
/// - PATCH: altera dados ou status (só Administrador, RF 3.2.3 e 3.2.4).
///   Desativar = `{"status": "inativo"}`;
///   reativar = `{"status": "disponivel"}`.
/// - DELETE: exclui (só Administrador), desde que o veículo nunca tenha sido
///   usado em uma solicitação. Com histórico, o caminho é desativar.
///
///   A resposta traz o veículo e `releasedRequestIds`: as reservas aprovadas
///   que voltaram para Pendente porque o veículo deixou de atendê-las.
Future<Response> onRequest(RequestContext context, String id) async {
  final vehicleId = int.tryParse(id);
  if (vehicleId == null) {
    throw const ApiException.notFound('Veículo não encontrado.');
  }

  switch (context.request.method) {
    case HttpMethod.get:
      final vehicle = await context.read<VeiculosRepository>().findById(
        vehicleId,
      );
      if (vehicle == null) {
        throw const ApiException.notFound('Veículo não encontrado.');
      }
      return Response.json(body: vehicle.toJson());

    case HttpMethod.patch:
      checkProfile(context.read<UserModel>(), {
        UserProfile.administrador,
      }, 'alterar veículos');
      final changes = parseVehicleUpdate(await readJsonObject(context));
      final result = await context.read<FrotaService>().updateVehicle(
        vehicleId,
        changes,
      );
      return Response.json(
        body: {
          ...result.vehicle.toJson(),
          'releasedRequestIds': result.releasedRequestIds,
        },
      );

    case HttpMethod.delete:
      checkProfile(context.read<UserModel>(), {
        UserProfile.administrador,
      }, 'excluir veículos');
      final repository = context.read<VeiculosRepository>();
      if (await repository.hasHistory(vehicleId)) {
        throw const ApiException.conflict(
          'Este veículo tem solicitações registradas e não pode ser '
          'excluído. Desative-o.',
        );
      }
      if (!await repository.delete(vehicleId)) {
        throw const ApiException.notFound('Veículo não encontrado.');
      }
      return Response(statusCode: HttpStatus.noContent);

    // ignore: no_default_cases
    default:
      throw const ApiException.methodNotAllowed();
  }
}
