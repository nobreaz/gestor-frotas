import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project/core/components/pending_request_card.dart';
import 'package:project/core/components/request_card.dart';
import 'package:project/core/models/request_model.dart';

RequestModel _request({
  RequestStatus status = RequestStatus.pendente,
  bool failed = false,
}) => RequestModel(
  id: 7,
  requester: 'Ana',
  reason: 'Visita',
  destination: 'Macaé',
  passengers: 1,
  departure: DateTime(2026, 11, 10, 8),
  returnDate: DateTime(2026, 11, 10),
  returnPeriod: ReturnPeriod.tarde,
  status: status,
  pickupFailedAt: failed ? DateTime(2026, 11, 10, 8, 5) : null,
  pickupFailureReason: failed ? PickupFailureReason.problemaVeiculo : null,
  pickupFailureNotes: failed ? 'Pneu furado' : null,
  pickupFailedVehicleId: failed ? 3 : null,
);

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('botão "Não consegui retirar" chama o callback', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _wrap(
        RequestCard(
          request: _request(status: RequestStatus.aprovada),
          onCheckOut: () {},
          onPickupFailure: () => tapped = true,
        ),
      ),
    );
    await tester.tap(find.text('Não consegui retirar o veículo'));
    expect(tapped, isTrue);
  });

  testWidgets('falha → novo veículo: aviso no card do solicitante e '
      'URGENTE no card do aprovador', (tester) async {
    final request = _request(failed: true);
    await tester.pumpWidget(_wrap(RequestCard(request: request)));
    expect(find.textContaining('Retirada não realizada'), findsOneWidget);
    expect(find.textContaining('Pneu furado'), findsOneWidget);

    await tester.pumpWidget(
      _wrap(
        PendingRequestCard(request: request, onApprove: () {}, onReject: () {}),
      ),
    );
    expect(find.text('URGENTE · Retirada não realizada'), findsOneWidget);
  });

  testWidgets('falha → reagendar: card mostra que foi encerrada', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        RequestCard(
          request: _request(status: RequestStatus.cancelada, failed: true),
        ),
      ),
    );
    expect(find.textContaining('Encerrada para reagendamento'), findsOneWidget);
    expect(find.textContaining('Retirada não realizada'), findsNothing);
  });

  testWidgets('cancelada pelo sistema: card explica o motivo', (tester) async {
    final request = _request(status: RequestStatus.cancelada)
      ..cancellationReason = CancellationReason.naoRetirada;
    await tester.pumpWidget(_wrap(RequestCard(request: request)));
    expect(
      find.textContaining('o veículo não foi retirado no dia da saída'),
      findsOneWidget,
    );
  });

  testWidgets('cancelar aparece também na aprovada', (tester) async {
    final request = _request(status: RequestStatus.aprovada);
    expect(request.canCancel, isTrue);
    expect(_request(status: RequestStatus.emUso).canCancel, isFalse);
    var tapped = false;
    await tester.pumpWidget(
      _wrap(RequestCard(request: request, onCancel: () => tapped = true)),
    );
    await tester.tap(find.text('Cancelar'));
    expect(tapped, isTrue);
  });
}
