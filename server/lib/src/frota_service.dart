import 'dart:io';

import 'package:frota_core/frota_core.dart';
import 'package:frota_server/src/api_exception.dart';
import 'package:frota_server/src/notificacoes_repository.dart';
import 'package:frota_server/src/request_input.dart';
import 'package:frota_server/src/solicitacoes_repository.dart';
import 'package:frota_server/src/veiculos_repository.dart';
import 'package:postgres/postgres.dart';

/// Roda o alerta de reservas em risco sem deixar uma falha dele derrubar a
/// listagem que o chamou (o alerta é um "extra" das rotas de leitura).
Future<void> alertReservationsAtRiskQuietly(FrotaService frota) async {
  try {
    await frota.alertReservationsAtRisk();
  } on Object catch (e) {
    stderr.writeln('Falha ao verificar reservas em risco: $e');
  }
}

/// Repositórios ligados a uma mesma transação.
class _Tx {
  _Tx(Session tx)
    : requests = SolicitacoesRepository(tx),
      vehicles = VeiculosRepository(tx),
      notifications = NotificacoesRepository(tx);

  final SolicitacoesRepository requests;
  final VeiculosRepository vehicles;
  final NotificacoesRepository notifications;

  /// Avisa o solicitante (RF 3.3.7).
  Future<void> notify(
    int userId,
    int requestId,
    String destination,
    NotificationType type,
    String message,
  ) => notifications.insert(
    userId: userId,
    requestId: requestId,
    type: type,
    destination: destination,
    message: message,
  );

  /// Avisa todos os Aprovadores ativos.
  Future<void> notifyApprovers(
    int requestId,
    String destination,
    NotificationType type,
    String message,
  ) => notifications.insertForApprovers(
    requestId: requestId,
    type: type,
    destination: destination,
    message: message,
  );
}

/// Regras de negócio de solicitações e veículos (seção 4 do documento).
///
/// Cada operação roda numa transação: a mudança, os efeitos colaterais
/// (status/km do veículo, reservas liberadas) e as notificações são gravados
/// juntos ou nada é gravado. As linhas alteradas são travadas (`FOR UPDATE`)
/// e o banco ainda recusa conflitos de agenda (`EXCLUDE`), então dois
/// aprovadores agindo ao mesmo tempo não alocam o mesmo veículo (RNF 6.5).
///
/// Quem pode chamar cada operação (perfil) é conferido nas rotas; aqui
/// ficam as regras que dependem do estado da solicitação e do veículo.
class FrotaService {
  FrotaService(this._db, {this._afterCommit});

  final SessionExecutor _db;

  /// Chamado depois de cada transação gravada (envio de push).
  final void Function()? _afterCommit;

  /// Folga para "saída no passado": o usuário pode demorar a enviar o
  /// formulário depois de escolher o horário.
  static const _pastTolerance = Duration(minutes: 10);

  Future<T> _tx<T>(Future<T> Function(_Tx tx) fn) async {
    final result = await _db.runTx((session) => fn(_Tx(session)));
    _afterCommit?.call();
    return result;
  }

  // -------------------------------------------------------------------
  // Solicitações
  // -------------------------------------------------------------------

  /// Nova solicitação (RF 3.3.1). Só o perfil Padrão (conferido na rota).
  Future<RequestModel> createRequest(UserModel me, RequestFields f) {
    final departure = f.departure!;
    final returnDate = f.returnDate!;
    final period = f.returnPeriod!;

    _ensureValidCnh(me, returnDate);
    _ensureNotPast(departure);

    return _tx((tx) async {
      final deadline = await tx.requests.deadline(returnDate, period);
      _ensureReturnAfterDeparture(departure, deadline);
      await _ensurePassengersFit(tx, f.passengers!);
      await _ensureNoUserConflict(tx, me.id, departure, deadline);

      final id = await tx.requests.insert(
        requesterId: me.id,
        reason: f.reason!,
        destination: f.destination!,
        passengers: f.passengers!,
        departure: departure,
        returnDate: returnDate,
        returnPeriod: period,
        deadline: deadline,
      );
      await tx.notify(
        me.id,
        id,
        f.destination!,
        NotificationType.sent,
        'Sua solicitação foi enviada e aguarda aprovação.',
      );
      return (await tx.requests.findById(id))!;
    });
  }

  /// Edição pelo solicitante, só antes da retirada (RF 3.3.3).
  ///
  /// Se já estava aprovada e mudaram datas, período ou passageiros, volta
  /// para Pendente e perde o veículo. Motivo e destino mantêm a aprovação.
  Future<RequestModel> updateRequest(
    UserModel me,
    int id,
    RequestFields f,
  ) => _tx((tx) async {
    final current = await _ownRequest(tx, me, id);
    if (!current.canEdit) {
      throw const ApiException.conflict(
        'Só é possível alterar a solicitação antes da retirada do veículo.',
      );
    }

    final departure = f.departure ?? current.departure!.toUtc();
    final returnDate = f.returnDate ?? current.returnDate!;
    final period = f.returnPeriod ?? current.returnPeriod!;
    final passengers = f.passengers ?? current.passengers;

    final departureChanged = !departure.isAtSameMomentAs(current.departure!);
    final scheduleChanged =
        departureChanged ||
        formatDate(returnDate) != formatDate(current.returnDate!) ||
        period != current.returnPeriod;
    final passengersChanged = passengers != current.passengers;

    final changes = <String, Object?>{
      'motivo': ?f.reason,
      'destino': ?f.destination,
    };

    if (scheduleChanged) {
      if (departureChanged) _ensureNotPast(departure);
      _ensureValidCnh(me, returnDate);
      final deadline = await tx.requests.deadline(returnDate, period);
      _ensureReturnAfterDeparture(departure, deadline);
      await _ensureNoUserConflict(tx, me.id, departure, deadline, ignore: id);
      changes.addAll({
        'saida': departure,
        'data_retorno': returnDate,
        'periodo_retorno': period,
        'prazo_retorno': deadline,
      });
    }
    if (passengersChanged) {
      await _ensurePassengersFit(tx, passengers);
      changes['passageiros'] = passengers;
    }

    final reverted =
        current.status == RequestStatus.aprovada &&
        (scheduleChanged || passengersChanged);
    if (reverted) changes.addAll(_backToPending);

    await tx.requests.update(id, changes);
    if (reverted) {
      await tx.notify(
        me.id,
        id,
        f.destination ?? current.destination,
        NotificationType.reverted,
        'Solicitação alterada. Aguardando nova aprovação.',
      );
    }
    return (await tx.requests.findById(id))!;
  });

  /// Cancelamento pelo solicitante, só enquanto Pendente (RF 3.3.4).
  Future<RequestModel> cancelRequest(UserModel me, int id) => _tx((tx) async {
    final current = await _ownRequest(tx, me, id);
    if (current.status != RequestStatus.pendente) {
      throw const ApiException.conflict(
        'Só solicitações pendentes podem ser canceladas.',
      );
    }

    await tx.requests.update(id, {'status': RequestStatus.cancelada});
    await tx.notify(
      me.id,
      id,
      current.destination,
      NotificationType.canceled,
      'Você cancelou esta solicitação.',
    );
    return (await tx.requests.findById(id))!;
  });

  /// Aprovação com alocação do veículo (RF 3.4.2, RN 4.1 e 4.3).
  /// Não muda o status do veículo: a reserva existe só na agenda.
  Future<RequestModel> approve(UserModel me, int id, int vehicleId) =>
      _tx((tx) async {
        final request = await _pendingRequest(tx, id);

        final vehicle = await tx.vehicles.findById(vehicleId, forUpdate: true);
        if (vehicle == null) {
          throw const ApiException.badRequest(
            'Veículo não encontrado.',
            fields: {'vehicleId': 'Veículo não encontrado.'},
          );
        }
        if (!vehicle.status.canBeScheduled) {
          throw ApiException.conflict(
            'O veículo está ${vehicle.status.label.toLowerCase()} '
            'e não pode ser agendado.',
          );
        }
        if (vehicle.seats < request.passengers) {
          throw ApiException.conflict(
            'O veículo tem ${vehicle.seats} lugar(es) e a solicitação '
            'precisa de ${request.passengers}.',
          );
        }
        if (vehicleId == request.pickupFailedVehicleId) {
          throw const ApiException.conflict(
            'O solicitante não conseguiu retirar este veículo. '
            'Escolha outro.',
          );
        }

        // Margem de um dia: o veículo fica ocupado até a meia-noite
        // seguinte ao retorno (vehicleEnd), não só até o prazo.
        final period = await tx.requests.periodOf(id);
        final free = await tx.requests.vehicleIsFree(
          vehicleId: vehicleId,
          start: period.start,
          end: period.vehicleEnd,
          ignoreRequestId: id,
        );
        if (!free) {
          throw const ApiException.conflict(
            'O veículo já está reservado neste período. Escolha outro.',
          );
        }

        await tx.requests.update(id, {
          'status': RequestStatus.aprovada,
          'veiculo_id': vehicleId,
          'justificativa_recusa': null,
          'aprovador_id': me.id,
          'decidido_em': DateTime.now(),
          'alerta_risco_em': null,
        });
        await tx.notify(
          request.requesterId,
          id,
          request.destination,
          NotificationType.approved,
          'Veículo alocado: ${vehicle.model} · ${vehicle.plate}.',
        );
        return (await tx.requests.findById(id))!;
      });

  /// Recusa com justificativa obrigatória (RF 3.4.3, RN 4.7).
  Future<RequestModel> reject(UserModel me, int id, String justification) =>
      _tx((tx) async {
        final request = await _pendingRequest(tx, id);

        await tx.requests.update(id, {
          'status': RequestStatus.recusada,
          'veiculo_id': null,
          'justificativa_recusa': justification,
          'aprovador_id': me.id,
          'decidido_em': DateTime.now(),
        });
        await tx.notify(
          request.requesterId,
          id,
          request.destination,
          NotificationType.rejected,
          'Motivo: $justification',
        );
        return (await tx.requests.findById(id))!;
      });

  /// Retirada do veículo (check-out, RF 3.3.5). A km informada não pode ser
  /// menor que a atual do veículo e passa a ser a km dele.
  Future<RequestModel> checkOut(
    UserModel me,
    int id, {
    required int mileage,
    String? notes,
  }) => _tx((tx) async {
    final request = await _ownRequest(tx, me, id);
    if (request.status != RequestStatus.aprovada) {
      throw const ApiException.conflict(
        'A retirada só pode ser registrada em solicitação aprovada.',
      );
    }

    final vehicle = (await tx.vehicles.findById(
      request.vehicleId!,
      forUpdate: true,
    ))!;
    if (vehicle.status != VehicleStatus.disponivel) {
      throw ApiException.conflict(
        vehicle.status == VehicleStatus.emUso
            ? 'O veículo ainda não foi devolvido da viagem anterior.'
            : 'O veículo está ${vehicle.status.label.toLowerCase()}. '
                  'Procure o Aprovador.',
      );
    }
    if (mileage < vehicle.mileage) {
      throw ApiException.badRequest(
        'Quilometragem inválida.',
        fields: {
          'mileage':
              'Não pode ser menor que a atual do veículo '
              '(${vehicle.mileage} km).',
        },
      );
    }

    await tx.requests.update(id, {
      'status': RequestStatus.emUso,
      'km_saida': mileage,
      'check_out_em': DateTime.now(),
      'obs_check_out': notes,
    });
    await tx.vehicles.update(vehicle.id, {
      'status': VehicleStatus.emUso.name,
      'quilometragem': mileage,
    });
    return (await tx.requests.findById(id))!;
  });

  /// O solicitante não conseguiu retirar o veículo alocado (pedido do
  /// professor, 2026-11-09). Só em solicitação aprovada e a partir do dia
  /// da saída. Registra motivo, observação e o veículo, e:
  /// - [PickupFailureAction.novoVeiculo]: volta a Pendente (sem veículo e
  ///   sem decisão) e todos os Aprovadores são avisados na hora;
  /// - [PickupFailureAction.reagendar]: a solicitação é cancelada (o app
  ///   leva o solicitante para uma nova, já preenchida).
  Future<RequestModel> reportPickupFailure(
    UserModel me,
    int id, {
    required PickupFailureReason reason,
    required PickupFailureAction action,
    String? notes,
  }) => _tx((tx) async {
    final request = await _ownRequest(tx, me, id);
    if (request.status != RequestStatus.aprovada) {
      throw const ApiException.conflict(
        'Só é possível informar problema em solicitação aprovada.',
      );
    }
    if (!await tx.requests.departureDayReached(id)) {
      throw const ApiException.conflict(
        'O problema só pode ser informado a partir do dia da saída.',
      );
    }

    final vehicle = (await tx.vehicles.findById(request.vehicleId!))!;
    final vehicleName = '${vehicle.model} · ${vehicle.plate}';
    final failure = <String, Object?>{
      'falha_retirada_em': DateTime.now(),
      'falha_retirada_motivo': reason,
      'falha_retirada_obs': notes,
      'falha_retirada_veiculo_id': vehicle.id,
    };
    final why = notes == null ? reason.label : '${reason.label}: $notes';

    switch (action) {
      case PickupFailureAction.novoVeiculo:
        await tx.requests.update(id, {
          ...failure,
          ..._backToPending,
        });
        await tx.notifyApprovers(
          id,
          request.destination,
          NotificationType.pickupFailed,
          '${request.requester} não conseguiu retirar o $vehicleName '
          '($why). Aloque outro veículo.',
        );
        await tx.notify(
          me.id,
          id,
          request.destination,
          NotificationType.reverted,
          'Pedido de outro veículo enviado aos Aprovadores.',
        );
      case PickupFailureAction.reagendar:
        await tx.requests.update(id, {
          ...failure,
          ..._backToPending,
          'status': RequestStatus.cancelada,
        });
        await tx.notify(
          me.id,
          id,
          request.destination,
          NotificationType.canceled,
          'Solicitação encerrada para reagendamento ($why).',
        );
    }
    return (await tx.requests.findById(id))!;
  });

  /// Reservas em risco: avisa o solicitante e os Aprovadores quando o
  /// veículo de uma reserva aprovada que sai em até 72 h ainda está numa
  /// viagem com a devolução atrasada. Cada reserva é avisada uma vez só.
  ///
  /// Não há tarefa agendada: é chamado quando o app busca notificações ou
  /// solicitações (o app faz isso ao abrir e ao "puxar para atualizar").
  /// Devolve quantas reservas foram marcadas.
  Future<int> alertReservationsAtRisk() => _tx((tx) async {
    final atRisk = await tx.requests.markAtRisk();
    for (final r in atRisk) {
      final when = r.departure;
      await tx.notify(
        r.requesterId,
        r.id,
        r.destination,
        NotificationType.atRisk,
        'O ${r.vehicle} ainda não voltou da viagem anterior. Sua saída '
        '($when) pode ser afetada.',
      );
      await tx.notifyApprovers(
        r.id,
        r.destination,
        NotificationType.atRisk,
        'O ${r.vehicle} está com a devolução atrasada e tem reserva com '
        'saída em $when.',
      );
    }
    return atRisk.length;
  });

  /// Devolução do veículo (check-in, RF 3.3.6). A km de retorno não pode ser
  /// menor que a de saída (RN 4.8); o veículo volta a Disponível com ela.
  Future<RequestModel> checkIn(
    UserModel me,
    int id, {
    required int mileage,
    String? notes,
  }) => _tx((tx) async {
    final request = await _ownRequest(tx, me, id);
    if (request.status != RequestStatus.emUso) {
      throw const ApiException.conflict(
        'A devolução só pode ser registrada depois da retirada.',
      );
    }

    final minimum = request.departureMileage ?? 0;
    if (mileage < minimum) {
      throw ApiException.badRequest(
        'Quilometragem inválida.',
        fields: {
          'mileage': 'Não pode ser menor que a de saída ($minimum km).',
        },
      );
    }

    await tx.vehicles.findById(request.vehicleId!, forUpdate: true);
    await tx.requests.update(id, {
      'status': RequestStatus.finalizada,
      'km_retorno': mileage,
      'check_in_em': DateTime.now(),
      'obs_check_in': notes,
    });
    await tx.vehicles.update(request.vehicleId!, {
      'status': VehicleStatus.disponivel.name,
      'quilometragem': mileage,
    });
    return (await tx.requests.findById(id))!;
  });

  /// Veículos que podem atender a solicitação (RN 4.1), menor km primeiro.
  Future<List<VehicleModel>> eligibleVehicles(int id) => _tx((tx) async {
    final request = await tx.requests.findById(id);
    if (request == null) {
      throw const ApiException.notFound('Solicitação não encontrada.');
    }
    final period = await tx.requests.periodOf(id);
    return tx.vehicles.eligible(
      passengers: request.passengers,
      start: period.start,
      end: period.vehicleEnd,
      ignoreRequestId: id,
      excludeVehicleId: request.pickupFailedVehicleId,
    );
  });

  // -------------------------------------------------------------------
  // Veículos
  // -------------------------------------------------------------------

  /// Cadastro (RF 3.2.1). Placa/chassi repetidos viram 409 no middleware.
  Future<VehicleModel> createVehicle(VehicleModel vehicle) =>
      _tx((tx) => tx.vehicles.insert(vehicle));

  /// Edição, desativação e reativação (RF 3.2.3 e 3.2.4).
  ///
  /// - Em uso: o status só muda pela devolução (check-in).
  /// - Ficou indisponível (manutenção/inativo): todas as reservas aprovadas
  ///   voltam para Pendente.
  /// - Perdeu lugares: voltam as reservas com mais passageiros que isso.
  ///
  /// Devolve o veículo e os ids das solicitações liberadas.
  Future<({VehicleModel vehicle, List<int> releasedRequestIds})> updateVehicle(
    int id,
    Map<String, Object?> changes,
  ) => _tx((tx) async {
    final before = await tx.vehicles.findById(id, forUpdate: true);
    if (before == null) {
      throw const ApiException.notFound('Veículo não encontrado.');
    }

    final statusName = changes['status'] as String?;
    final status = statusName == null
        ? null
        : VehicleStatus.values.byName(statusName);
    if (before.status == VehicleStatus.emUso &&
        status != null &&
        status != VehicleStatus.emUso) {
      throw const ApiException.conflict(
        'O veículo está em uso. Registre a devolução primeiro.',
      );
    }

    final becomesUnavailable = status != null && !status.canBeScheduled;
    final seats = changes['lugares'] as int?;
    final List<ReleasedRequest> released;
    if (becomesUnavailable) {
      released = await tx.requests.releaseApproved(id);
    } else if (seats != null && seats < before.seats) {
      released = await tx.requests.releaseApproved(id, seats: seats);
    } else {
      released = const [];
    }

    final vehicle = (await tx.vehicles.update(id, changes))!;
    for (final r in released) {
      await tx.notify(
        r.requesterId,
        r.id,
        r.destination,
        NotificationType.reverted,
        becomesUnavailable
            ? 'O veículo alocado ficou indisponível. Aguardando outro '
                  'veículo.'
            : 'O veículo alocado não comporta mais os passageiros. Sua '
                  'solicitação aguarda nova alocação.',
      );
    }
    return (
      vehicle: vehicle,
      releasedRequestIds: [for (final r in released) r.id],
    );
  });

  // -------------------------------------------------------------------
  // Regras auxiliares
  // -------------------------------------------------------------------

  /// Volta para Pendente: sem veículo e sem decisão.
  static const _backToPending = <String, Object?>{
    'status': RequestStatus.pendente,
    'veiculo_id': null,
    'aprovador_id': null,
    'decidido_em': null,
    'alerta_risco_em': null,
  };

  /// A solicitação, travada, desde que seja de [me].
  Future<RequestModel> _ownRequest(_Tx tx, UserModel me, int id) async {
    final request = await tx.requests.findById(id, forUpdate: true);
    if (request == null) {
      throw const ApiException.notFound('Solicitação não encontrada.');
    }
    if (request.requesterId != me.id) {
      throw const ApiException.forbidden(
        'Só quem abriu a solicitação pode alterá-la.',
      );
    }
    return request;
  }

  /// A solicitação, travada, desde que ainda esteja Pendente.
  Future<RequestModel> _pendingRequest(_Tx tx, int id) async {
    final request = await tx.requests.findById(id, forUpdate: true);
    if (request == null) {
      throw const ApiException.notFound('Solicitação não encontrada.');
    }
    if (request.status != RequestStatus.pendente) {
      throw ApiException.conflict(
        'Esta solicitação não está mais pendente '
        '(status atual: ${request.status.label}).',
      );
    }
    return request;
  }

  /// RN 5.2.4: CNH válida, e válida até o dia do retorno.
  void _ensureValidCnh(UserModel me, DateTime returnDate) {
    if (!me.hasValidCnh) {
      throw const ApiException.forbidden(
        'CNH vencida ou não cadastrada.',
      );
    }
    final expiry = me.cnhExpiry!;
    if (formatDate(returnDate).compareTo(formatDate(expiry)) > 0) {
      throw ApiException.badRequest(
        'Sua CNH vence antes da data de retorno.',
        fields: {
          'returnDate':
              'Sua CNH vence em ${_brDate(expiry)}, '
              'antes da data de retorno.',
        },
      );
    }
  }

  void _ensureNotPast(DateTime departure) {
    if (departure.isBefore(DateTime.now().subtract(_pastTolerance))) {
      throw const ApiException.badRequest(
        'A saída não pode ser no passado.',
        fields: {'departure': 'A saída não pode ser no passado.'},
      );
    }
  }

  void _ensureReturnAfterDeparture(DateTime departure, DateTime deadline) {
    if (!deadline.isAfter(departure)) {
      throw const ApiException.badRequest(
        'O retorno precisa ser depois da saída.',
        fields: {
          'returnDate':
              'O retorno precisa ser depois da saída. '
              'Verifique a data e o período de retorno.',
        },
      );
    }
  }

  /// Passageiros: de 1 até a maior lotação da frota disponível.
  Future<void> _ensurePassengersFit(_Tx tx, int passengers) async {
    final max = await tx.vehicles.maxSeats();
    if (max == null) {
      throw const ApiException.conflict(
        'Não há veículos disponíveis na frota no momento.',
      );
    }
    if (passengers > max) {
      throw ApiException.badRequest(
        'Passageiros acima da lotação da frota.',
        fields: {'passengers': 'O maior veículo da frota tem $max lugares.'},
      );
    }
  }

  /// RN 4.4 (o banco também confere, ver `usuario_sem_conflito`).
  Future<void> _ensureNoUserConflict(
    _Tx tx,
    int userId,
    DateTime start,
    DateTime end, {
    int? ignore,
  }) async {
    final conflict = await tx.requests.userHasConflict(
      userId: userId,
      start: start,
      end: end,
      ignoreRequestId: ignore,
    );
    if (conflict) {
      throw const ApiException.conflict(
        'Você já tem uma solicitação nesse período.',
      );
    }
  }

  static String _brDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
}
