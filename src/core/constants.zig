//! Centralized constants for the application.
//! All magic numbers and configuration values should be defined here.

/// Timer/render refresh interval in milliseconds (~60fps)
pub const TIMER_REFRESH_MS: i64 = 16;

/// Minimum elapsed time before showing WPM (milliseconds)
pub const MIN_WPM_MS: i64 = 500;

/// Legacy: former unread-queue size of the byte-wise parser (unused now).
pub const INPUT_QUEUE_SIZE: usize = 8;

/// Legacy alias of `INPUT_BUFFER_SIZE` kept for older callers.
pub const WEB_RING_BUFFER_SIZE: usize = INPUT_BUFFER_SIZE;

/// Byte buffer of the shared input parser (pending, not yet parsed bytes).
pub const INPUT_BUFFER_SIZE: usize = 4096;

/// Native pushed-back event queue (`Input.queueEvent`, e.g. keys typed
/// during the capability probe).
pub const INPUT_EVENT_QUEUE_SIZE: usize = 256;

/// Web event queue (bytes are parsed at push time and drained every tick;
/// the oldest events are dropped beyond this, e.g. on a huge paste).
pub const WEB_EVENT_QUEUE_SIZE: usize = 1024;

/// How long a trailing partial escape sequence (e.g. a lone ESC) may wait for
/// its continuation before it is resolved (lone ESC → Escape key).
pub const ESC_TIMEOUT_MS: i32 = 20;

/// Longest CSI/SS3 sequence accepted; longer ones are discarded.
pub const INPUT_MAX_CSI_LEN: usize = 128;

/// Longest APC/DCS/OSC string kept for interpretation; longer strings are
/// skipped until their terminator.
pub const INPUT_MAX_STRING_LEN: usize = 1024;

/// Upper bound for the startup capability probe (terminated early by DA1).
pub const CAPS_PROBE_TIMEOUT_MS: u32 = 300;

/// Legacy: former cap of words mode (kept for compatibility, no longer a
/// cap; word counts are bounded by `types.MAX_WORDS`).
pub const MAX_WORDS: usize = 50;

/// Legacy: former cap of sentences mode (no longer used as a cap).
pub const MAX_SENTENCES: usize = 10;

/// Legacy: former cap of code mode (no longer used as a cap).
pub const MAX_CODE_SNIPPETS: usize = 20;

/// Timed tests pull more words while the active word is within this many
/// words of the end of the target.
pub const ENDLESS_LOOKAHEAD_WORDS: usize = 30;

/// Letters that may be typed past the end of a word ("extra"); more are
/// ignored.
pub const MAX_EXTRA_LETTERS: u8 = 20;

/// Maximum count prefix in vim mode (e.g., 999j)
pub const MAX_VIM_COUNT: usize = 999;

/// Default terminal dimensions
pub const DEFAULT_TERM_WIDTH: usize = 80;
pub const DEFAULT_TERM_HEIGHT: usize = 24;

/// Idle poll wait time in milliseconds (when not actively typing)
pub const IDLE_POLL_MS: i64 = 250;
