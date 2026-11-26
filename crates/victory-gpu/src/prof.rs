//! (Neptune) Sub-stage profiler of the frame's critical path, always on.
//!
//! The frame line splits a frame into "preparing", "on the GPU" and "copying back", and in a
//! heavy scene (4,600 draws, 150-180 ms a frame) most of the submitting thread's time was in
//! none of them: the wait for the list ahead of the frame (36 ms), the pass over records the
//! title copied into its heap (33 ms, before "preparing" starts) and some 60 ms of
//! "preparing" that was neither copies nor textures. This module names every stage of the
//! thread that runs the queues' lines (`victory-submit`) and of the thread that records the
//! list ahead of a frame (`victory-ahead`), in microseconds summed since the last report,
//! and says them in one line of `key=value` pairs (ms a frame) that `neptune-diag.ps1`
//! reads.
//!
//! Cost: one `Instant::now()` pair per stage per submission (some 30 submissions a frame,
//! about 25 stages: well under 0.05 ms a frame). No lock: relaxed atomic adds only, so it
//! takes no part in any lock order.

use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::time::Instant;

/// A stage whose time is summed.
#[derive(Clone, Copy)]
#[repr(usize)]
pub(crate) enum S {
    /// `Host::submit`: settling the flights before a submission (waited for, or blocked).
    SettleBefore,
    /// `descriptor::sync_heaps`, all of it.
    SyncHeaps,
    /// Of it: the write-watch question of the heaps' changed pages.
    SyncWatch,
    /// Of it: reading the changed pages and choosing the slots to look at (summed over threads).
    SyncPages,
    /// Of it: comparing and mirroring the chosen records (summed over threads).
    SyncMirror,
    /// `sweep` (and the settle made for it).
    Sweep,
    /// `descriptor::make_waiting`.
    MakeWaiting,
    /// `shadow::preparing` and `stamp::advance`.
    PreMisc,
    /// The submission's one write-watch asking (`VICTORY_ASK_ONCE`), with the stale check.
    AskOnce,
    /// Deferred steps, by kind, without the refreshes they flush (those are `Refresh`).
    StepCopy,
    StepFill,
    StepRun,
    StepHost,
    StepGpuWrite,
    StepTexture,
    /// Refreshes of host copies (`Batch::flush` and `flush_one`), wherever they run.
    Refresh,
    /// The step loop's own overhead: what the deferred steps took beyond the kinds above.
    StepLoop,
    /// `shadow::take_snapshots`.
    Snapshots,
    /// Flights settled in the middle of a submission (stale under flights, card results low).
    SettleMid,
    /// `Host::card_before`.
    CardBefore,
    /// `ExecuteCommandLists` and the fence signal of a submission sent ahead.
    Execute,
    /// What a submission sent ahead collects after its lists went (declared writes).
    Tail,
    /// `Host::execute_late` after `submit`: the line of flights, waits for the relay, landing.
    LateTail,
    /// Synchronous submissions: the wait for the card.
    SyncWait,
    /// `victory-submit` waiting for the list ahead of the frame (`queue::ahead_of_frame`).
    WaitAhead,
    /// `victory-submit` at a present, waiting for the frame's lists to be translated.
    WaitTranslations,
    /// `victory-submit` running the present job.
    Present,
    /// `victory-submit` with nothing to do (waiting to be woken).
    Idle,
    /// `victory-submit` in `release_held`, all of it (busy time of the lines).
    Lines,
    /// `victory-ahead`: planning the pass over the heap's buffer views.
    AheadPlan,
    /// `victory-ahead`: the slots of the pass (mirror, host copy lookup, bookkeeping).
    AheadSlots,
    /// `victory-ahead`: the spans of the host copies the views read, and their refreshes.
    AheadSpans,
    /// `victory-ahead`: the pass over textures picked by index.
    AheadTextures,
}

/// Stages ([`S`]).
const STAGES: usize = S::AheadTextures as usize + 1;

/// Counts summed with the stages.
#[derive(Clone, Copy)]
#[repr(usize)]
pub(crate) enum C {
    /// Submissions prepared (`Host::submit`).
    Submissions,
    /// Deferred steps run.
    Steps,
    /// Slots the pass over the heap's buffer views looked at.
    AheadDue,
    /// Records `sync_heaps` mirrored.
    SyncMirrored,
}

const COUNTS: usize = C::SyncMirrored as usize + 1;

static US: [AtomicU64; STAGES] = [const { AtomicU64::new(0) }; STAGES];
static N: [AtomicU64; COUNTS] = [const { AtomicU64::new(0) }; COUNTS];

/// Adds the time since `since` to `stage`; returns now, for the next stage.
#[inline]
pub(crate) fn lap(stage: S, since: Instant) -> Instant {
    let now = Instant::now();
    US[stage as usize].fetch_add(now.saturating_duration_since(since).as_micros() as u64, Relaxed);
    now
}

/// Adds `micros` to `stage`.
#[inline]
pub(crate) fn add_us(stage: S, micros: u64) {
    US[stage as usize].fetch_add(micros, Relaxed);
}

/// Adds `n` to count `c`.
#[inline]
pub(crate) fn count(c: C, n: u64) {
    N[c as usize].fetch_add(n, Relaxed);
}

thread_local! {
    /// Microseconds of refreshes run on this thread so far ([`S::Refresh`]): a step that
    /// flushes refreshes has their time taken out of its own.
    static REFRESHED: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// Refreshes took `micros` on this thread ([`S::Refresh`]).
#[inline]
pub(crate) fn refreshed(micros: u64) {
    US[S::Refresh as usize].fetch_add(micros, Relaxed);
    REFRESHED.with(|r| r.set(r.get() + micros));
}

/// The refresh microseconds this thread has run so far.
#[inline]
pub(crate) fn refreshed_so_far() -> u64 {
    REFRESHED.with(std::cell::Cell::get)
}

/// The names in the line, by stage.
const NAMES: [&str; STAGES] = [
    "settle",
    "sync_heaps",
    "sync_watch",
    "sync_pages",
    "sync_mirror",
    "sweep",
    "make_waiting",
    "pre_misc",
    "ask_once",
    "step_copy",
    "step_fill",
    "step_run",
    "step_host",
    "step_gpu_write",
    "step_texture",
    "refresh",
    "step_loop",
    "snapshots",
    "settle_mid",
    "card_before",
    "execute",
    "tail",
    "late_tail",
    "sync_wait",
    "wait_ahead",
    "wait_translations",
    "present",
    "idle",
    "lines",
    "ahead_plan",
    "ahead_slots",
    "ahead_spans",
    "ahead_textures",
];

const COUNT_NAMES: [&str; COUNTS] = ["submissions", "steps", "ahead_due", "sync_mirrored"];

/// The line, over `frames` frames: every stage in ms a frame, every count a frame.
pub(crate) fn line(frames: f64) {
    if frames <= 0.0 {
        return;
    }
    use std::fmt::Write;
    let mut text = String::with_capacity(768);
    for (name, us) in NAMES.iter().zip(US.iter()) {
        let _ = write!(text, " {name}={:.2}", us.swap(0, Relaxed) as f64 / 1000.0 / frames);
    }
    for (name, n) in COUNT_NAMES.iter().zip(N.iter()) {
        let _ = write!(text, " {name}={:.1}", n.swap(0, Relaxed) as f64 / frames);
    }
    tracing::info!("neptune profile ms/frame:{text}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_stage_and_count_has_a_name() {
        assert_eq!(NAMES.len(), STAGES);
        assert_eq!(COUNT_NAMES.len(), COUNTS);
        let mut all: Vec<&str> = NAMES.iter().chain(COUNT_NAMES.iter()).copied().collect();
        all.sort_unstable();
        all.dedup();
        assert_eq!(all.len(), STAGES + COUNTS, "names are unique");
    }
}
