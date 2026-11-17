import 'package:dart_frog/dart_frog.dart';
import 'package:frota_core/frota_core.dart';
import 'package:frota_server/src/api_exception.dart';
import 'package:frota_server/src/frota_service.dart';
import 'package:frota_server/src/middleware.dart';
import 'package:frota_server/src/request_input.dart';

/// `POST /solicitacoes/{id}/falha_retirada`
/// `{"reason": "naoDevolvido", "action": "novoVeiculo", "notes": "..."}`:
/// o solicitante não conseguiu retirar o veículo alocado.
///
/// - `reason`: `naoDevolvido`, `problemaVeiculo` ou `outro` (exige `notes`).
/// - `action`: `novoVeiculo` (volta a Pendente e os Aprovadores são
///   avisados) ou `reagendar` (a solicitação é cancelada).
///
/// Só o perfil Padrão, dono da solicitação, aprovada e a partir do dia da
/// saída.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    throw const ApiException.methodNotAllowed();
  }
  final requestId = pathId(id, 'Solicitação não encontrada.');
  final me = context.read<UserModel>();
  checkProfile(me, {UserProfile.padrao}, 'informar problema na retirada');

  final input = parsePickupFailure(await readJsonObject(context));
  final updated = await context.read<FrotaService>().reportPickupFailure(
    me,
    requestId,
    reason: input.reason,
    action: input.action,
    notes: input.notes,
  );
  return Response.json(body: updated.toJson());
}
