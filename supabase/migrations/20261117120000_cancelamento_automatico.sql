-- Cancelamentos feitos pelo sistema (revisão final, 2026-11-17).
--
-- Até aqui só o solicitante cancelava. Agora o sistema também encerra
-- solicitações que não podem mais acontecer, e guarda o motivo para o app
-- explicar ao usuário por que ela foi cancelada:
--   semAprovacao       pendente que ninguém aprovou até o fim do dia da saída
--   naoRetirada        aprovada cujo veículo não foi retirado até o fim do
--                      dia da saída (o veículo volta a ficar livre)
--   usuarioDesativado  o Administrador desativou o solicitante
--   perfilAlterado     o solicitante deixou de ser Padrão (não pode mais
--                      retirar nem devolver veículo)
-- Cancelada pelo próprio solicitante: motivo nulo.

create type motivo_cancelamento as enum (
  'semAprovacao', 'naoRetirada', 'usuarioDesativado', 'perfilAlterado'
);

alter table solicitacoes add column cancelamento_motivo motivo_cancelamento;

alter table solicitacoes add constraint cancelamento_so_em_cancelada check (
  cancelamento_motivo is null or status = 'cancelada'
);
