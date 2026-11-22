//! Optional Rex Lua action helpers (task picker and quick main-chat prompt).
//! Kept separate from core execution and durable approvals because `rex.ui`
//! requires an attached Rex client and `client.perform` requires Remote Control.

pub const MODULE: &str = include_str!("actions.lua");

#[cfg(test)]
mod tests {
    use super::MODULE;

    #[test]
    fn actions_module_defines_picker_and_quick_prompt_outside_core_execution() {
        assert!(MODULE.contains("rex.ui.pick"));
        assert!(MODULE.contains("rex.ui.input"));
        assert!(MODULE.contains("session.select"));
        assert!(MODULE.contains("agent_jump_to_task"));
        assert!(MODULE.contains("agent_quick_prompt"));
        assert!(!MODULE.contains("agent_messages"));
    }

    #[test]
    #[ignore = "requires the installed native Rex CLI"]
    fn actions_module_passes_native_rex_config_check() {
        use crate::serialized_spawn::SerializedSpawn;
        let directory = tempfile::tempdir().unwrap();
        let module = directory.path().join("agent_actions.lua");
        let init = directory.path().join("init.lua");
        std::fs::write(&module, MODULE).unwrap();
        std::fs::write(&init, "require('agent_actions')\n").unwrap();
        let output = std::process::Command::new("rex")
            .args(["config", "check"])
            .arg(&init)
            .arg("--json")
            .output_serialized()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let checked: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(checked["diagnostics"].as_array().unwrap().len(), 0);
        let names: Vec<_> = checked["actions"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|action| action["name"].as_str())
            .collect();
        assert!(names.contains(&"agent_jump_to_task"), "{names:?}");
        assert!(names.contains(&"agent_quick_prompt"), "{names:?}");
    }
}
