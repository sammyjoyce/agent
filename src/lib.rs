extern crate self as agent_cli;

pub mod attachments;
pub mod backup;
pub mod chat_commands;
pub mod config;
pub mod context;
pub mod coordinator_id;
pub mod discovery;
pub mod dreams;
pub mod embeddings;
pub mod failover;
pub mod feedback;
pub mod goal_view;
pub mod history;
pub mod host;
pub mod models;
pub mod owner_floor;
pub mod protocol;
pub mod resources;
pub mod rex;
pub mod runtime;
pub mod scrawl_feedback;
pub mod serialized_spawn;
pub mod service;

pub mod background;
pub mod broker;
pub mod browser;
pub mod callback;
pub mod instructions;
pub mod intake;
pub mod job_view;
pub mod jobs;
pub mod machines;
pub mod source_view;
pub mod sources;
pub mod tailnet;
pub mod task_graph_view;
pub mod tui;
pub mod usage;

pub mod native;
pub mod notifications;

#[cfg(test)]
#[path = "../tests/fixtures/executable.rs"]
mod executable_fixture;

#[cfg(test)]
#[path = "../tests/fixtures/hang_limit.rs"]
mod hang_limit;

#[cfg(test)]
pub(crate) use hang_limit::TEST_HANG_LIMIT;
