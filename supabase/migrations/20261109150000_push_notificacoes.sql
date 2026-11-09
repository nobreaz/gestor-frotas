-- Notificações push no celular (Firebase Cloud Messaging), 2026-11-09.
--
-- 1. dispositivos: o token FCM de cada celular logado. O app registra ao
--    entrar e apaga ao sair. Um token pertence a um usuário só (se outra
--    pessoa entrar no mesmo celular, o token passa para ela).
-- 2. notificacoes ganha uma "fila de envio": push_enviado_em vazio = ainda
--    não foi para o celular. A API envia logo depois de gravar e tenta de
--    novo a cada minuto (até 5 vezes, só notificações da última hora).

create table dispositivos (
  id             bigint generated always as identity primary key,
  usuario_id     bigint not null references usuarios (id),
  token          text not null unique,
  plataforma     text not null default 'android',
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);

create index dispositivos_usuario_idx on dispositivos (usuario_id);

create trigger dispositivos_atualizado_em before update on dispositivos
  for each row execute function definir_atualizado_em();

-- Só a API acessa (mesma regra das outras tabelas).
alter table dispositivos enable row level security;

alter table notificacoes
  add column push_enviado_em  timestamptz,
  add column push_tentativas  int not null default 0;

-- As notificações que já existem não vão para o celular.
update notificacoes set push_enviado_em = criada_em;

-- A fila é pequena: só as ainda não enviadas.
create index notificacoes_push_pendente_idx on notificacoes (id)
  where push_enviado_em is null;
