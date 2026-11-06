//! A small, Zig-only interface to the vendored Elz interpreter.
//!
//! Each `Env` owns one Elz engine. The engine is not thread-safe, so
//! every call must stay on the thread that ran `init`.

const env = @import("env.zig");

pub const Environment = @import("contract").Environment;

pub const Env = env.Env;
pub const InitOptions = env.InitOptions;
pub const Error = env.Error;
pub const Skill = env.Skill;
pub const Foreign = env.Foreign;
pub const Handler = env.Handler;
pub const Tool = env.Tool;
pub const Help = env.Help;

test {
    _ = env;
}
