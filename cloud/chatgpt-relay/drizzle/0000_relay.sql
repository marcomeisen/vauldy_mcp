CREATE TABLE pairs (id TEXT PRIMARY KEY, challenge TEXT NOT NULL, public_key TEXT NOT NULL, expires INTEGER NOT NULL, owner TEXT, token_hash TEXT);
--> statement-breakpoint
CREATE INDEX pairs_expiry ON pairs(expires);
--> statement-breakpoint
CREATE TABLE devices (id TEXT PRIMARY KEY, owner TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE, public_key TEXT NOT NULL, created INTEGER NOT NULL, expires INTEGER NOT NULL, last_seen INTEGER NOT NULL DEFAULT 0, revoked INTEGER NOT NULL DEFAULT 0);
--> statement-breakpoint
CREATE INDEX devices_owner ON devices(owner,revoked,created);
--> statement-breakpoint
CREATE TABLE jobs (id TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id), public_key TEXT NOT NULL, request TEXT NOT NULL, result TEXT, expires INTEGER NOT NULL, claimed INTEGER NOT NULL DEFAULT 0);
--> statement-breakpoint
CREATE INDEX jobs_device_expiry ON jobs(device_id,expires);
--> statement-breakpoint
CREATE INDEX jobs_expiry ON jobs(expires);
