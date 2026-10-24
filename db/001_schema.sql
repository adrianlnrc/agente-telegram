-- Schema v1 do agente pessoal no Telegram.
-- Todos os horarios sao timestamptz (UTC). Toda tabela de dados tem user_id.

CREATE SCHEMA IF NOT EXISTS agente;
SET search_path = agente;

-- Pessoas autorizadas. O telegram_id vem do Telegram em toda mensagem e nunca do texto.
CREATE TABLE users (
  id                   bigserial PRIMARY KEY,
  telegram_id          bigint      NOT NULL UNIQUE,
  name                 text        NOT NULL,
  timezone             text        NOT NULL DEFAULT 'America/Sao_Paulo',
  summary_time         time        NOT NULL DEFAULT '07:30',
  default_lead_minutes integer,                      -- NULL = perguntar "quer que eu lembre antes?"
  supply_alert_days    integer     NOT NULL DEFAULT 5,
  calendar_key         text,                         -- escolhe o sub-workflow do Google Calendar
  onboarding_step      text        NOT NULL DEFAULT 'start',
  onboarded_at         timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now()
);

-- Lembretes (kind=reminder) e compromissos espelhados do Google Calendar (kind=event).
CREATE TABLE reminders (
  id                bigserial PRIMARY KEY,
  user_id           bigint      NOT NULL REFERENCES users(id),
  kind              text        NOT NULL DEFAULT 'reminder' CHECK (kind IN ('reminder','event')),
  title             text        NOT NULL,
  notes             text,
  due_at            timestamptz,                     -- NULL = aguardando o usuario informar o horario
  status            text        NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('awaiting_time','pending','done','cancelled')),
  calendar_event_id text,
  shared_group      uuid,                            -- mesmo valor nas linhas de "lembra nos dois"
  source            text        NOT NULL DEFAULT 'text' CHECK (source IN ('text','audio')),
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX reminders_user_status ON reminders (user_id, status);

-- Fila de envios. Um workflow com cron a cada minuto envia o que venceu.
CREATE TABLE notifications (
  id                  bigserial PRIMARY KEY,
  user_id             bigint      NOT NULL REFERENCES users(id),
  reminder_id         bigint      REFERENCES reminders(id) ON DELETE CASCADE,
  supply_id           bigint,                        -- FK adicionada abaixo
  type                text        NOT NULL CHECK (type IN ('reminder','pre_alert','repeat','supply')),
  fire_at             timestamptz NOT NULL,
  state               text        NOT NULL DEFAULT 'pending'
                      CHECK (state IN ('pending','sent','acked','cancelled')),
  offset_minutes      integer,                       -- antecedencia, para pre_alert
  telegram_message_id bigint,
  sent_at             timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX notifications_due ON notifications (fire_at) WHERE state = 'pending';

-- Estoque de itens de uso continuo (ex.: vitamina D). O restante e calculado, nao descontado.
CREATE TABLE supplies (
  id              bigserial PRIMARY KEY,
  user_id         bigint        NOT NULL REFERENCES users(id),
  item            text          NOT NULL,
  units_total     integer       NOT NULL CHECK (units_total > 0),
  units_per_day   numeric(6,2)  NOT NULL DEFAULT 1 CHECK (units_per_day > 0),
  started_on      date          NOT NULL DEFAULT CURRENT_DATE,
  paused_days     integer       NOT NULL DEFAULT 0,
  alert_days      integer       NOT NULL DEFAULT 5,
  status          text          NOT NULL DEFAULT 'active' CHECK (status IN ('active','paused')),
  created_at      timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX supplies_user ON supplies (user_id, status);

ALTER TABLE notifications
  ADD CONSTRAINT notifications_supply_fk FOREIGN KEY (supply_id) REFERENCES supplies(id) ON DELETE CASCADE;

-- Restante e data do aviso, calculados a partir da data de inicio.
CREATE VIEW supplies_status AS
SELECT s.*,
       GREATEST(0, s.units_total - ((CURRENT_DATE - s.started_on) - s.paused_days) * s.units_per_day) AS units_left,
       s.started_on + s.paused_days
         + CEIL(s.units_total / s.units_per_day)::int                    AS runs_out_on,
       s.started_on + s.paused_days
         + CEIL(s.units_total / s.units_per_day)::int - s.alert_days      AS alert_on
FROM supplies s;
