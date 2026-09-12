-- A lane held at the left or right edge of the window instead of scrolling with
-- the strip — and the rename that had to come with it.
--
-- `pinned` meant exactly one thing in this schema: "never evict this lane's web
-- panes". It means something else in the owner's vocabulary — *"but pinning i
-- mean docking a pane to the left or right side"* — and two meanings of one
-- word in one app is how someone pins a lane and then wonders why it did not
-- move. The word goes to the feature that was named after it; the memory flag
-- takes the name it should have had. `keep_live` and not `never_evict`, because
-- it is a statement about what the lane keeps, not about a policy that may be
-- rewritten around it.
--
-- Renamed in place rather than added-and-backfilled. A second column with the
-- old one left behind is how a lane ends up protected in the table and
-- unprotected in the record six months later, and every SQLite this crate can
-- link against has rewritten a column name since 3.25.
--
-- `dock_side` alone answers "is this lane docked": a lane with a side has a
-- mode and a width, a lane without has neither. One nullable column and no
-- boolean beside it, because `docked = 1, dock_side = NULL` is a state nothing
-- can draw and therefore nothing should be able to write.
--
-- The unique index is the real guarantee, and it is here rather than in Rust on
-- purpose. Two lanes docked to the same edge is not a rendering conflict to be
-- resolved at layout time — it is a window that cannot be drawn — so the ledger
-- is where it is made unrepresentable, including against a future caller that
-- forgets to check. Partial, because every undocked lane holds NULL here and
-- NULLs do not collide with each other.
--
-- No default for `dock_width_pt`: a docked lane is born at the width the lane
-- already had, which is a fact about that lane and not a constant. See
-- `Core::dock_lane` for why docking must not reflow the page.
ALTER TABLE lane RENAME COLUMN pinned TO keep_live;
ALTER TABLE lane ADD COLUMN dock_side TEXT;      -- NULL | 'left' | 'right'
ALTER TABLE lane ADD COLUMN dock_mode TEXT;      -- 'overlay' | 'inset'
ALTER TABLE lane ADD COLUMN dock_width_pt INTEGER;

CREATE UNIQUE INDEX lane_dock_side ON lane(dock_side) WHERE dock_side IS NOT NULL;
