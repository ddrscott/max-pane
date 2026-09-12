//! Fractional ordinals.
//!
//! Lanes are ordered by a single `REAL`. Inserting between two lanes takes the
//! midpoint, so an insert writes one row instead of renumbering the strip. Doing
//! that repeatedly in the same gap halves the gap each time, and f64 runs out of
//! room after about 50 halvings, so the caller renormalizes when a gap gets
//! smaller than `MIN_GAP`.

/// Spacing between lanes after a renormalize, and between appended lanes.
pub const STEP: f64 = 1024.0;

/// Renormalize when an insert would produce a gap tighter than this. f64 has
/// plenty of headroom left here; the bound exists so we never approach the
/// point where midpoint(a, b) == a.
pub const MIN_GAP: f64 = 1e-6;

/// The ordinal that sits between `before` and `after`.
///
/// `None` on either side means "the end of the strip in that direction".
/// Returns `None` when the gap is too tight to subdivide, which is the caller's
/// signal to renormalize and retry.
pub fn between(before: Option<f64>, after: Option<f64>) -> Option<f64> {
    match (before, after) {
        (None, None) => Some(0.0),
        (Some(b), None) => Some(b + STEP),
        (None, Some(a)) => Some(a - STEP),
        (Some(b), Some(a)) => {
            if a - b < MIN_GAP {
                None
            } else {
                Some(b + (a - b) / 2.0)
            }
        }
    }
}

/// Evenly spaced ordinals for `count` lanes, preserving their current order.
pub fn renormalized(count: usize) -> Vec<f64> {
    (0..count).map(|i| i as f64 * STEP).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn appends_past_the_last_lane() {
        assert_eq!(between(Some(1024.0), None), Some(1024.0 + STEP));
    }

    #[test]
    fn prepends_before_the_first_lane() {
        assert_eq!(between(None, Some(0.0)), Some(-STEP));
    }

    #[test]
    fn first_lane_on_an_empty_strip_is_zero() {
        assert_eq!(between(None, None), Some(0.0));
    }

    #[test]
    fn splits_the_gap() {
        assert_eq!(between(Some(0.0), Some(1024.0)), Some(512.0));
    }

    #[test]
    fn refuses_to_split_an_exhausted_gap() {
        assert_eq!(between(Some(1.0), Some(1.0 + MIN_GAP / 2.0)), None);
    }

    #[test]
    fn repeated_inserts_in_one_gap_stay_ordered_until_exhaustion() {
        // Insert at the same spot over and over; every ordinal must stay
        // strictly between its neighbours until `between` gives up.
        let (lo, mut hi) = (0.0f64, STEP);
        let mut inserts = 0;
        while let Some(mid) = between(Some(lo), Some(hi)) {
            assert!(mid > lo && mid < hi, "midpoint left the gap");
            hi = mid;
            inserts += 1;
            if inserts > 1000 {
                break;
            }
        }

        // The budget is fixed by the two constants: halving STEP until the gap
        // drops below MIN_GAP takes ceil(log2(STEP / MIN_GAP)) steps. With
        // STEP = 1024 and MIN_GAP = 1e-6 that is 30. Nothing here is near the
        // f64 floor (~50 halvings would be); MIN_GAP is a PRD-chosen safety
        // margin, and renormalize resets the budget whenever it is spent.
        let budget = (STEP / MIN_GAP).log2().ceil() as u32;
        assert_eq!(budget, 30);
        assert_eq!(inserts, budget, "insert budget drifted from the constants");
    }

    #[test]
    fn renormalize_is_evenly_spaced_and_ascending() {
        let v = renormalized(4);
        assert_eq!(v, vec![0.0, STEP, 2.0 * STEP, 3.0 * STEP]);
    }
}
