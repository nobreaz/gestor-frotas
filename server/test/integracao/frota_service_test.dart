// Testes de integração do FrotaService contra o PostgreSQL de verdade.
//
// Rodam DENTRO de uma transação que é sempre desfeita no final: nada fica
// gravado no banco (só os contadores de id avançam). Usam o DATABASE_URL do
// server/.env.
//
// Desligados por padrão. Para rodar, dentro de server/:
//   INTEGRACAO=1 dart test test/integracao          (bash)
//   $env:INTEGRACAO=1; dart test test/integracao    (PowerShell)
@Tags(['integracao'])
library;

import 'dart:io';

import 'package:frota_core/frota_core.dart';
import 'package:frota_server/src/api_exception.dart';
import 'package:frota_server/src/config.dart';
import 'package:frota_server/src/dispositivos_repository.dart';
import 'package:frota_server/src/frota_service.dart';
import 'package:frota_server/src/notificacoes_repository.dart';
import 'package:frota_server/src/push.dart';
import 'package:frota_server/src/relatorios.dart';
import 'package:frota_server/src/relatorios_repository.dart';
import 'package:frota_server/src/request_input.dart';
import 'package:frota_server/src/solicitacoes_repository.dart';
import 'package:frota_server/src/usuarios_repository.dart';
import 'package:frota_server/src/veiculos_repository.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

/// Executa as "transações" do serviço como SAVEPOINTs dentro da transação
/// do teste: um erro desfaz só aquela operação, como em produção, e no fim
/// o teste desfaz tudo.
class _InsideTx implements SessionExecutor {
  _InsideTx(this._tx);

  final TxSession _tx;
  var _count = 0;

  @override
  Future<R> runTx<R>(
    Future<R> Function(TxSession session) fn, {
    TransactionSettings? settings,
  }) async {
    final name = 'sp${_count++}';
    await _tx.execute('SAVEPOINT $name');
    try {
      final result = await fn(_tx);
      await _tx.execute('RELEASE SAVEPOINT $name');
      return result;
    } catch (_) {
      await _tx.execute('ROLLBACK TO SAVEPOINT $name');
      rethrow;
    }
  }

  @override
  Future<R> run<R>(
    Future<R> Function(Session session) fn, {
    SessionSettings? settings,
  }) => fn(_tx);

  @override
  Future<void> close({bool force = false}) async {}
}

class _Rollback implements Exception {}

/// Dados de um cenário, todos criados dentro da transação do teste.
class _World {
  _World(this.tx) : service = FrotaService(_InsideTx(tx));

  final TxSession tx;
  final FrotaService service;
  late final users = UsuariosRepository(tx);
  late final vehicles = VeiculosRepository(tx);
  late final requests = SolicitacoesRepository(tx);
  late final notifications = NotificacoesRepository(tx);

  late UserModel ana; // padrão
  late UserModel caio; // padrão
  late UserModel bruno; // aprovador
  late VehicleModel van; // 7 lugares, 5.000 km
  late VehicleModel uno; // 2 lugares, 900 km
  late VehicleModel gol; // 5 lugares, 3.000 km

  var _seq = 0;

  Future<UserModel> _user(String name, UserProfile profile) async {
    final email = 'teste.${name.toLowerCase()}.${_seq++}@integracao.local';
    final auth = await tx.execute(
      Sql.named(
        'INSERT INTO auth.users (id, email, aud, role) '
        "VALUES (gen_random_uuid(), @email, 'authenticated', 'authenticated') "
        'RETURNING id::text',
      ),
      parameters: {'email': email},
    );
    return users.insert(
      UserModel(
        id: 0,
        name: name,
        email: email,
        role: 'Teste',
        department: 'Teste',
        profile: profile,
        cnhNumber: profile == UserProfile.padrao ? '123' : null,
        cnhExpiry: DateTime.now().add(const Duration(days: 365)),
      ),
      authId: auth.single.first! as String,
    );
  }

  Future<VehicleModel> _vehicle(String plate, int seats, int km) =>
      vehicles.insert(
        VehicleModel(
          id: 0,
          plate: plate,
          chassis: 'CHASSI$plate',
          model: 'Modelo $plate',
          color: 'Branco',
          year: 2022,
          seats: seats,
          mileage: km,
          licensingExpiry: DateTime(2027),
          insuranceExpiry: DateTime(2027),
        ),
      );

  Future<void> seed() async {
    ana = await _user('Ana', UserProfile.padrao);
    caio = await _user('Caio', UserProfile.padrao);
    bruno = await _user('Bruno', UserProfile.aprovador);
    van = await _vehicle('TST9A01', 7, 5000);
    uno = await _vehicle('TST9A02', 2, 900);
    gol = await _vehicle('TST9A03', 5, 3000);
  }

  /// Daqui a [days] dias, saindo às 8h e voltando no mesmo dia à tarde
  /// (horário de Brasília = UTC−3).
  RequestFields trip({
    int days = 3,
    int passengers = 1,
    ReturnPeriod period = ReturnPeriod.tarde,
  }) {
    final now = DateTime.now().toUtc();
    final day = DateTime.utc(now.year, now.month, now.day + days);
    return RequestFields(
      reason: 'Visita técnica',
      destination: 'Macaé',
      passengers: passengers,
      departure: day.add(const Duration(hours: 11)), // 8h em Brasília
      returnDate: DateTime(day.year, day.month, day.day),
      returnPeriod: period,
    );
  }

  Future<List<NotificationType>> notificationTypes(UserModel u) async => [
    for (final n in await notifications.listFor(u.id)) n.type,
  ];
}

Matcher _apiError(int status) =>
    throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', status));

void main() {
  final enabled = Platform.environment['INTEGRACAO'] == '1';
  late Pool<void> db;

  setUpAll(() {
    if (enabled) db = Pool.withUrl(Config.fromEnvironment().databaseUrl);
  });
  tearDownAll(() async {
    if (enabled) await db.close();
  });

  /// Roda [body] numa transação desfeita no final.
  void scenario(String name, Future<void> Function(_World w) body) {
    test(
      name,
      skip: enabled ? null : 'defina INTEGRACAO=1 para rodar contra o banco',
      () async {
        try {
          await db.runTx((tx) async {
            final w = _World(tx);
            await w.seed();
            await body(w);
            throw _Rollback();
          });
        } on _Rollback {
          // esperado: tudo desfeito
        }
      },
    );
  }

  scenario('prazo de devolução é 12h/18h no horário de Brasília', (w) async {
    final deadline = await w.requests.deadline(
      DateTime(2026, 11, 10),
      ReturnPeriod.manha,
    );
    expect(deadline, DateTime.utc(2026, 11, 10, 15));
  });

  scenario('criar: pendente, notifica e bloqueia conflito (RN 4.4)', (
    w,
  ) async {
    final created = await w.service.createRequest(w.ana, w.trip());

    expect(created.status, RequestStatus.pendente);
    expect(created.requester, 'Ana');
    expect(await w.notificationTypes(w.ana), [NotificationType.sent]);

    // Mesma pessoa, mesmo período → 409. Outra pessoa pode.
    await expectLater(w.service.createRequest(w.ana, w.trip()), _apiError(409));
    await w.service.createRequest(w.caio, w.trip());

    // Mais passageiros que o maior veículo da frota → 400.
    await expectLater(
      w.service.createRequest(w.ana, w.trip(days: 5, passengers: 99)),
      _apiError(400),
    );
  });

  scenario('elegíveis por lotação e menor km; aprovar aloca (RN 4.1/4.3)', (
    w,
  ) async {
    final a = await w.service.createRequest(w.ana, w.trip(passengers: 3));
    final c = await w.service.createRequest(w.caio, w.trip(passengers: 3));

    final eligible = await w.service.eligibleVehicles(a.id);
    final mine = eligible.where((v) => v.plate.startsWith('TST9A'));
    expect(mine.map((v) => v.plate), ['TST9A03', 'TST9A01']); // gol, van

    // Uno tem 2 lugares → 409.
    await expectLater(
      w.service.approve(w.bruno, a.id, w.uno.id),
      _apiError(409),
    );

    final approved = await w.service.approve(w.bruno, a.id, w.gol.id);
    expect(approved.status, RequestStatus.aprovada);
    expect(approved.vehicleId, w.gol.id);
    expect(approved.approverName, 'Bruno');
    expect(await w.notificationTypes(w.ana), [
      NotificationType.approved,
      NotificationType.sent,
    ]);

    // O gol está ocupado no período: some dos elegíveis do Caio e não
    // pode ser alocado de novo.
    final forCaio = await w.service.eligibleVehicles(c.id);
    expect(forCaio.map((v) => v.id), isNot(contains(w.gol.id)));
    await expectLater(
      w.service.approve(w.bruno, c.id, w.gol.id),
      _apiError(409),
    );

    // Já decidida: não aprova nem recusa de novo.
    await expectLater(w.service.reject(w.bruno, a.id, 'x'), _apiError(409));
  });

  scenario('editar: motivo mantém aprovação; passageiros voltam p/ pendente', (
    w,
  ) async {
    final r = await w.service.createRequest(w.ana, w.trip());
    await w.service.approve(w.bruno, r.id, w.gol.id);

    final sameApproval = await w.service.updateRequest(
      w.ana,
      r.id,
      const RequestFields(reason: 'Reunião'),
    );
    expect(sameApproval.status, RequestStatus.aprovada);
    expect(sameApproval.reason, 'Reunião');

    final reverted = await w.service.updateRequest(
      w.ana,
      r.id,
      const RequestFields(passengers: 2),
    );
    expect(reverted.status, RequestStatus.pendente);
    expect(reverted.vehicleId, isNull);
    expect(reverted.approverId, isNull);
    expect(
      (await w.notificationTypes(w.ana)).first,
      NotificationType.reverted,
    );

    // Outra pessoa não edita.
    await expectLater(
      w.service.updateRequest(w.caio, r.id, const RequestFields()),
      _apiError(403),
    );
  });

  scenario('retirada e devolução atualizam km e status do veículo', (w) async {
    final r = await w.service.createRequest(w.ana, w.trip());
    await w.service.approve(w.bruno, r.id, w.gol.id);

    await expectLater(
      w.service.checkOut(w.ana, r.id, mileage: 2999),
      _apiError(400),
    );
    final out = await w.service.checkOut(
      w.ana,
      r.id,
      mileage: 3010,
      notes: '  ',
    );
    expect(out.status, RequestStatus.emUso);
    expect(out.departureMileage, 3010);
    expect((await w.vehicles.findById(w.gol.id))!.status, VehicleStatus.emUso);

    // Em uso: o Administrador não muda o status.
    await expectLater(
      w.service.updateVehicle(w.gol.id, {'status': 'emManutencao'}),
      _apiError(409),
    );
    // Não dá para cancelar nem editar depois da retirada.
    await expectLater(w.service.cancelRequest(w.ana, r.id), _apiError(409));

    await expectLater(
      w.service.checkIn(w.ana, r.id, mileage: 3000),
      _apiError(400),
    );
    final done = await w.service.checkIn(
      w.ana,
      r.id,
      mileage: 3170,
      notes: 'Tudo certo',
    );
    expect(done.status, RequestStatus.finalizada);
    expect(done.distanceTravelled, 160);
    expect(done.checkInNotes, 'Tudo certo');

    final gol = (await w.vehicles.findById(w.gol.id))!;
    expect(gol.status, VehicleStatus.disponivel);
    expect(gol.mileage, 3170);
  });

  scenario('veículo em manutenção ou com menos lugares libera reservas', (
    w,
  ) async {
    final a = await w.service.createRequest(w.ana, w.trip(passengers: 4));
    final c = await w.service.createRequest(w.caio, w.trip(days: 6));
    await w.service.approve(w.bruno, a.id, w.van.id);
    await w.service.approve(w.bruno, c.id, w.van.id);

    // 7 → 3 lugares: só a da Ana (4 passageiros) volta.
    final fewer = await w.service.updateVehicle(w.van.id, {'lugares': 3});
    expect(fewer.releasedRequestIds, [a.id]);
    expect(fewer.vehicle.seats, 3);

    // Manutenção: a do Caio também volta, e ele é avisado.
    final maintenance = await w.service.updateVehicle(w.van.id, {
      'status': 'emManutencao',
    });
    expect(maintenance.releasedRequestIds, [c.id]);
    expect(
      (await w.requests.findById(c.id))!.status,
      RequestStatus.pendente,
    );
    expect(
      (await w.notificationTypes(w.caio)).first,
      NotificationType.reverted,
    );
    expect(
      (await w.service.eligibleVehicles(c.id)).map((v) => v.id),
      isNot(contains(w.van.id)),
    );
  });

  scenario('cancelar e recusar', (w) async {
    final a = await w.service.createRequest(w.ana, w.trip());
    final canceled = await w.service.cancelRequest(w.ana, a.id);
    expect(canceled.status, RequestStatus.cancelada);

    // Cancelada não ocupa mais a agenda: pode pedir de novo no mesmo horário.
    final again = await w.service.createRequest(w.ana, w.trip());
    final rejected = await w.service.reject(w.bruno, again.id, 'Sem verba');
    expect(rejected.status, RequestStatus.recusada);
    expect(rejected.rejectionReason, 'Sem verba');
    expect(rejected.approverName, 'Bruno');

    await w.notifications.markAllRead(w.ana.id);
    final all = await w.notifications.listFor(w.ana.id);
    expect(all.every((n) => n.read), isTrue);
  });

  scenario('excluir: só veículo e usuário sem histórico', (w) async {
    // Com solicitação: não pode.
    final request = await w.service.createRequest(w.ana, w.trip());
    await w.service.approve(w.bruno, request.id, w.gol.id);
    expect(await w.vehicles.hasHistory(w.gol.id), isTrue);
    expect(await w.users.hasHistory(w.ana.id), isTrue);
    expect(await w.users.hasHistory(w.bruno.id), isTrue); // aprovou

    // Sem solicitação: exclui (o usuário leva notificações e aparelhos).
    expect(await w.vehicles.hasHistory(w.uno.id), isFalse);
    expect(await w.vehicles.delete(w.uno.id), isTrue);
    expect(await w.vehicles.findById(w.uno.id), isNull);
    expect(await w.vehicles.delete(w.uno.id), isFalse);

    await DispositivosRepository(w.tx).register(w.caio.id, 'tok-caio');
    await w.notifications.insert(
      userId: w.caio.id,
      requestId: request.id,
      type: NotificationType.reverted,
      destination: 'Macaé',
      message: 'Teste',
    );
    expect(await w.users.hasHistory(w.caio.id), isFalse);
    await w.users.delete(w.caio.id);
    expect(await w.users.findById(w.caio.id), isNull);
  });

  scenario('placa repetida vira erro de unicidade', (w) async {
    await expectLater(
      w.service.createVehicle(
        VehicleModel(
          id: 0,
          plate: w.gol.plate,
          chassis: 'OUTRO',
          model: 'X',
          color: 'Y',
          year: 2020,
          seats: 5,
          mileage: 0,
          licensingExpiry: DateTime(2027),
          insuranceExpiry: DateTime(2027),
        ),
      ),
      throwsA(
        isA<ServerException>().having(
          (e) => e.constraintName,
          'constraint',
          'veiculos_placa_key',
        ),
      ),
    );
  });

  scenario('relatório: viagem devolvida atrasada entra nos rankings', (
    w,
  ) async {
    // Viagem de 5 dias atrás (gravada direto: o serviço não aceita saída
    // no passado), devolvida no dia seguinte, depois do prazo.
    await w.tx.execute(
      Sql.named('''
        INSERT INTO solicitacoes (
          solicitante_id, motivo, destino, passageiros, saida, data_retorno,
          periodo_retorno, prazo_retorno, status, veiculo_id, km_saida,
          km_retorno, check_out_em, check_in_em, aprovador_id, decidido_em,
          criado_em
        ) VALUES (
          @ana, 'Visita', ' macaé ', 1, now() - interval '5 days',
          (now() - interval '5 days')::date, 'tarde',
          now() - interval '5 days' + interval '8 hours', 'finalizada', @gol,
          3000, 3120, now() - interval '5 days', now() - interval '4 days',
          @bruno, now() - interval '6 days', now() - interval '7 days'
        )'''),
      parameters: {'ana': w.ana.id, 'gol': w.gol.id, 'bruno': w.bruno.id},
    );
    // Revisão a 500 km: alerta "vencendo".
    await w.vehicles.update(w.van.id, {'proxima_revisao_km': 5500});

    final report = await buildFleetReport(
      reports: RelatoriosRepository(w.tx),
      vehicles: w.vehicles,
      users: w.users,
      days: 30,
    );

    final ana = report.users.firstWhere((u) => u.id == w.ana.id);
    expect((ana.trips, ana.km, ana.lateReturns), (1, 120, 1));
    final gol = report.vehicles.firstWhere((v) => v.id == w.gol.id);
    expect((gol.trips, gol.km), (1, 120));
    // Veículo sem viagem aparece no fim (ocioso).
    expect(report.vehicles.any((v) => v.id == w.uno.id && v.trips == 0), true);
    expect(report.trend.fold(0, (sum, t) => sum + t.trips), report.trips);
    expect(report.lateReturns, greaterThanOrEqualTo(1));
    final bruno = report.approvers.firstWhere((a) => a.id == w.bruno.id);
    expect((bruno.approved, bruno.rejected), (1, 0));
    expect(
      report.alerts.where(
        (a) => a.kind == AlertKind.revisao && a.title.contains('TST9A01'),
      ),
      hasLength(1),
    );
    // Ida e volta pelo JSON da rota.
    expect(FleetReport.fromJson(report.toJson()).toJson(), report.toJson());
  });

  // -------------------------------------------------------------------
  // Margem de um dia, falha na retirada e reservas em risco (2026-11-09)
  // -------------------------------------------------------------------

  /// Altera datas direto no banco (o serviço não deixa criar no passado).
  /// Os valores são expressões SQL fixas dos próprios testes.
  Future<void> moveTo(
    _World w,
    int id, {
    required String saida,
    String? prazo,
    String? dataRetorno,
  }) => w.tx.execute(
    Sql.named('''
      UPDATE solicitacoes SET saida = $saida
        ${prazo == null ? '' : ', prazo_retorno = $prazo'}
        ${dataRetorno == null ? '' : ', data_retorno = $dataRetorno'}
      WHERE id = @id'''),
    parameters: {'id': id},
  );

  const tenMinutesAgo = "now() - interval '10 minutes'";

  scenario('margem: veículo só fica livre à meia-noite seguinte ao retorno', (
    w,
  ) async {
    // Ana volta no dia D (até 18h) com o gol.
    final a = await w.service.createRequest(w.ana, w.trip());
    await w.service.approve(w.bruno, a.id, w.gol.id);
    final period = await w.requests.periodOf(a.id);
    // D+1 00h em Brasília = 03h UTC.
    final d = w.trip().returnDate!;
    expect(period.vehicleEnd, DateTime.utc(d.year, d.month, d.day + 1, 3));

    // Caio sai no dia D às 19h: antes da margem → gol não serve.
    final sameDay = await w.service.createRequest(
      w.caio,
      RequestFields(
        reason: 'Visita',
        destination: 'Niterói',
        passengers: 1,
        departure: DateTime.utc(d.year, d.month, d.day, 22),
        returnDate: DateTime(d.year, d.month, d.day + 1),
        returnPeriod: ReturnPeriod.tarde,
      ),
    );
    final eligible = await w.service.eligibleVehicles(sameDay.id);
    expect(eligible.map((v) => v.id), isNot(contains(w.gol.id)));
    await expectLater(
      w.service.approve(w.bruno, sameDay.id, w.gol.id),
      _apiError(409),
    );
    // O banco também recusa (EXCLUDE com veiculo_livre_em).
    await w.tx.execute('SAVEPOINT margem');
    await expectLater(
      w.tx.execute(
        Sql.named('''
          UPDATE solicitacoes SET status = 'aprovada', veiculo_id = @v,
                 aprovador_id = @b, decidido_em = now()
          WHERE id = @id'''),
        parameters: {'v': w.gol.id, 'b': w.bruno.id, 'id': sameDay.id},
      ),
      throwsA(isA<ServerException>().having((e) => e.code, 'code', '23P01')),
    );
    await w.tx.execute('ROLLBACK TO SAVEPOINT margem');
  });

  scenario('margem: no dia seguinte ao retorno o veículo já serve', (
    w,
  ) async {
    final a = await w.service.createRequest(w.ana, w.trip());
    await w.service.approve(w.bruno, a.id, w.gol.id);

    final next = await w.service.createRequest(w.caio, w.trip(days: 4));
    final eligible = await w.service.eligibleVehicles(next.id);
    expect(eligible.map((v) => v.id), contains(w.gol.id));
    final approved = await w.service.approve(w.bruno, next.id, w.gol.id);
    expect(approved.vehicleId, w.gol.id);
  });

  scenario(
    'falha na retirada → novo veículo: pendente, urgente e avisa aprovadores',
    (w) async {
      final a = await w.service.createRequest(w.ana, w.trip());
      await w.service.approve(w.bruno, a.id, w.gol.id);

      // Antes do dia da saída → 409.
      await expectLater(
        w.service.reportPickupFailure(
          w.ana,
          a.id,
          reason: PickupFailureReason.naoDevolvido,
          action: PickupFailureAction.novoVeiculo,
        ),
        _apiError(409),
      );
      // Só o dono.
      await moveTo(w, a.id, saida: tenMinutesAgo);
      await expectLater(
        w.service.reportPickupFailure(
          w.caio,
          a.id,
          reason: PickupFailureReason.naoDevolvido,
          action: PickupFailureAction.novoVeiculo,
        ),
        _apiError(403),
      );

      final failed = await w.service.reportPickupFailure(
        w.ana,
        a.id,
        reason: PickupFailureReason.problemaVeiculo,
        action: PickupFailureAction.novoVeiculo,
        notes: 'Pneu furado',
      );
      expect(failed.status, RequestStatus.pendente);
      expect(failed.vehicleId, isNull);
      expect(failed.approverId, isNull);
      expect(failed.needsReallocation, isTrue);
      expect(failed.pickupFailedVehicleId, w.gol.id);
      expect(failed.pickupFailureReason, PickupFailureReason.problemaVeiculo);
      expect(failed.pickupFailureNotes, 'Pneu furado');
      expect(
        await w.notificationTypes(w.bruno),
        contains(NotificationType.pickupFailed),
      );
      expect(
        (await w.notificationTypes(w.ana)).first,
        NotificationType.reverted,
      );

      // Aparece em "Precisa de atenção".
      final alerts = await RelatoriosRepository(w.tx).requestAlerts();
      expect(
        alerts.where(
          (x) =>
              x.kind == AlertKind.retiradaFalhou &&
              x.title.startsWith('Ana') &&
              x.message.contains('TST9A03'),
        ),
        hasLength(1),
      );

      // O gol (que falhou) não é oferecido nem aceito; outro veículo, sim.
      final eligible = await w.service.eligibleVehicles(a.id);
      expect(eligible.map((v) => v.id), isNot(contains(w.gol.id)));
      await expectLater(
        w.service.approve(w.bruno, a.id, w.gol.id),
        _apiError(409),
      );
      final realloc = await w.service.approve(w.bruno, a.id, w.van.id);
      expect(realloc.status, RequestStatus.aprovada);
      expect(realloc.vehicleId, w.van.id);
      // O histórico da falha continua registrado.
      expect(realloc.pickupFailedVehicleId, w.gol.id);
    },
  );

  scenario('falha na retirada → reagendar: cancela e libera a agenda', (
    w,
  ) async {
    final a = await w.service.createRequest(w.ana, w.trip());
    await w.service.approve(w.bruno, a.id, w.gol.id);
    await moveTo(w, a.id, saida: tenMinutesAgo);

    // "Outro" sem observação: a rota recusa antes; o banco também.
    await expectLater(
      w.service.reportPickupFailure(
        w.ana,
        a.id,
        reason: PickupFailureReason.outro,
        action: PickupFailureAction.reagendar,
      ),
      throwsA(isA<ServerException>()),
    );

    final canceled = await w.service.reportPickupFailure(
      w.ana,
      a.id,
      reason: PickupFailureReason.naoDevolvido,
      action: PickupFailureAction.reagendar,
    );
    expect(canceled.status, RequestStatus.cancelada);
    expect(canceled.vehicleId, isNull);
    expect(canceled.approverId, isNull);
    expect(canceled.pickupFailedVehicleId, w.gol.id);
    expect((await w.notificationTypes(w.ana)).first, NotificationType.canceled);
    expect(
      await w.notificationTypes(w.bruno),
      isNot(contains(NotificationType.pickupFailed)),
    );

    // Pode pedir de novo no mesmo período (RN 4.4 liberada).
    final again = await w.service.createRequest(w.ana, w.trip());
    expect(again.status, RequestStatus.pendente);
  });

  scenario('reserva em risco: avisa uma vez quando o veículo está atrasado', (
    w,
  ) async {
    // Caio tem o gol reservado para daqui a 2 dias.
    final c = await w.service.createRequest(w.caio, w.trip(days: 2));
    await w.service.approve(w.bruno, c.id, w.gol.id);

    // Ana está com o gol e deveria ter devolvido há 1 hora (hoje).
    final a = await w.service.createRequest(w.ana, w.trip(days: 5));
    await w.service.approve(w.bruno, a.id, w.gol.id);
    // Retirou dentro do prazo; depois o prazo passou sem devolução.
    await moveTo(
      w,
      a.id,
      saida: "now() - interval '5 hours'",
      prazo: "now() + interval '1 hour'",
      dataRetorno: "(now() AT TIME ZONE 'America/Sao_Paulo')::date",
    );
    await w.service.checkOut(w.ana, a.id, mileage: 3000);
    await moveTo(
      w,
      a.id,
      saida: "now() - interval '5 hours'",
      prazo: "now() - interval '1 hour'",
      dataRetorno: "(now() AT TIME ZONE 'America/Sao_Paulo')::date",
    );

    expect(await w.service.alertReservationsAtRisk(), greaterThanOrEqualTo(1));
    expect((await w.notificationTypes(w.caio)).first, NotificationType.atRisk);
    expect(
      await w.notificationTypes(w.bruno),
      contains(NotificationType.atRisk),
    );
    final alerts = await RelatoriosRepository(w.tx).requestAlerts();
    expect(
      alerts.where(
        (x) => x.kind == AlertKind.reservaEmRisco && x.message.contains('Caio'),
      ),
      hasLength(1),
    );

    // Segunda chamada não repete o aviso.
    final before = (await w.notificationTypes(w.caio)).length;
    await w.service.alertReservationsAtRisk();
    expect(await w.notificationTypes(w.caio), hasLength(before));

    // Atrasada: o gol some dos elegíveis de qualquer período.
    final later = await w.service.createRequest(w.caio, w.trip(days: 9));
    final eligible = await w.service.eligibleVehicles(later.id);
    expect(eligible.map((v) => v.id), isNot(contains(w.gol.id)));
  });

  // -------------------------------------------------------------------
  // Revisão final (2026-11-17): cancelamentos
  // -------------------------------------------------------------------

  const yesterday = "now() - interval '1 day'";

  scenario('cancelar aprovada: libera o veículo e avisa os Aprovadores', (
    w,
  ) async {
    final a = await w.service.createRequest(w.ana, w.trip());
    await w.service.approve(w.bruno, a.id, w.gol.id);

    final canceled = await w.service.cancelRequest(w.ana, a.id);
    expect(canceled.status, RequestStatus.cancelada);
    expect(canceled.vehicleId, isNull);
    expect(canceled.approverId, isNull);
    expect(canceled.cancellationReason, isNull); // foi o solicitante
    expect((await w.notificationTypes(w.ana)).first, NotificationType.canceled);
    expect(
      (await w.notificationTypes(w.bruno)).first,
      NotificationType.canceled,
    );

    // O gol volta a servir para outra pessoa no mesmo período.
    final c = await w.service.createRequest(w.caio, w.trip());
    final approved = await w.service.approve(w.bruno, c.id, w.gol.id);
    expect(approved.vehicleId, w.gol.id);

    // Em uso não cancela.
    final d = await w.service.createRequest(w.ana, w.trip(days: 8));
    await w.service.approve(w.bruno, d.id, w.van.id);
    await moveTo(w, d.id, saida: tenMinutesAgo);
    await w.service.checkOut(w.ana, d.id, mileage: 5000);
    await expectLater(w.service.cancelRequest(w.ana, d.id), _apiError(409));
  });

  scenario('pendente sem aprovação até o fim do dia da saída é cancelada', (
    w,
  ) async {
    final old = await w.service.createRequest(w.ana, w.trip());
    await moveTo(w, old.id, saida: yesterday);
    // Saída hoje, há 10 min: ainda dá para aprovar.
    final today = await w.service.createRequest(w.caio, w.trip());
    await moveTo(w, today.id, saida: tenMinutesAgo);

    await expectLater(
      w.service.approve(w.bruno, old.id, w.gol.id),
      _apiError(409),
    );

    await w.service.expireStaleRequests();
    final expired = (await w.requests.findById(old.id))!;
    expect(expired.status, RequestStatus.cancelada);
    expect(expired.cancellationReason, CancellationReason.semAprovacao);
    expect((await w.notificationTypes(w.ana)).first, NotificationType.canceled);

    final stillPending = (await w.requests.findById(today.id))!;
    expect(stillPending.status, RequestStatus.pendente);
    final approved = await w.service.approve(w.bruno, today.id, w.gol.id);
    expect(approved.status, RequestStatus.aprovada);
  });

  scenario('aprovada não retirada até o fim do dia da saída é cancelada e '
      'libera o veículo', (w) async {
    final a = await w.service.createRequest(w.ana, w.trip());
    await w.service.approve(w.bruno, a.id, w.gol.id);
    await moveTo(w, a.id, saida: yesterday);

    // Retirada fora do prazo é recusada.
    await expectLater(
      w.service.checkOut(w.ana, a.id, mileage: 3000),
      _apiError(409),
    );

    await w.service.expireStaleRequests();
    final expired = (await w.requests.findById(a.id))!;
    expect(expired.status, RequestStatus.cancelada);
    expect(expired.cancellationReason, CancellationReason.naoRetirada);
    expect(expired.vehicleId, isNull);
    expect((await w.notificationTypes(w.ana)).first, NotificationType.canceled);
    expect(
      (await w.notificationTypes(w.bruno)).first,
      NotificationType.canceled,
    );

    // Depois de "não consegui retirar", o prazo vai até a devolução: o
    // Aprovador ainda pode realocar no dia seguinte.
    final c = await w.service.createRequest(w.caio, w.trip(days: 4));
    await w.service.approve(w.bruno, c.id, w.gol.id);
    await moveTo(w, c.id, saida: tenMinutesAgo);
    await w.service.reportPickupFailure(
      w.caio,
      c.id,
      reason: PickupFailureReason.problemaVeiculo,
      action: PickupFailureAction.novoVeiculo,
    );
    await moveTo(w, c.id, saida: yesterday);
    await w.service.expireStaleRequests();
    expect(
      (await w.requests.findById(c.id))!.status,
      RequestStatus.pendente,
    );
    final realloc = await w.service.approve(w.bruno, c.id, w.van.id);
    expect(realloc.status, RequestStatus.aprovada);
  });

  scenario('desativar usuário cancela as solicitações dele; com veículo em '
      'uso é recusado', (w) async {
    final approved = await w.service.createRequest(w.ana, w.trip());
    await w.service.approve(w.bruno, approved.id, w.gol.id);
    final pending = await w.service.createRequest(w.ana, w.trip(days: 6));

    final updated = await w.service.updateUserClosingRequests(
      w.ana.id,
      {'ativo': false},
      CancellationReason.usuarioDesativado,
    );
    expect(updated.active, isFalse);
    for (final id in [approved.id, pending.id]) {
      final r = (await w.requests.findById(id))!;
      expect(r.status, RequestStatus.cancelada);
      expect(r.cancellationReason, CancellationReason.usuarioDesativado);
      expect(r.vehicleId, isNull);
    }
    // Só a aprovada avisa os Aprovadores (o veículo foi liberado).
    expect(
      (await w.notificationTypes(w.bruno)).first,
      NotificationType.canceled,
    );

    // Caio está com o gol na rua: não pode ser desativado.
    final c = await w.service.createRequest(w.caio, w.trip(days: 9));
    await w.service.approve(w.bruno, c.id, w.gol.id);
    await moveTo(w, c.id, saida: tenMinutesAgo);
    await w.service.checkOut(w.caio, c.id, mileage: 3000);
    await expectLater(
      w.service.updateUserClosingRequests(
        w.caio.id,
        {'ativo': false},
        CancellationReason.usuarioDesativado,
      ),
      _apiError(409),
    );
    expect((await w.users.findById(w.caio.id))!.active, isTrue);
  });

  // -------------------------------------------------------------------
  // Push no celular (fila em notificacoes.push_enviado_em)
  // -------------------------------------------------------------------

  scenario('push: envia a notificação nova uma vez; token inválido é '
      'apagado; falha temporária volta para a fila', (w) async {
    final devices = DispositivosRepository(w.tx);
    await devices.register(w.ana.id, 'token-bom');
    await devices.register(w.ana.id, 'token-velho');
    final gateway = _FakeGateway({'token-velho': PushResult.invalidToken});
    final push = PushDispatcher(w.tx, gateway);

    // Só nas notificações deste cenário (o banco real pode ter outras).
    bool mine(_Sent s) => s.token.startsWith('token-');

    await w.service.createRequest(w.ana, w.trip());
    await push.flush();
    final sent = gateway.sent.where(mine).toList();
    expect(sent.map((s) => s.token), ['token-bom', 'token-velho']);
    expect(sent.first.title, 'Solicitação enviada');
    expect(sent.first.body, startsWith('Macaé: '));
    expect(sent.first.data['type'], 'sent');
    // O token velho foi apagado; o bom continua.
    expect((await devices.tokensOf([w.ana.id]))[w.ana.id], ['token-bom']);

    // Já enviada: não sai de novo.
    gateway.sent.clear();
    await push.flush();
    expect(gateway.sent.where(mine), isEmpty);

    // FCM fora do ar: volta para a fila e sai na próxima tentativa.
    gateway.results['token-bom'] = PushResult.failed;
    final r = await w.service.createRequest(w.ana, w.trip(days: 6));
    await push.flush();
    final pending = await w.tx.execute(
      Sql.named(
        'SELECT push_enviado_em IS NULL, push_tentativas FROM notificacoes '
        'WHERE solicitacao_id = @id',
      ),
      parameters: {'id': r.id},
    );
    expect(pending.single, [true, 1]);

    gateway.results.remove('token-bom');
    gateway.sent.clear();
    await push.flush();
    expect(gateway.sent.where(mine), hasLength(1));
  });
}

class _Sent {
  _Sent(this.token, this.title, this.body, this.data);
  final String token;
  final String title;
  final String body;
  final Map<String, String> data;
}

class _FakeGateway implements PushGateway {
  _FakeGateway(this.results);

  final Map<String, PushResult> results;
  final sent = <_Sent>[];

  @override
  Future<PushResult> send({
    required String token,
    required String title,
    required String body,
    required Map<String, String> data,
  }) async {
    final result = results[token] ?? PushResult.sent;
    if (result != PushResult.failed) sent.add(_Sent(token, title, body, data));
    return result;
  }
}
