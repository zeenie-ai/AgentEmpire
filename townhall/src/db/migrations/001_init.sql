-- Aurelhaven Town Hall schema, version 1.

CREATE TABLE event_log (
  seq          INTEGER PRIMARY KEY AUTOINCREMENT,
  id           TEXT NOT NULL UNIQUE,
  type         TEXT NOT NULL,
  time         TEXT NOT NULL,
  subject      TEXT,
  causation_id TEXT,
  payload      TEXT NOT NULL
);

CREATE TRIGGER event_log_no_update BEFORE UPDATE ON event_log
BEGIN
  SELECT RAISE(ABORT, 'event_log is append-only');
END;

CREATE TRIGGER event_log_no_delete BEFORE DELETE ON event_log
BEGIN
  SELECT RAISE(ABORT, 'event_log is append-only');
END;

CREATE TABLE agents (
  id                   TEXT PRIMARY KEY,
  name                 TEXT NOT NULL,
  provider             TEXT NOT NULL,
  model                TEXT NOT NULL,
  role                 TEXT NOT NULL,
  instructions         TEXT NOT NULL,
  approval_mode        TEXT NOT NULL,
  workspace_path       TEXT NOT NULL,
  workspace_mode       TEXT NOT NULL,
  repo_root            TEXT,
  workspace_sub        TEXT NOT NULL DEFAULT '',
  mirror_path          TEXT,
  workspace_ready      INTEGER NOT NULL DEFAULT 0,
  workspace_error      TEXT,
  seals_json           TEXT NOT NULL,
  billing              TEXT NOT NULL,
  lifecycle            TEXT NOT NULL,
  activity             TEXT NOT NULL,
  blocked_reason       TEXT,
  home_tile_json       TEXT,
  home_built           INTEGER NOT NULL DEFAULT 0,
  xp                   INTEGER NOT NULL DEFAULT 0,
  level                INTEGER NOT NULL DEFAULT 1,
  rank                 TEXT NOT NULL DEFAULT 'F',
  stats_json           TEXT NOT NULL,
  party_id             TEXT,
  grace                INTEGER NOT NULL DEFAULT 0,
  cost_json            TEXT NOT NULL,
  starting_tools_json  TEXT NOT NULL,
  retire_after_current INTEGER NOT NULL DEFAULT 0,
  version              INTEGER NOT NULL DEFAULT 1,
  created_at           TEXT NOT NULL,
  retired_at           TEXT
);

CREATE TABLE tool_addons (
  id                  TEXT PRIMARY KEY,
  agent_id            TEXT NOT NULL REFERENCES agents(id),
  type                TEXT NOT NULL,
  status              TEXT NOT NULL,
  tile_json           TEXT NOT NULL,
  config_json         TEXT,
  config_summary_json TEXT,
  health_json         TEXT,
  cost_json           TEXT NOT NULL,
  free                INTEGER NOT NULL DEFAULT 0,
  created_at          TEXT NOT NULL,
  built_at            TEXT,
  removed_at          TEXT
);
CREATE INDEX tool_addons_agent ON tool_addons(agent_id);

CREATE TABLE tasks (
  id                  TEXT PRIMARY KEY,
  agent_id            TEXT NOT NULL REFERENCES agents(id),
  party_id            TEXT,
  parent_task_id      TEXT,
  depth               INTEGER NOT NULL DEFAULT 0,
  title               TEXT NOT NULL,
  prompt              TEXT NOT NULL,
  prompt_hash         TEXT NOT NULL,
  size                TEXT NOT NULL,
  acceptance_json     TEXT NOT NULL,
  rite                TEXT,
  state               TEXT NOT NULL,
  state_reason        TEXT,
  attempt             INTEGER NOT NULL DEFAULT 1,
  seal_micros         INTEGER NOT NULL,
  reserved_micros     INTEGER NOT NULL DEFAULT 0,
  spent_micros        INTEGER NOT NULL DEFAULT 0,
  spent_is_estimate   INTEGER NOT NULL DEFAULT 1,
  seal_warned         INTEGER NOT NULL DEFAULT 0,
  courier_json        TEXT NOT NULL,
  queue_pos           REAL NOT NULL DEFAULT 0,
  created_at          TEXT NOT NULL,
  delivered_at        TEXT,
  started_at          TEXT,
  finished_at         TEXT,
  updated_at          TEXT NOT NULL,
  run_ms              INTEGER NOT NULL DEFAULT 0,
  run_started_at      TEXT,
  result_json         TEXT,
  rewards_json        TEXT,
  session_id          TEXT,
  provider_state_json TEXT,
  pending_feedback    TEXT,
  workspace_json      TEXT,
  rift_retries        INTEGER NOT NULL DEFAULT 0,
  subtasks_total      INTEGER NOT NULL DEFAULT 0,
  accepted_at         TEXT,
  reward_rp           INTEGER,
  role_at_accept      TEXT,
  mana_used_micros    INTEGER,
  baseline_micros     INTEGER,
  version             INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX tasks_agent_state ON tasks(agent_id, state);
CREATE INDEX tasks_parent ON tasks(parent_task_id);
CREATE INDEX tasks_accepted ON tasks(accepted_at);

CREATE TABLE task_events (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id TEXT NOT NULL,
  time    TEXT NOT NULL,
  kind    TEXT NOT NULL,
  text    TEXT NOT NULL
);
CREATE INDEX task_events_task ON task_events(task_id, id);

CREATE TABLE approvals (
  id                 TEXT PRIMARY KEY,
  task_id            TEXT NOT NULL,
  agent_id           TEXT NOT NULL,
  attempt            INTEGER NOT NULL,
  tool               TEXT NOT NULL,
  category           TEXT NOT NULL,
  risk               TEXT NOT NULL,
  summary            TEXT NOT NULL,
  input_preview      TEXT NOT NULL,
  input_hash         TEXT NOT NULL,
  signature          TEXT NOT NULL,
  reason             TEXT,
  status             TEXT NOT NULL,
  scopes_json        TEXT NOT NULL,
  seal_exhausted     INTEGER NOT NULL DEFAULT 0,
  decision           TEXT,
  scope              TEXT,
  resolved_by        TEXT,
  message            TEXT,
  updated_input_json TEXT,
  created_at         TEXT NOT NULL,
  resolved_at        TEXT
);
CREATE INDEX approvals_status ON approvals(status);
CREATE INDEX approvals_task ON approvals(task_id);

CREATE TABLE approval_rules (
  id         TEXT PRIMARY KEY,
  kind       TEXT NOT NULL,            -- task | agent | pre_approval
  agent_id   TEXT NOT NULL,
  task_id    TEXT,
  tool       TEXT NOT NULL,
  category   TEXT NOT NULL,
  signature  TEXT,
  input_hash TEXT,
  decision   TEXT NOT NULL,
  message    TEXT,
  uses_left  INTEGER,
  expires_at TEXT,
  created_at TEXT NOT NULL,
  used_at    TEXT
);
CREATE INDEX approval_rules_agent ON approval_rules(agent_id, kind);

CREATE TABLE ledger (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  time        TEXT NOT NULL,
  op_id       TEXT UNIQUE,
  kind        TEXT NOT NULL,
  reason      TEXT NOT NULL,
  ref         TEXT,
  spend_op_id TEXT,
  food        INTEGER NOT NULL DEFAULT 0,
  wood        INTEGER NOT NULL DEFAULT 0,
  stone       INTEGER NOT NULL DEFAULT 0,
  gold        INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX ledger_one_refund_per_spend ON ledger(spend_op_id) WHERE spend_op_id IS NOT NULL;

CREATE TRIGGER ledger_no_update BEFORE UPDATE ON ledger
BEGIN
  SELECT RAISE(ABORT, 'ledger is append-only');
END;

CREATE TRIGGER ledger_no_delete BEFORE DELETE ON ledger
BEGIN
  SELECT RAISE(ABORT, 'ledger is append-only');
END;

CREATE TABLE budget_periods (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  kind               TEXT NOT NULL,
  refill_hour        INTEGER NOT NULL,
  period_start       TEXT NOT NULL,
  period_end         TEXT NOT NULL,
  pool_micros        INTEGER NOT NULL,
  carried_in_micros  INTEGER NOT NULL DEFAULT 0,
  cap_micros         INTEGER NOT NULL,
  spent_micros       INTEGER NOT NULL DEFAULT 0,
  overdraft_micros   INTEGER NOT NULL DEFAULT 0,
  by_provider_json   TEXT NOT NULL,
  closed_at          TEXT
);

CREATE TABLE incidents (
  id          TEXT PRIMARY KEY,
  kind        TEXT NOT NULL,
  severity    TEXT NOT NULL,
  agent_id    TEXT,
  task_id     TEXT,
  key         TEXT NOT NULL,
  message     TEXT NOT NULL,
  opened_at   TEXT NOT NULL,
  resolved_at TEXT
);
CREATE UNIQUE INDEX incidents_open_key ON incidents(key) WHERE resolved_at IS NULL;

CREATE TABLE parties (
  id              TEXT PRIMARY KEY,
  lead_agent_id   TEXT NOT NULL,
  member_ids_json TEXT NOT NULL,
  created_at      TEXT NOT NULL,
  disbanded_at    TEXT
);

CREATE TABLE town_saves (
  rev            INTEGER PRIMARY KEY,
  schema_version INTEGER NOT NULL,
  snapshot_json  TEXT NOT NULL,
  created_at     TEXT NOT NULL
);

CREATE TABLE settings (
  key        TEXT PRIMARY KEY,
  value_json TEXT NOT NULL
);

-- Internal Town Hall state that is not a player setting (age, budget config, Quartermaster market).
CREATE TABLE town_state (
  key        TEXT PRIMARY KEY,
  value_json TEXT NOT NULL
);
