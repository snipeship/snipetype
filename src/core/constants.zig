//! Centralized constants for the application.
//! All magic numbers and configuration values should be defined here.

/// Timer/render refresh interval in milliseconds (~60fps)
pub const TIMER_REFRESH_MS: i64 = 16;

/// Minimum elapsed time before showing WPM (milliseconds)
pub const MIN_WPM_MS: i64 = 500;

/// Input queue size for escape sequence parsing
pub const INPUT_QUEUE_SIZE: usize = 8;

/// Ring buffer size for web input (bytes)
pub const WEB_RING_BUFFER_SIZE: usize = 4096;

/// Maximum words in words mode
pub const MAX_WORDS: usize = 50;

/// Maximum sentences in sentences mode
pub const MAX_SENTENCES: usize = 10;

/// Maximum code snippets in code mode
pub const MAX_CODE_SNIPPETS: usize = 20;

/// Maximum count prefix in vim mode (e.g., 999j)
pub const MAX_VIM_COUNT: usize = 999;

/// Default terminal dimensions
pub const DEFAULT_TERM_WIDTH: usize = 80;
pub const DEFAULT_TERM_HEIGHT: usize = 24;

/// Idle poll wait time in milliseconds (when not actively typing)
pub const IDLE_POLL_MS: i64 = 250;
