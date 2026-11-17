-- Margem de segurança entre reservas e "não consegui retirar o veículo".
-- Pedidos do professor e do grupo em 2026-11-09.
--
-- 1. Margem de um dia: o veículo só volta a ficar livre à meia-noite do
--    dia seguinte ao retorno previsto (fuso da empresa). Ex.: retorno na
--    segunda (manhã ou tarde) → livre a partir de terça 00h. Vale só para
--    o VEÍCULO (RN 4.3); o usuário (RN 4.4) continua com o prazo exato.
-- 2. Falha na retirada: o solicitante informa que não conseguiu retirar o
--    veículo (motivo + observação) e escolhe pedir outro veículo (volta a
--    Pendente, urgente) ou reagendar (a solicitação é cancelada).
-- 3. Alerta de reserva em risco: avisos enviados quando o veículo da
--    reserva ainda está com uma viagem atrasada (enviado uma vez só).

-- ---------------------------------------------------------------------
-- 1. Margem de um dia
-- ---------------------------------------------------------------------
alter table solicitacoes
  add column veiculo_livre_em timestamptz generated always as (
    ((data_retorno + 1)::timestamp at time zone 'America/Sao_Paulo')
  ) stored;

alter table solicitacoes drop constraint veiculo_sem_conflito;
alter table solicitacoes add constraint veiculo_sem_conflito exclude using gist (
  veiculo_id with =,
  tstzrange(saida, veiculo_livre_em, '[)') with &&
) where (status in ('aprovada', 'emUso'));

-- ---------------------------------------------------------------------
-- 2. Falha na retirada
-- ---------------------------------------------------------------------
create type motivo_falha_retirada as enum (
  'naoDevolvido',     -- o veículo não voltou da viagem anterior
  'problemaVeiculo',  -- defeito, pneu, sem combustível, documento...
  'outro'             -- exige observação
);

alter table solicitacoes
  add column falha_retirada_em         timestamptz,
  add column falha_retirada_motivo     motivo_falha_retirada,
  add column falha_retirada_obs        text,
  add column falha_retirada_veiculo_id bigint references veiculos (id),
  add column alerta_risco_em           timestamptz;

alter table solicitacoes add constraint falha_retirada_completa check (
  (falha_retirada_em is null) = (falha_retirada_motivo is null)
  and (falha_retirada_em is null) = (falha_retirada_veiculo_id is null)
  and (
    falha_retirada_motivo is distinct from 'outro'
    or length(trim(coalesce(falha_retirada_obs, ''))) > 0
  )
);

-- Novos tipos de notificação:
-- pickupFailed: aos Aprovadores, "fulano não conseguiu retirar, realoque";
-- atRisk: ao solicitante e aos Aprovadores, "o veículo ainda não voltou".
alter type tipo_notificacao add value 'pickupFailed';
alter type tipo_notificacao add value 'atRisk';
