use clap::ValueEnum;
use serde::Serialize;

use crate::gate::{Discount, Gate, GateDefinition, Mark};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum Scenario {
    ChiefCold,
    Chief,
    LongHistory,
}

const CONVERSATION_VISIBLE: &[GateDefinition] = &[GateDefinition {
    gate: Gate::ConversationVisible,
    from: Mark::Spawn,
    to: Mark::StoredTextVisible,
    discount: Discount::None,
}];

impl Scenario {
    pub fn sentence(self) -> &'static str {
        match self {
            Self::ChiefCold | Self::Chief => "Stored chief conversation is ready.",
            Self::LongHistory => "Stored long conversation is ready.",
        }
    }

    pub fn gates(self) -> &'static [GateDefinition] {
        match self {
            Self::ChiefCold | Self::Chief | Self::LongHistory => CONVERSATION_VISIBLE,
        }
    }
}
