CREATE TABLE IF NOT EXISTS session(
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  status TEXT NOT NULL,
  started_at_wall TEXT NOT NULL,
  stopped_at_wall TEXT,
  sample_rate INTEGER NOT NULL,
  last_committed_sample INTEGER NOT NULL DEFAULT 0,
  next_chunk_index INTEGER NOT NULL DEFAULT 0,
  recovery_count INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS chunks(
  chunk_index INTEGER PRIMARY KEY,
  path TEXT NOT NULL UNIQUE,
  sample_count INTEGER NOT NULL,
  byte_count INTEGER NOT NULL,
  sha256 TEXT NOT NULL,
  committed_at_wall TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS events(
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  type TEXT NOT NULL,
  sample_offset INTEGER NOT NULL,
  wall_time TEXT NOT NULL,
  payload_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS recovery_report(
  session_id TEXT PRIMARY KEY,
  status TEXT NOT NULL,
  last_committed_sample INTEGER NOT NULL,
  next_chunk_index INTEGER NOT NULL,
  observed_samples INTEGER NOT NULL,
  discarded_samples INTEGER NOT NULL,
  rpo_ms INTEGER NOT NULL,
  quarantined_files INTEGER NOT NULL,
  corrupt_chunks INTEGER NOT NULL,
  completed_at_wall TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS transcript_segments(
  segment_id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  start_sample INTEGER NOT NULL CHECK(start_sample >= 0),
  end_sample INTEGER NOT NULL CHECK(end_sample >= start_sample),
  start_ms INTEGER NOT NULL CHECK(start_ms = (start_sample * 1000 / 16000)),
  end_ms INTEGER NOT NULL CHECK(end_ms = (end_sample * 1000 / 16000)),
  text TEXT NOT NULL CHECK(length(trim(text)) > 0),
  raw_text TEXT NOT NULL,
  language TEXT NOT NULL,
  source TEXT NOT NULL,
  model_id TEXT NOT NULL,
  is_final INTEGER NOT NULL CHECK(is_final IN (0, 1)),
  created_at_wall TEXT NOT NULL,
  FOREIGN KEY(session_id) REFERENCES session(id)
);
CREATE TABLE IF NOT EXISTS media_assets(
  blob_id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('image', 'voice_thought')),
  state TEXT NOT NULL CHECK(state IN ('pending', 'committed', 'failed', 'missing', 'corrupt', 'tombstoned')),
  path TEXT NOT NULL UNIQUE,
  mime_type TEXT NOT NULL,
  byte_count INTEGER NOT NULL DEFAULT 0 CHECK(byte_count >= 0),
  sha256 TEXT NOT NULL DEFAULT '',
  created_at_wall TEXT NOT NULL,
  updated_at_wall TEXT NOT NULL,
  FOREIGN KEY(session_id) REFERENCES session(id)
);
CREATE TABLE IF NOT EXISTS capture_events(
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id TEXT NOT NULL UNIQUE,
  session_id TEXT NOT NULL,
  type TEXT NOT NULL CHECK(type IN ('image', 'thought', 'bookmark', 'voice_thought')),
  sample_offset INTEGER NOT NULL CHECK(sample_offset >= 0),
  at_ms INTEGER NOT NULL CHECK(at_ms = (sample_offset * 1000 / 16000)),
  monotonic_elapsed_ns INTEGER NOT NULL CHECK(monotonic_elapsed_ns >= 0),
  wall_time TEXT NOT NULL,
  clock_epoch_id TEXT NOT NULL,
  capture_state TEXT NOT NULL CHECK(capture_state IN ('pending', 'committed', 'failed', 'tombstoned')),
  asset_blob_id TEXT,
  display_after_segment TEXT,
  manual_adjustment INTEGER NOT NULL DEFAULT 0 CHECK(manual_adjustment IN (0, 1)),
  payload_json TEXT NOT NULL DEFAULT '{}',
  created_at_wall TEXT NOT NULL,
  updated_at_wall TEXT NOT NULL,
  FOREIGN KEY(session_id) REFERENCES session(id),
  FOREIGN KEY(asset_blob_id) REFERENCES media_assets(blob_id)
);
CREATE INDEX IF NOT EXISTS transcript_segments_timeline
ON transcript_segments(start_sample, end_sample);
CREATE INDEX IF NOT EXISTS capture_events_timeline
ON capture_events(sample_offset, monotonic_elapsed_ns, seq);
CREATE INDEX IF NOT EXISTS media_assets_session_state
ON media_assets(session_id, state);
