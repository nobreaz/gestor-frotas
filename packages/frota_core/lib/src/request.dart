/// Status possíveis de uma solicitação de agendamento.
///
/// Ciclo previsto na regra 4.2 do documento:
/// Pendente → Aprovada → Em uso → Finalizada
/// (ou, a partir de Pendente: Negada / Cancelada; Aprovada ainda não
/// retirada também pode ser Cancelada)
enum RequestStatus {
  pendente,
  aprovada,
  emUso,
  finalizada,
  recusada,
  cancelada,
}

extension RequestStatusX on RequestStatus {
  String get label {
    switch (this) {
      case RequestStatus.pendente:
        return 'Pendente';
      case RequestStatus.aprovada:
        return 'Aprovada';
      case RequestStatus.emUso:
        return 'Em uso';
      case RequestStatus.finalizada:
        return 'Finalizada';
      case RequestStatus.recusada:
        return 'Recusada';
      case RequestStatus.cancelada:
        return 'Cancelada';
    }
  }

  /// Ocupa a agenda do usuário (regra 4.4).
  bool get isActive =>
      this == RequestStatus.pendente ||
      this == RequestStatus.aprovada ||
      this == RequestStatus.emUso;

  /// Ocupa a agenda do veículo alocado (regra 4.3).
  bool get holdsVehicle =>
      this == RequestStatus.aprovada || this == RequestStatus.emUso;
}

/// Período do dia em que o veículo será devolvido.
enum ReturnPeriod { manha, tarde }

extension ReturnPeriodX on ReturnPeriod {
  String get label {
    switch (this) {
      case ReturnPeriod.manha:
        return 'Manhã';
      case ReturnPeriod.tarde:
        return 'Tarde';
    }
  }

  /// Horário limite de devolução de cada período.
  int get endHour {
    switch (this) {
      case ReturnPeriod.manha:
        return 12;
      case ReturnPeriod.tarde:
        return 18;
    }
  }

  String get description => 'até ${endHour}h';
}

/// Por que o solicitante não conseguiu retirar o veículo.
enum PickupFailureReason { naoDevolvido, problemaVeiculo, outro }

extension PickupFailureReasonX on PickupFailureReason {
  String get label {
    switch (this) {
      case PickupFailureReason.naoDevolvido:
        return 'O veículo não foi devolvido da viagem anterior';
      case PickupFailureReason.problemaVeiculo:
        return 'O veículo está com problema';
      case PickupFailureReason.outro:
        return 'Outro motivo';
    }
  }

  /// "Outro" exige observação.
  bool get requiresNotes => this == PickupFailureReason.outro;
}

/// Por que o SISTEMA cancelou a solicitação. Nulo quando foi o próprio
/// solicitante que cancelou.
enum CancellationReason {
  /// Pendente que ninguém aprovou até o fim do dia da saída.
  semAprovacao,

  /// Aprovada cujo veículo não foi retirado até o fim do dia da saída.
  naoRetirada,

  /// O Administrador desativou o solicitante.
  usuarioDesativado,

  /// O solicitante deixou de ser do perfil Padrão.
  perfilAlterado,
}

extension CancellationReasonX on CancellationReason {
  /// Texto mostrado no card da solicitação.
  String get label {
    switch (this) {
      case CancellationReason.semAprovacao:
        return 'Cancelada automaticamente: a data de saída passou sem '
            'aprovação.';
      case CancellationReason.naoRetirada:
        return 'Cancelada automaticamente: o veículo não foi retirado no '
            'dia da saída.';
      case CancellationReason.usuarioDesativado:
        return 'Cancelada porque o acesso do solicitante foi desativado.';
      case CancellationReason.perfilAlterado:
        return 'Cancelada porque o perfil do solicitante foi alterado.';
    }
  }
}

/// O que o solicitante quer depois de não conseguir retirar o veículo.
enum PickupFailureAction {
  /// A solicitação volta para Pendente (urgente) e os Aprovadores escolhem
  /// outro veículo.
  novoVeiculo,

  /// A solicitação é cancelada e o solicitante abre outra com novas datas.
  reagendar,
}

/// Margem de segurança entre reservas do mesmo veículo (pedido do
/// professor): o veículo só fica livre à meia-noite do dia seguinte ao
/// retorno. Ex.: retorno na segunda → livre a partir de terça 00h.
/// Vale só para o veículo (RN 4.3), não para o usuário (RN 4.4).
DateTime vehicleFreeFrom(DateTime returnDay) =>
    DateTime(returnDay.year, returnDay.month, returnDay.day + 1);

/// Dois intervalos `[aStart, aEnd)` e `[bStart, bEnd)` se sobrepõem?
/// Base das regras 4.3 (veículo) e 4.4 (usuário). Encostar não conta:
/// uma devolução às 12h não conflita com uma saída às 12h.
bool periodsOverlap(
  DateTime aStart,
  DateTime aEnd,
  DateTime bStart,
  DateTime bEnd,
) => aStart.isBefore(bEnd) && bStart.isBefore(aEnd);

/// Representa uma solicitação de agendamento de veículo.
/// (Entidade "Solicitação de agendamento" — seção 5.3 do documento.)
class RequestModel {
  final int id;

  /// Usuário que abriu a solicitação (id + nome).
  final int requesterId;
  final String requester;

  // Campos editáveis antes do check-out.
  String reason;
  String destination;
  int passengers;
  DateTime? departure;
  DateTime? returnDate;
  ReturnPeriod? returnPeriod;

  RequestStatus status;

  /// Veículo alocado pelo aprovador (item 5.3.4 / regra 4.1.3).
  int? vehicleId;

  /// Justificativa obrigatória em caso de recusa (regra 4.7).
  String? rejectionReason;

  /// Quilometragem de saída e de retorno (item 5.3.5 / regra 4.8).
  int? departureMileage;
  int? returnMileage;

  /// Momentos reais de retirada e devolução.
  DateTime? checkOutAt;
  DateTime? checkInAt;

  /// Observações registradas na retirada e na devolução.
  String? checkOutNotes;
  String? checkInNotes;

  /// Aprovador que decidiu (aprovou ou recusou) e quando.
  /// Nulos enquanto pendente; apagados se a solicitação voltar a pendente.
  int? approverId;
  String? approverName;
  DateTime? decidedAt;

  /// Falha na retirada informada pelo solicitante: quando, por quê, a
  /// observação e o veículo que não pôde ser retirado.
  DateTime? pickupFailedAt;
  PickupFailureReason? pickupFailureReason;
  String? pickupFailureNotes;
  int? pickupFailedVehicleId;

  /// Por que o sistema cancelou (nulo se o solicitante cancelou).
  CancellationReason? cancellationReason;

  RequestModel({
    required this.id,
    required this.reason,
    required this.destination,
    required this.passengers,
    this.requesterId = 1,
    this.requester = 'Nome Sobrenome',
    this.departure,
    this.returnDate,
    this.returnPeriod,
    this.status = RequestStatus.pendente,
    this.vehicleId,
    this.rejectionReason,
    this.departureMileage,
    this.returnMileage,
    this.checkOutAt,
    this.checkInAt,
    this.checkOutNotes,
    this.checkInNotes,
    this.approverId,
    this.approverName,
    this.decidedAt,
    this.pickupFailedAt,
    this.pickupFailureReason,
    this.pickupFailureNotes,
    this.pickupFailedVehicleId,
    this.cancellationReason,
  });

  /// Formato JSON trocado entre a API e o app.
  /// Momentos (saída, check-out...) vão em ISO 8601 UTC e voltam no fuso
  /// local; a data de retorno é só o dia (`AAAA-MM-DD`).
  factory RequestModel.fromJson(Map<String, dynamic> json) {
    DateTime? instant(String key) {
      final v = json[key] as String?;
      return v == null ? null : DateTime.parse(v).toLocal();
    }

    final returnDate = json['returnDate'] as String?;
    final period = json['returnPeriod'] as String?;
    final failure = json['pickupFailureReason'] as String?;
    final cancellation = json['cancellationReason'] as String?;
    return RequestModel(
      id: json['id'] as int,
      requesterId: json['requesterId'] as int,
      requester: json['requester'] as String,
      reason: json['reason'] as String,
      destination: json['destination'] as String,
      passengers: json['passengers'] as int,
      departure: instant('departure'),
      returnDate: returnDate == null ? null : DateTime.parse(returnDate),
      returnPeriod: period == null ? null : ReturnPeriod.values.byName(period),
      status: RequestStatus.values.byName(json['status'] as String),
      vehicleId: json['vehicleId'] as int?,
      rejectionReason: json['rejectionReason'] as String?,
      departureMileage: json['departureMileage'] as int?,
      returnMileage: json['returnMileage'] as int?,
      checkOutAt: instant('checkOutAt'),
      checkInAt: instant('checkInAt'),
      checkOutNotes: json['checkOutNotes'] as String?,
      checkInNotes: json['checkInNotes'] as String?,
      approverId: json['approverId'] as int?,
      approverName: json['approverName'] as String?,
      decidedAt: instant('decidedAt'),
      pickupFailedAt: instant('pickupFailedAt'),
      pickupFailureReason: failure == null
          ? null
          : PickupFailureReason.values.byName(failure),
      pickupFailureNotes: json['pickupFailureNotes'] as String?,
      pickupFailedVehicleId: json['pickupFailedVehicleId'] as int?,
      cancellationReason: cancellation == null
          ? null
          : CancellationReason.values.byName(cancellation),
    );
  }

  Map<String, dynamic> toJson() {
    String? instant(DateTime? d) => d?.toUtc().toIso8601String();
    final date = returnDate;
    return {
      'id': id,
      'requesterId': requesterId,
      'requester': requester,
      'reason': reason,
      'destination': destination,
      'passengers': passengers,
      'departure': instant(departure),
      'returnDate': date == null
          ? null
          : '${date.year.toString().padLeft(4, '0')}-'
                '${date.month.toString().padLeft(2, '0')}-'
                '${date.day.toString().padLeft(2, '0')}',
      'returnPeriod': returnPeriod?.name,
      'status': status.name,
      'vehicleId': vehicleId,
      'rejectionReason': rejectionReason,
      'departureMileage': departureMileage,
      'returnMileage': returnMileage,
      'checkOutAt': instant(checkOutAt),
      'checkInAt': instant(checkInAt),
      'checkOutNotes': checkOutNotes,
      'checkInNotes': checkInNotes,
      'approverId': approverId,
      'approverName': approverName,
      'decidedAt': instant(decidedAt),
      'pickupFailedAt': instant(pickupFailedAt),
      'pickupFailureReason': pickupFailureReason?.name,
      'pickupFailureNotes': pickupFailureNotes,
      'pickupFailedVehicleId': pickupFailedVehicleId,
      'cancellationReason': cancellationReason?.name,
    };
  }

  /// Registra a decisão do aprovador (aprovação ou recusa).
  void recordDecision({required int approverId, required String approverName}) {
    this.approverId = approverId;
    this.approverName = approverName;
    decidedAt = DateTime.now();
  }

  /// Volta para pendente: a decisão anterior deixa de valer.
  void clearDecision() {
    approverId = null;
    approverName = null;
    decidedAt = null;
  }

  /// Já passou pela aprovação (aprovada, em uso ou finalizada).
  bool get wasApproved =>
      status == RequestStatus.aprovada ||
      status == RequestStatus.emUso ||
      status == RequestStatus.finalizada;

  /// Prazo exato de devolução: data de retorno + horário do período.
  DateTime? get returnDeadline {
    final date = returnDate;
    if (date == null) return null;
    final hour = (returnPeriod ?? ReturnPeriod.tarde).endHour;
    return DateTime(date.year, date.month, date.day, hour);
  }

  /// Pode ser editada? Somente antes do check-out.
  bool get canEdit =>
      status == RequestStatus.pendente || status == RequestStatus.aprovada;

  /// O solicitante pode cancelar? Antes da retirada: pendente ou aprovada
  /// (cancelar uma aprovada libera o veículo).
  bool get canCancel => canEdit;

  /// Momento a partir do qual o veículo alocado fica livre para outra
  /// reserva (margem de um dia, ver [vehicleFreeFrom]).
  DateTime? get vehicleFreeAt {
    final date = returnDate;
    return date == null ? null : vehicleFreeFrom(date);
  }

  /// Voltou para Pendente porque o solicitante não conseguiu retirar o
  /// veículo: o Aprovador precisa alocar outro com urgência.
  bool get needsReallocation =>
      status == RequestStatus.pendente && pickupFailedAt != null;

  /// O solicitante pode informar que não conseguiu retirar o veículo:
  /// aprovada e a partir do dia da saída.
  bool canReportPickupFailure({DateTime? now}) {
    final d = departure;
    if (status != RequestStatus.aprovada || d == null) return false;
    final today = now ?? DateTime.now();
    return !DateTime(
      today.year,
      today.month,
      today.day,
    ).isBefore(DateTime(d.year, d.month, d.day));
  }

  /// Data de saída passou e o veículo não foi retirado.
  bool get isCheckOutLate =>
      status == RequestStatus.aprovada &&
      departure != null &&
      departure!.isBefore(DateTime.now());

  /// Prazo de retorno passou e o veículo continua em uso.
  bool get isReturnLate =>
      status == RequestStatus.emUso &&
      returnDeadline != null &&
      returnDeadline!.isBefore(DateTime.now());

  /// Viagem finalizada, mas devolvida depois do prazo.
  bool get wasReturnedLate {
    final deadline = returnDeadline;
    final at = checkInAt;
    return status == RequestStatus.finalizada &&
        deadline != null &&
        at != null &&
        at.isAfter(deadline);
  }

  /// Distância percorrida na viagem, quando já finalizada.
  int? get distanceTravelled {
    if (departureMileage == null || returnMileage == null) return null;
    return returnMileage! - departureMileage!;
  }
}
