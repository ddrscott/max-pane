-- A web pane's sound: whether it is muted, and how loud it is, 0 to 100.
--
-- In `Pane` beside `zoom` and `mobile`, for their reason: the shell needs both
-- before the page makes its first noise, and a lane muted yesterday that is
-- blaring at launch is the bug the mute exists to prevent. One migration for
-- the pair because they are one decision: `volume` is the last level that was
-- not silence, which is what unmuting returns to, so a slider dragged to zero
-- is `muted = 1` with the level it came from kept.
--
-- A private lane's pane is a row like any other until the next open
-- (ADR-0016), so it takes the same path and goes with the lane.
ALTER TABLE pane ADD COLUMN muted INTEGER NOT NULL DEFAULT 0;
ALTER TABLE pane ADD COLUMN volume INTEGER NOT NULL DEFAULT 100;
