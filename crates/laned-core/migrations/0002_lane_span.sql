-- PRD §13 Phase 3: lane spanning (2x width) for the rare landscape site.
--
-- A deliberate, narrow exception to the design invariant in §1 — "a lane is a
-- portrait-bounded column" — for content that genuinely cannot be read in
-- portrait: a wide dashboard, a timeline, a diff. `span` multiplies LANE_MAX for
-- one lane and nothing else; there is no span 3, and the default stays 1 so the
-- invariant holds everywhere the user has not deliberately opted out.
ALTER TABLE lane ADD COLUMN span INTEGER NOT NULL DEFAULT 1;
