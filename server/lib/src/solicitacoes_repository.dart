import 'package:frota_core/frota_core.dart';
import 'package:postgres/postgres.dart';

/// Fuso da empresa. "Devolver até 12h" é 12h no horário de Brasília,
/// mesmo que o servidor rode em UTC (como na maioria das hospedagens).
const companyTimeZone = 'America/Sao_Paulo';

/// Intervalo que a solicitação [alias] ocupa na agenda do USUÁRIO (RN 4.4):
/// - em uso, começa na retirada real (pode ter sido antes da saída prevista);
/// - em uso e com a devolução atrasada, ocupa até o check-in (sem fim).
String occupiedRangeSql(String alias) =>
    '''
    tstzrange(
      CASE WHEN $alias.status = 'emUso'
           THEN least(coalesce($alias.check_out_em, $alias.saida), $alias.saida)
           ELSE $alias.saida END,
      CASE WHEN $alias.status = 'emUso' AND $alias.prazo_retorno < now()
           THEN 'infinity'::timestamptz
           ELSE $alias.prazo_retorno END,
      '[)')''';

/// Intervalo que a solicitação [alias] ocupa na agenda do VEÍCULO (RN 4.3),
/// com a margem de um dia (`vehicleFreeFrom` no frota_core):
/// - aprovada: da saída até a meia-noite do dia seguinte ao retorno
///   (`veiculo_livre_em`, coluna calculada pelo banco);
/// - em uso: começa na retirada real; com a devolução atrasada, sem fim;
/// - finalizada: do check-in até a meia-noite seguinte (devolveu atrasado
///   na terça → só fica livre na quarta; devolveu adiantado → libera antes).
/// Usar junto com [vehicleHoldsSql].
String vehicleOccupiedRangeSql(String alias) =>
    '''
    tstzrange(
      CASE WHEN $alias.status = 'finalizada' THEN $alias.check_in_em
           WHEN $alias.status = 'emUso'
           THEN least(coalesce($alias.check_out_em, $alias.saida), $alias.saida)
           ELSE $alias.saida END,
      CASE WHEN $alias.status = 'finalizada'
           THEN (($alias.check_in_em AT TIME ZONE '$companyTimeZone')::date + 1)
                ::timestamp AT TIME ZONE '$companyTimeZone'
           WHEN $alias.status = 'emUso' AND $alias.prazo_retorno < now()
           THEN 'infinity'::timestamptz
           ELSE $alias.veiculo_livre_em END,
      '[)')''';

/// Solicitações que ocupam a agenda do veículo em [vehicleOccupiedRangeSql].
/// Finalizada só conta até a meia-noite seguinte à devolução (margem); o
/// filtro de data evita varrer o histórico inteiro.
String vehicleHoldsSql(String alias) =>
    '''
    ($alias.status IN ('aprovada', 'emUso')
     OR ($alias.status = 'finalizada'
         AND $alias.check_in_em > now() - interval '2 days'))''';

/// Reserva aprovada cujo veículo ainda está numa viagem atrasada.
typedef AtRiskRequest = ({
  int id,
  int requesterId,
  String destination,
  String vehicle,

  /// "DD/MM/AAAA HH:MM" no fuso da empresa (o servidor pode rodar em UTC).
  String departure,
});

/// Solicitação que voltou para Pendente porque o veículo deixou de atendê-la.
typedef ReleasedRequest = ({int id, int requesterId, String destination});

/// Acesso à tabela `solicitacoes`. Só SQL e conversão linha → [RequestModel];
/// regras de negócio ficam no `FrotaService` e no frota_core.
class SolicitacoesRepository {
  SolicitacoesRepository(this._db);

  final Session _db;

  // Nomes do solicitante e do aprovador vêm de `usuarios` (dois joins).
  static const _select = '''
    SELECT s.id, s.solicitante_id, u.nome AS solicitante,
           s.motivo, s.destino, s.passageiros,
           s.saida, s.data_retorno, s.periodo_retorno::text AS periodo_retorno,
           s.status::text AS status, s.veiculo_id, s.justificativa_recusa,
           s.km_saida, s.km_retorno, s.check_out_em, s.check_in_em,
           s.obs_check_out, s.obs_check_in,
           s.aprovador_id, a.nome AS aprovador, s.decidido_em,
           s.falha_retirada_em, s.falha_retirada_motivo::text AS falha_motivo,
           s.falha_retirada_obs, s.falha_retirada_veiculo_id
    FROM solicitacoes s
    JOIN usuarios u ON u.id = s.solicitante_id
    LEFT JOIN usuarios a ON a.id = s.aprovador_id''';

  /// Colunas que podem ser alteradas por [update], com o tipo SQL de cada uma.
  static const editableColumns = {
    'motivo': 'text',
    'destino': 'text',
    'passageiros': 'int',
    'saida': 'timestamptz',
    'data_retorno': 'date',
    'periodo_retorno': 'periodo_retorno',
    'prazo_retorno': 'timestamptz',
    'status': 'status_solicitacao',
    'veiculo_id': 'bigint',
    'justificativa_recusa': 'text',
    'km_saida': 'int',
    'km_retorno': 'int',
    'check_out_em': 'timestamptz',
    'check_in_em': 'timestamptz',
    'obs_check_out': 'text',
    'obs_check_in': 'text',
    'aprovador_id': 'bigint',
    'decidido_em': 'timestamptz',
    'falha_retirada_em': 'timestamptz',
    'falha_retirada_motivo': 'motivo_falha_retirada',
    'falha_retirada_obs': 'text',
    'falha_retirada_veiculo_id': 'bigint',
    'alerta_risco_em': 'timestamptz',
  };

  /// [forUpdate] trava a solicitação até o fim da transação (usar dentro
  /// de `runTx`), para duas ações sobre ela não se atropelarem.
  Future<RequestModel?> findById(int id, {bool forUpdate = false}) async {
    final result = await _db.execute(
      Sql.named(
        '$_select WHERE s.id = @id${forUpdate ? ' FOR UPDATE OF s' : ''}',
      ),
      parameters: {'id': id},
    );
    return result.isEmpty ? null : _fromRow(result.first);
  }

  /// Lista com filtros opcionais, mais recentes primeiro
  /// (decididas pela data da decisão; pendentes pela data de criação).
  Future<List<RequestModel>> list({
    Set<RequestStatus>? statuses,
    int? requesterId,
    int? approverId,
  }) async {
    final where = <String>[];
    final params = <String, Object?>{};

    if (statuses != null && statuses.isNotEmpty) {
      where.add('s.status::text = ANY(@statuses)');
      params['statuses'] = TypedValue(
        Type.textArray,
        [for (final s in statuses) s.name],
      );
    }
    if (requesterId != null) {
      where.add('s.solicitante_id = @requesterId');
      params['requesterId'] = requesterId;
    }
    if (approverId != null) {
      where.add('s.aprovador_id = @approverId');
      params['approverId'] = approverId;
    }

    final result = await _db.execute(
      Sql.named(
        '$_select '
        '${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} '
        'ORDER BY coalesce(s.decidido_em, s.criado_em) DESC, s.id DESC',
      ),
      parameters: params,
    );
    return result.map(_fromRow).toList();
  }

  /// Prazo exato de devolução: [returnDate] às 12h (manhã) ou 18h (tarde)
  /// no fuso da empresa. Mesma regra de `RequestModel.returnDeadline`.
  Future<DateTime> deadline(DateTime returnDate, ReturnPeriod period) async {
    final result = await _db.execute(
      Sql.named(
        'SELECT (@date::date + make_interval(hours => @hour::int)) '
        'AT TIME ZONE @zone::text',
      ),
      parameters: {
        'date': formatDate(returnDate),
        'hour': period.endHour,
        'zone': companyTimeZone,
      },
    );
    return (result.first.first! as DateTime).toUtc();
  }

  /// Saída, prazo de devolução e fim da ocupação do veículo (com a margem
  /// de um dia), como gravados no banco.
  Future<({DateTime start, DateTime end, DateTime vehicleEnd})> periodOf(
    int id,
  ) async {
    final result = await _db.execute(
      Sql.named(
        'SELECT saida, prazo_retorno, veiculo_livre_em '
        'FROM solicitacoes WHERE id = @id',
      ),
      parameters: {'id': id},
    );
    final row = result.single;
    return (
      start: row[0]! as DateTime,
      end: row[1]! as DateTime,
      vehicleEnd: row[2]! as DateTime,
    );
  }

  /// Já é o dia da saída (ou depois) no fuso da empresa?
  Future<bool> departureDayReached(int id) => _exists(
    '''
    SELECT 1 FROM solicitacoes
    WHERE id = @id
      AND now() >= ((saida AT TIME ZONE @zone)::date)::timestamp
                   AT TIME ZONE @zone''',
    {'id': id, 'zone': companyTimeZone},
  );

  /// Marca (uma vez só) as reservas aprovadas que saem em até [window] e
  /// cujo veículo ainda está numa viagem com a devolução atrasada.
  /// O `UPDATE ... WHERE alerta_risco_em IS NULL` garante que duas
  /// chamadas ao mesmo tempo não avisem em dobro.
  Future<List<AtRiskRequest>> markAtRisk({
    Duration window = const Duration(hours: 72),
  }) async {
    final result = await _db.execute(
      Sql.named('''
        UPDATE solicitacoes r
        SET alerta_risco_em = now()
        FROM veiculos v
        WHERE v.id = r.veiculo_id
          AND r.status = 'aprovada'
          AND r.alerta_risco_em IS NULL
          AND r.saida < now() + make_interval(secs => @window)
          AND EXISTS (
            SELECT 1 FROM solicitacoes o
            WHERE o.veiculo_id = r.veiculo_id
              AND o.id <> r.id
              AND o.status = 'emUso'
              AND o.prazo_retorno < now()
          )
        RETURNING r.id, r.solicitante_id, r.destino,
                  v.modelo || ' · ' || v.placa,
                  to_char(r.saida AT TIME ZONE @zone, 'DD/MM/YYYY HH24:MI')'''),
      parameters: {'window': window.inSeconds, 'zone': companyTimeZone},
    );
    return [
      for (final row in result)
        (
          id: row[0]! as int,
          requesterId: row[1]! as int,
          destination: row[2]! as String,
          vehicle: row[3]! as String,
          departure: row[4]! as String,
        ),
    ];
  }

  /// RN 4.4: o usuário já tem outra solicitação ativa (pendente, aprovada ou
  /// em uso) que se sobrepõe a [start]–[end]?
  Future<bool> userHasConflict({
    required int userId,
    required DateTime start,
    required DateTime end,
    int? ignoreRequestId,
  }) => _exists(
    '''
    SELECT 1 FROM solicitacoes o
    WHERE o.solicitante_id = @owner
      AND o.id <> @ignore
      AND o.status IN ('pendente', 'aprovada', 'emUso')
      AND ${occupiedRangeSql('o')}
          && tstzrange(@start::timestamptz, @end::timestamptz, '[)')''',
    {
      'owner': userId,
      'ignore': ignoreRequestId ?? 0,
      'start': start.toUtc().toIso8601String(),
      'end': end.toUtc().toIso8601String(),
    },
  );

  /// RN 4.3: o veículo está livre (sem reserva aprovada ou em uso, nem
  /// devolvido hoje) no período [start]–[end] inteiro? [end] já deve
  /// incluir a margem (`vehicleEnd` de [periodOf]).
  Future<bool> vehicleIsFree({
    required int vehicleId,
    required DateTime start,
    required DateTime end,
    int? ignoreRequestId,
  }) async => !await _exists(
    '''
    SELECT 1 FROM solicitacoes o
    WHERE o.veiculo_id = @vehicle
      AND o.id <> @ignore
      AND ${vehicleHoldsSql('o')}
      AND ${vehicleOccupiedRangeSql('o')}
          && tstzrange(@start::timestamptz, @end::timestamptz, '[)')''',
    {
      'vehicle': vehicleId,
      'ignore': ignoreRequestId ?? 0,
      'start': start.toUtc().toIso8601String(),
      'end': end.toUtc().toIso8601String(),
    },
  );

  /// Grava uma nova solicitação (sempre Pendente). Devolve o id.
  Future<int> insert({
    required int requesterId,
    required String reason,
    required String destination,
    required int passengers,
    required DateTime departure,
    required DateTime returnDate,
    required ReturnPeriod returnPeriod,
    required DateTime deadline,
  }) async {
    final result = await _db.execute(
      Sql.named('''
        INSERT INTO solicitacoes (
          solicitante_id, motivo, destino, passageiros,
          saida, data_retorno, periodo_retorno, prazo_retorno
        ) VALUES (
          @requester, @reason, @destination, @passengers,
          @departure::timestamptz, @returnDate::date,
          @period::periodo_retorno, @deadline::timestamptz
        )
        RETURNING id'''),
      parameters: {
        'requester': requesterId,
        'reason': reason,
        'destination': destination,
        'passengers': passengers,
        'departure': departure.toUtc().toIso8601String(),
        'returnDate': formatDate(returnDate),
        'period': returnPeriod.name,
        'deadline': deadline.toUtc().toIso8601String(),
      },
    );
    return result.single.first! as int;
  }

  /// Altera só as colunas recebidas em [changes] (nomes de [editableColumns]).
  /// `DateTime` vira dia (`date`) ou momento UTC (`timestamptz`) conforme
  /// a coluna.
  Future<void> update(int id, Map<String, Object?> changes) async {
    if (changes.isEmpty) return;

    final sets = <String>[];
    final params = <String, Object?>{'id': id};
    for (final MapEntry(key: column, :value) in changes.entries) {
      final type = editableColumns[column];
      if (type == null) throw ArgumentError('Coluna não editável: $column');
      sets.add('$column = @$column::$type');
      params[column] = switch (value) {
        final DateTime d when type == 'date' => formatDate(d),
        final DateTime d => d.toUtc().toIso8601String(),
        final Enum e => e.name,
        _ => value,
      };
    }

    await _db.execute(
      Sql.named('UPDATE solicitacoes SET ${sets.join(', ')} WHERE id = @id'),
      parameters: params,
    );
  }

  /// Devolve para Pendente as reservas APROVADAS do veículo (ainda não
  /// retiradas), apagando veículo e decisão. Com [seats], só as que têm
  /// mais passageiros que isso (o veículo perdeu lugares).
  Future<List<ReleasedRequest>> releaseApproved(
    int vehicleId, {
    int? seats,
  }) async {
    final result = await _db.execute(
      Sql.named('''
        UPDATE solicitacoes
        SET status = 'pendente', veiculo_id = NULL,
            aprovador_id = NULL, decidido_em = NULL, alerta_risco_em = NULL
        WHERE veiculo_id = @vehicle AND status = 'aprovada'
          ${seats == null ? '' : 'AND passageiros > @seats'}
        RETURNING id, solicitante_id, destino'''),
      parameters: {'vehicle': vehicleId, 'seats': ?seats},
    );
    return [
      for (final row in result)
        (
          id: row[0]! as int,
          requesterId: row[1]! as int,
          destination: row[2]! as String,
        ),
    ];
  }

  Future<bool> _exists(String sql, Map<String, Object?> parameters) async {
    final result = await _db.execute(
      Sql.named('SELECT EXISTS ($sql)'),
      parameters: parameters,
    );
    return result.single.first! as bool;
  }

  static RequestModel _fromRow(ResultRow row) {
    final m = row.toColumnMap();
    DateTime? local(String key) => (m[key] as DateTime?)?.toLocal();
    final returnDate = m['data_retorno'] as DateTime?;
    final failure = m['falha_motivo'] as String?;

    return RequestModel(
      id: m['id'] as int,
      requesterId: m['solicitante_id'] as int,
      requester: m['solicitante'] as String,
      reason: m['motivo'] as String,
      destination: m['destino'] as String,
      passengers: m['passageiros'] as int,
      departure: local('saida'),
      // `date` chega como meia-noite UTC; guardamos só o dia.
      returnDate: returnDate == null
          ? null
          : DateTime(returnDate.year, returnDate.month, returnDate.day),
      returnPeriod: ReturnPeriod.values.byName(m['periodo_retorno'] as String),
      status: RequestStatus.values.byName(m['status'] as String),
      vehicleId: m['veiculo_id'] as int?,
      rejectionReason: m['justificativa_recusa'] as String?,
      departureMileage: m['km_saida'] as int?,
      returnMileage: m['km_retorno'] as int?,
      checkOutAt: local('check_out_em'),
      checkInAt: local('check_in_em'),
      checkOutNotes: m['obs_check_out'] as String?,
      checkInNotes: m['obs_check_in'] as String?,
      approverId: m['aprovador_id'] as int?,
      approverName: m['aprovador'] as String?,
      decidedAt: local('decidido_em'),
      pickupFailedAt: local('falha_retirada_em'),
      pickupFailureReason: failure == null
          ? null
          : PickupFailureReason.values.byName(failure),
      pickupFailureNotes: m['falha_retirada_obs'] as String?,
      pickupFailedVehicleId: m['falha_retirada_veiculo_id'] as int?,
    );
  }
}
