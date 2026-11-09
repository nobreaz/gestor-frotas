import 'package:flutter/material.dart';
import 'package:project/core/components/request_card.dart';
import 'package:project/core/controllers/request_controller.dart';
import 'package:project/core/controllers/user_controller.dart';
import 'package:project/core/controllers/vehicle_controller.dart';
import 'package:project/core/components/load_state.dart';
import 'package:project/core/models/request_model.dart';
import 'package:project/core/models/vehicle_model.dart';
import 'package:project/core/services/api_client.dart';
import 'package:project/core/services/feedback.dart';
import 'package:project/core/theme/app_colors.dart';
import 'package:project/pages/new_request_page.dart';

class MyRequestsPage extends StatelessWidget {
  const MyRequestsPage({super.key});

  /// Diálogo do check-out e do check-in: quilometragem + observação.
  Future<({int mileage, String? notes})?> _askMileage(
    BuildContext context, {
    required String title,
    required String description,
    int? minimum,
    String? minimumMessage,
  }) {
    final mileageController = TextEditingController();
    final notesController = TextEditingController();
    String? errorText;

    return showDialog<({int mileage, String? notes})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  description,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                ),
                if (minimum != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Mínimo aceito: $minimum km',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: mileageController,
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Quilometragem',
                    hintText: minimum != null ? '$minimum' : 'Ex.: 42500',
                    errorText: errorText,
                    errorMaxLines: 2,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesController,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: 'Observações (opcional)',
                    hintText: 'Ex.: nível de combustível, avarias...',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () {
                final value = int.tryParse(mileageController.text.trim());
                if (value == null) {
                  setDialogState(() => errorText = 'Informe um número válido.');
                  return;
                }
                if (minimum != null && value < minimum) {
                  setDialogState(
                    () => errorText =
                        minimumMessage ??
                        'O valor deve ser maior ou igual a $minimum km.',
                  );
                  return;
                }
                final notes = notesController.text.trim();
                Navigator.of(dialogContext)
                    .pop((mileage: value, notes: notes.isEmpty ? null : notes));
              },
              child: const Text('Confirmar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkOut(BuildContext context, RequestModel request) async {
    final vehicle = RequestController.instance.vehicleOf(request);
    final minimum = RequestController.instance.minimumCheckOutMileage(request);

    final result = await _askMileage(
      context,
      title: 'Retirada do veículo',
      description: vehicle == null
          ? 'Informe a quilometragem atual do painel.'
          : 'Informe a quilometragem atual do painel do '
                '${vehicle.model} (${vehicle.plate}).',
      minimum: minimum,
      minimumMessage:
          'A km de saída não pode ser menor que a '
          'quilometragem atual do veículo ($minimum km).',
    );
    if (result == null) return;

    if (!context.mounted) return;
    try {
      await RequestController.instance.checkOut(
        request.id,
        result.mileage,
        notes: result.notes,
      );
      if (context.mounted) {
        showSnack(context, 'Check-out registrado. Boa viagem!');
      }
    } on ApiError catch (e) {
      if (!context.mounted) return;
      // Veículo não devolvido, em manutenção...: oferece o fluxo de
      // "não consegui retirar" em vez de só mostrar o erro.
      if (e.statusCode == 409 && request.canReportPickupFailure()) {
        await _reportPickupFailure(
          context,
          request,
          problem: e.message,
          suggested: vehicle?.status == VehicleStatus.emUso
              ? PickupFailureReason.naoDevolvido
              : PickupFailureReason.problemaVeiculo,
        );
      } else {
        showSnack(context, e.details);
      }
    }
  }

  /// "Não consegui retirar o veículo": pergunta o motivo e depois se a
  /// pessoa quer outro veículo (Aprovadores avisados) ou reagendar (a
  /// solicitação é encerrada e abre uma nova já preenchida).
  /// [problem]: mensagem do servidor quando a retirada foi recusada.
  Future<void> _reportPickupFailure(
    BuildContext context,
    RequestModel request, {
    String? problem,
    PickupFailureReason? suggested,
  }) async {
    final failure = await _askFailureReason(
      context,
      problem: problem,
      suggested: suggested,
    );
    if (failure == null || !context.mounted) return;

    final action = await _askFailureAction(context);
    if (action == null || !context.mounted) return;

    final ok = await runWithFeedback(
      context,
      () => RequestController.instance.reportPickupFailure(
        request.id,
        reason: failure.reason,
        action: action,
        notes: failure.notes,
      ),
      success: action == PickupFailureAction.novoVeiculo
          ? 'Os Aprovadores foram avisados e vão alocar outro veículo.'
          : 'Solicitação encerrada. Escolha as novas datas.',
    );
    if (!ok || !context.mounted) return;

    if (action == PickupFailureAction.reagendar) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => NewRequestPage(copyFrom: request)),
      );
    }
  }

  /// Passo 1: o que aconteceu (motivo + observação; "Outro" exige texto).
  Future<({PickupFailureReason reason, String? notes})?> _askFailureReason(
    BuildContext context, {
    String? problem,
    PickupFailureReason? suggested,
  }) {
    var reason = suggested;
    final notesController = TextEditingController();
    String? notesError;

    return showDialog<({PickupFailureReason reason, String? notes})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Não consegui retirar o veículo'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (problem != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.rejected.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      problem,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                const Text(
                  'O que aconteceu?',
                  style: TextStyle(fontSize: 13, color: AppColors.textMuted),
                ),
                RadioGroup<PickupFailureReason>(
                  groupValue: reason,
                  onChanged: (value) => setDialogState(() => reason = value),
                  child: Column(
                    children: [
                      for (final r in PickupFailureReason.values)
                        RadioListTile<PickupFailureReason>(
                          value: r,
                          title: Text(
                            r.label,
                            style: const TextStyle(fontSize: 14),
                          ),
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: notesController,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: reason?.requiresNotes ?? false
                        ? 'Descreva o que aconteceu'
                        : 'Observações (opcional)',
                    hintText: 'Ex.: pneu furado, chave não estava na portaria',
                    errorText: notesError,
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Voltar'),
            ),
            TextButton(
              onPressed: reason == null
                  ? null
                  : () {
                      final notes = notesController.text.trim();
                      if (reason!.requiresNotes && notes.isEmpty) {
                        setDialogState(
                          () => notesError = 'Descreva o que aconteceu.',
                        );
                        return;
                      }
                      Navigator.of(dialogContext).pop((
                        reason: reason!,
                        notes: notes.isEmpty ? null : notes,
                      ));
                    },
              child: const Text('Continuar'),
            ),
          ],
        ),
      ),
    );
  }

  /// Passo 2: outro veículo ou reagendar.
  Future<PickupFailureAction?> _askFailureAction(BuildContext context) {
    Widget option(
      BuildContext dialogContext, {
      required PickupFailureAction action,
      required IconData icon,
      required String title,
      required String subtitle,
    }) => Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(icon, color: AppColors.primary),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        onTap: () => Navigator.of(dialogContext).pop(action),
      ),
    );

    return showDialog<PickupFailureAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('O que você prefere?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            option(
              dialogContext,
              action: PickupFailureAction.novoVeiculo,
              icon: Icons.swap_horiz,
              title: 'Solicitar outro veículo',
              subtitle:
                  'Mantém as datas. Os Aprovadores são avisados na hora '
                  'para trocar o veículo desta solicitação.',
            ),
            option(
              dialogContext,
              action: PickupFailureAction.reagendar,
              icon: Icons.event_repeat,
              title: 'Reagendar a viagem',
              subtitle:
                  'Esta solicitação é encerrada e você abre uma nova, já '
                  'preenchida, escolhendo outras datas.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Voltar'),
          ),
        ],
      ),
    );
  }

  Future<void> _checkIn(BuildContext context, RequestModel request) async {
    final minimum = request.departureMileage;

    final result = await _askMileage(
      context,
      title: 'Devolução do veículo',
      description:
          'Informe a quilometragem do painel no momento '
          'da devolução. A km do veículo será atualizada.',
      minimum: minimum,
      minimumMessage:
          'A km de retorno não pode ser menor que a '
          'km de saída ($minimum km).',
    );
    if (result == null) return;

    if (!context.mounted) return;
    await runWithFeedback(
      context,
      () => RequestController.instance.checkIn(
        request.id,
        result.mileage,
        notes: result.notes,
      ),
      success: 'Devolução registrada. Solicitação finalizada.',
    );
  }

  void _edit(BuildContext context, RequestModel request) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => NewRequestPage(request: request)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Minhas Solicitações',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
        ),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: RefreshOnOpen(
        loaders: [
          RequestController.instance.load,
          VehicleController.instance.load,
        ],
        child: Container(
          color: AppColors.background,
          child: AnimatedBuilder(
            animation: RequestController.instance,
            builder: (context, _) {
              // Apenas as solicitações do usuário logado.
              final userId = UserController.instance.currentUser.id;
              final controller = RequestController.instance;
              final requests = controller.requestsOf(userId);

              if (requests.isEmpty) {
                return LoadState(
                  loading: controller.loading,
                  error: controller.error,
                  onRetry: controller.load,
                  empty: _emptyState(),
                );
              }

              return RefreshIndicator(
                onRefresh: controller.load,
                child: _list(context, requests),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _list(BuildContext context, List<RequestModel> requests) {
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(20),
      itemCount: requests.length,
      separatorBuilder: (_, _) => const SizedBox(height: 16),
      itemBuilder: (context, index) {
        final request = requests[index];

        return RequestCard(
          request: request,
          onCancel: request.status == RequestStatus.pendente
              ? () => runWithFeedback(
                  context,
                  () => RequestController.instance.cancelRequest(request.id),
                  success: 'Solicitação cancelada.',
                )
              : null,
          onEdit: request.canEdit ? () => _edit(context, request) : null,
          onCheckOut: request.status == RequestStatus.aprovada
              ? () => _checkOut(context, request)
              : null,
          onPickupFailure: request.canReportPickupFailure()
              ? () => _reportPickupFailure(context, request)
              : null,
          onCheckIn: request.status == RequestStatus.emUso
              ? () => _checkIn(context, request)
              : null,
        );
      },
    );
  }

  Widget _emptyState() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined, size: 72, color: AppColors.iconMuted),
          SizedBox(height: 12),
          Text(
            'Nenhuma solicitação ainda',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.textMuted,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Suas solicitações aparecerão aqui.',
            style: TextStyle(fontSize: 13, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}
