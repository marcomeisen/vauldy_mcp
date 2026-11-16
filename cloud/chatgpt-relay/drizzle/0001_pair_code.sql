ALTER TABLE pairs ADD COLUMN pairing_code_hash TEXT;
--> statement-breakpoint
ALTER TABLE pairs ADD COLUMN confirmation_attempts INTEGER NOT NULL DEFAULT 0;
