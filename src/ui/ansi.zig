// ANSI
pub const RESET = "\x1b[0m";
pub const BOLD = "\x1b[1m";
pub const DIM = "\x1b[2m";
pub const UNDERLINE = "\x1b[4m";
pub const REVERSE = "\x1b[7m";
pub const HIDE_CURSOR = "\x1b[?25l";
pub const SHOW_CURSOR = "\x1b[?25h";
pub const CLEAR = "\x1b[2J\x1b[H";
pub const CLEAR_LINE = "\x1b[2K";
pub const SYNC_BEGIN = "\x1b[?2026h";
pub const SYNC_END = "\x1b[?2026l";

// Colors
pub const C_INDIGO = "\x1b[38;2;99;102;241m";
pub const C_GREEN = "\x1b[38;2;34;197;94m";
pub const C_RED = "\x1b[38;2;239;68;68m";
pub const C_YELLOW = "\x1b[38;2;250;204;21m";
pub const C_ORANGE = "\x1b[38;2;251;146;60m";
pub const C_CYAN = "\x1b[38;2;34;211;238m";
pub const C_DIM = "\x1b[38;2;100;100;120m";
pub const C_DIMMER = "\x1b[38;2;60;60;80m";
pub const C_WHITE = "\x1b[38;2;255;255;255m";
pub const C_BG_INDIGO = "\x1b[48;2;99;102;241m";
pub const C_BG_GREEN = "\x1b[48;2;34;197;94m";
pub const C_BG_RED = "\x1b[48;2;50;20;20m";
pub const C_BG_YELLOW = "\x1b[48;2;80;70;20m";
pub const C_BG_VISUAL = "\x1b[48;2;60;60;100m";
