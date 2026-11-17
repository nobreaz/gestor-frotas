import 'package:frota_core/frota_core.dart';
import 'package:postgres/postgres.dart';

/// Números do período, já somados pelo banco.
typedef ReportTotals = ({
  int trips,
  int finishedTrips,
  int lateReturns,
  int requests,
});

/// Consultas agregadas da tela de relatórios (`GET /relatorios`).
///
/// Todas recebem o período [from, to). "Viagem" = solicitação retirada
/// (check-out) no período, em uso ou finalizada; km só das finalizadas.
/// Os agrupamentos por semana e mês usam o fuso da empresa.
class RelatoriosRepository {
  RelatoriosRepository(this._db);

  final Session _db;

  static const _tz = "'America/Sao_Paulo'";

  static const _trips = '''
    WITH viagens AS (
      SELECT s.*,
             CASE WHEN s.status = 'finalizada'
                  THEN s.km_retorno - s.km_saida ELSE 0 END AS km,
             s.status = 'finalizada' AND s.check_in_em > s.prazo_retorno
               AS atrasada
      FROM solicitacoes s
      WHERE s.status IN ('emUso', 'finalizada')
        AND s.check_out_em >= @from::timestamptz
        AND s.check_out_em < @to::timestamptz
    )''';

  Future<Result> _query(
    String sql,
    DateTime from,
    DateTime to, [
    Map<String, Object?> extra = const {},
  ]) => _db.execute(
    Sql.named(sql),
    parameters: {
      'from': from.toUtc().toIso8601String(),
      'to': to.toUtc().toIso8601String(),
      ...extra,
    },
  );

  Future<ReportTotals> totals(DateTime from, DateTime to) async {
    final row = (await _query(
      '''
      $_trips
      SELECT
        (SELECT count(*)::int FROM viagens) AS viagens,
        (SELECT count(*)::int FROM viagens WHERE status = 'finalizada')
          AS finalizadas,
        (SELECT count(*)::int FROM viagens WHERE atrasada) AS atrasadas,
        (SELECT count(*)::int FROM solicitacoes
          WHERE criado_em >= @from::timestamptz
            AND criado_em < @to::timestamptz) AS pedidos''',
      from,
      to,
    )).first.toColumnMap();

    return (
      trips: row['viagens'] as int,
      finishedTrips: row['finalizadas'] as int,
      lateReturns: row['atrasadas'] as int,
      requests: row['pedidos'] as int,
    );
  }

  /// Solicitações criadas no período, por status atual.
  Future<Map<RequestStatus, int>> statuses(DateTime from, DateTime to) async {
    final result = await _query(
      '''
      SELECT status::text AS status, count(*)::int AS total
      FROM solicitacoes
      WHERE criado_em >= @from::timestamptz AND criado_em < @to::timestamptz
      GROUP BY status''',
      from,
      to,
    );
    return {
      for (final row in result)
        RequestStatus.values.byName(row[0]! as String): row[1]! as int,
    };
  }

  /// Viagens por semana ou mês, com os períodos sem viagem zerados.
  Future<List<TrendPoint>> trend(
    DateTime from,
    DateTime to,
    TrendGranularity granularity,
  ) async {
    final result = await _query(
      '''
      $_trips
      SELECT g.inicio::date AS inicio, count(v.id)::int AS viagens
      FROM generate_series(
        date_trunc(@unit::text, @from::timestamptz AT TIME ZONE $_tz),
        date_trunc(@unit::text, @to::timestamptz AT TIME ZONE $_tz),
        ('1 ' || @unit::text)::interval) AS g(inicio)
      LEFT JOIN viagens v
        ON date_trunc(@unit::text, v.check_out_em AT TIME ZONE $_tz) = g.inicio
      GROUP BY g.inicio
      ORDER BY g.inicio''',
      from,
      to,
      {'unit': granularity.name},
    );
    return [
      for (final row in result)
        TrendPoint(start: _day(row[0]! as DateTime), trips: row[1]! as int),
    ];
  }

  /// Quem mais viajou (como solicitante), com as devoluções atrasadas.
  Future<List<RankingEntry>> topUsers(
    DateTime from,
    DateTime to, {
    int limit = 10,
  }) => _ranking(
    '''
    $_trips
    SELECT u.id, u.nome, u.setor, count(*)::int, coalesce(sum(v.km), 0)::int,
           count(*) FILTER (WHERE v.atrasada)::int
    FROM viagens v JOIN usuarios u ON u.id = v.solicitante_id
    GROUP BY u.id
    ORDER BY 4 DESC, 6, u.nome
    LIMIT @limit::int''',
    from,
    to,
    limit,
  );

  /// Toda a frota fora de Inativo (mais as inativas que rodaram no
  /// período), da mais usada para a menos; as sem viagem ficam no fim.
  Future<List<RankingEntry>> vehicles(DateTime from, DateTime to) => _ranking(
    '''
    $_trips
    SELECT c.id, c.modelo, c.placa, count(v.id)::int,
           coalesce(sum(v.km), 0)::int,
           count(*) FILTER (WHERE v.atrasada)::int
    FROM veiculos c LEFT JOIN viagens v ON v.veiculo_id = c.id
    GROUP BY c.id
    HAVING c.status <> 'inativo' OR count(v.id) > 0
    ORDER BY 4 DESC, 5 DESC, c.modelo, c.placa''',
    from,
    to,
  );

  /// Viagens por setor de quem pediu.
  Future<List<RankingEntry>> departments(DateTime from, DateTime to) =>
      _ranking(
        '''
    $_trips
    SELECT NULL::bigint, u.setor, NULL::text, count(*)::int,
           coalesce(sum(v.km), 0)::int, count(*) FILTER (WHERE v.atrasada)::int
    FROM viagens v JOIN usuarios u ON u.id = v.solicitante_id
    GROUP BY u.setor
    ORDER BY 4 DESC, u.setor''',
        from,
        to,
      );

  /// Decisões de cada aprovador no período (pela data da decisão).
  Future<List<ApproverStats>> approvers(DateTime from, DateTime to) async {
    final result = await _query(
      '''
      SELECT u.id, u.nome,
             count(*) FILTER (WHERE s.status <> 'recusada')::int,
             count(*) FILTER (WHERE s.status = 'recusada')::int
      FROM solicitacoes s JOIN usuarios u ON u.id = s.aprovador_id
      WHERE s.decidido_em >= @from::timestamptz
        AND s.decidido_em < @to::timestamptz
      GROUP BY u.id
      ORDER BY count(*) DESC, u.nome''',
      from,
      to,
    );
    return [
      for (final row in result)
        ApproverStats(
          id: row[0]! as int,
          name: row[1]! as String,
          approved: row[2]! as int,
          rejected: row[3]! as int,
        ),
    ];
  }

  /// Agora:
  /// - veículos em uso depois do prazo;
  /// - retiradas que falharam e aguardam outro veículo (Pendente);
  /// - reservas aprovadas que saem em até 72 h com o veículo ainda numa
  ///   viagem atrasada;
  /// - pendentes que saem em até 48 h (ou já deveriam ter saído).
  /// Nessa ordem.
  Future<List<ReportAlert>> requestAlerts() async {
    final result = await _db.execute('''
      WITH alertas AS (
        SELECT s.*,
          CASE
            WHEN s.status = 'emUso' THEN 'devolucaoAtrasada'
            WHEN s.status = 'pendente' AND s.falha_retirada_em IS NOT NULL
              THEN 'retiradaFalhou'
            WHEN s.status = 'aprovada' THEN 'reservaEmRisco'
            ELSE 'saidaSemAprovacao'
          END AS tipo
        FROM solicitacoes s
        WHERE (s.status = 'emUso' AND s.prazo_retorno < now())
           OR (s.status = 'pendente'
               AND (s.falha_retirada_em IS NOT NULL
                    OR s.saida < now() + interval '48 hours'))
           OR (s.status = 'aprovada'
               AND s.saida < now() + interval '72 hours'
               AND EXISTS (
                 SELECT 1 FROM solicitacoes o
                 WHERE o.veiculo_id = s.veiculo_id AND o.id <> s.id
                   AND o.status = 'emUso' AND o.prazo_retorno < now()))
      )
      SELECT a.tipo, u.nome, coalesce(c.modelo, f.modelo),
             coalesce(c.placa, f.placa),
             to_char(a.prazo_retorno AT TIME ZONE $_tz, 'DD/MM/YYYY HH24:MI'),
             to_char(a.saida AT TIME ZONE $_tz, 'DD/MM/YYYY HH24:MI'),
             a.saida < now(), a.destino
      FROM alertas a
      JOIN usuarios u ON u.id = a.solicitante_id
      LEFT JOIN veiculos c ON c.id = a.veiculo_id
      LEFT JOIN veiculos f ON f.id = a.falha_retirada_veiculo_id
      ORDER BY array_position(
        ARRAY['devolucaoAtrasada', 'retiradaFalhou', 'reservaEmRisco',
              'saidaSemAprovacao'], a.tipo), a.saida''');

    return [
      for (final row in result)
        switch (row[0]! as String) {
          'devolucaoAtrasada' => ReportAlert(
            kind: AlertKind.devolucaoAtrasada,
            critical: true,
            title: '${row[2]} · ${row[3]}',
            message: 'Com ${row[1]}: devolução era até ${row[4]}',
          ),
          'retiradaFalhou' => ReportAlert(
            kind: AlertKind.retiradaFalhou,
            critical: true,
            title: '${row[1]} · ${row[7]}',
            message:
                'Não conseguiu retirar o ${row[2]} · ${row[3]} '
                '(saída ${row[5]}). Aloque outro veículo',
          ),
          'reservaEmRisco' => ReportAlert(
            kind: AlertKind.reservaEmRisco,
            critical: true,
            title: '${row[2]} · ${row[3]}',
            message:
                'Reserva de ${row[1]} sai ${row[5]} e o veículo '
                'ainda não voltou da viagem anterior',
          ),
          _ => ReportAlert(
            kind: AlertKind.saidaSemAprovacao,
            critical: row[6]! as bool,
            title: '${row[1]} · ${row[7]}',
            message: row[6]! as bool
                ? 'Saída era ${row[5]} e o pedido segue pendente'
                : 'Sai ${row[5]} e ainda não foi aprovado',
          ),
        },
    ];
  }

  Future<List<RankingEntry>> _ranking(
    String sql,
    DateTime from,
    DateTime to, [
    int? limit,
  ]) async {
    final result = await _query(sql, from, to, {'limit': ?limit});
    return [
      for (final row in result)
        RankingEntry(
          id: row[0] as int?,
          label: row[1]! as String,
          detail: row[2] as String?,
          trips: row[3]! as int,
          km: row[4]! as int,
          lateReturns: row[5]! as int,
        ),
    ];
  }

  // `date` chega como meia-noite UTC; guardamos só o dia.
  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);
}
