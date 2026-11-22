//! Node capabilities come from the machine, while Rex owns its peer inventory.

use std::path::Path;

use crate::{
    config,
    protocol::{AgentNode, WorkerLaunch},
    rex::{HostId, RexClient},
};
use anyhow::{Context, Result, ensure};

pub async fn local_node(
    rex: &RexClient,
    coordinator: Option<&str>,
    launch: WorkerLaunch,
    name: Option<&str>,
    daemon: &crate::tailnet::Daemon,
) -> Result<AgentNode> {
    let identity = rex.whoami().await?;
    let inventory = rex.peer_inventory().await;
    let peer = inventory.as_ref().and_then(|hosts| {
        hosts
            .iter()
            .find(|peer| peer.host_id.as_deref() == Some(&identity.host_id.to_string()))
    });
    let native_name = identity
        .tailscale
        .as_ref()
        .and_then(|tailnet| tailnet.dns_name.as_deref())
        .and_then(|name| name.split('.').next())
        .filter(|name| !name.is_empty())
        .map(|name| name.strip_suffix("-rex").unwrap_or(name).to_owned());
    let name = name
        .map(str::to_owned)
        .or_else(|| {
            peer.filter(|peer| !peer.label.trim().is_empty())
                .map(|peer| peer.label.clone())
        })
        .or(native_name)
        .unwrap_or_else(|| "local".into());
    // Apps reach a node's Rex at its SSH or Tailscale/peer address, whereas a
    // local-only private Unix server never announces an address.
    let endpoint = if let Some(ssh) = rex.ssh_endpoint() {
        Some(ssh.to_owned())
    } else if rex.is_private() {
        None
    } else {
        identity
            .tailscale
            .as_ref()
            .and_then(|tailnet| tailnet.https.as_ref())
            .filter(|https| https.state == "available")
            .and_then(|https| https.url.clone())
            .or_else(|| select_peer_endpoint(peer.and_then(|peer| peer.endpoints.as_deref())))
    };
    let node = AgentNode {
        host_id: identity.host_id.to_string(),
        name,
        rex_server: endpoint,
        agent_program: config::program()?.to_string_lossy().into_owned(),
        home_directory: dirs::home_dir()
            .context("No home directory is available")?
            .to_string_lossy()
            .into_owned(),
        coordinator: coordinator.map(str::to_owned),
        launch,
        capabilities: Some(crate::protocol::WorkerCapabilities {
            resume_agent: true,
            browser: true,
            browser_user_tabs: true,
            browser_screenshots: true,
        }),
        machine: crate::machines::observe(daemon).await.ok(),
    };
    validate_node(&node)?;
    Ok(node)
}

fn select_peer_endpoint(endpoints: Option<&[String]>) -> Option<String> {
    let endpoints = endpoints?;
    endpoints
        .iter()
        .find(|endpoint| !endpoint.starts_with("unix://") && !endpoint.trim().is_empty())
        .cloned()
        .or_else(|| endpoints.first().cloned())
}

pub fn validate_node(node: &AgentNode) -> Result<()> {
    HostId::parse(&node.host_id)?;
    ensure!(
        !node.name.trim().is_empty()
            && node.name.len() <= 128
            && !node.name.chars().any(char::is_control),
        "Node needs a bounded, readable name"
    );
    ensure!(
        Path::new(&node.agent_program).is_absolute()
            && Path::new(&node.home_directory).is_absolute(),
        "Node program and home directory must be absolute paths"
    );
    for path in [
        &node.launch.state_dir,
        &node.launch.runtime,
        &node.launch.config,
        &node.launch.instructions,
    ]
    .into_iter()
    .flatten()
    {
        ensure!(
            Path::new(path).is_absolute(),
            "Node launch paths must be absolute"
        );
    }
    if let Some(coordinator) = &node.coordinator {
        config::validate_coordinator(coordinator)?;
    }
    if let Some(model) = &node.launch.model {
        model.validate()?;
    }
    Ok(())
}

#[cfg(test)]
#[allow(clippy::disallowed_methods)]
mod tests {
    use super::local_node;
    use crate::{protocol::WorkerLaunch, rex::RexClient, rex::fake_rex};

    #[tokio::test]
    async fn a_private_node_announces_no_rex_address_and_reads_no_peer_inventory() {
        const TEST: &str =
            "discovery::tests::a_private_node_announces_no_rex_address_and_reads_no_peer_inventory";
        let Some(case) = fake_rex::case() else {
            for case in ["private", "personal"] {
                fake_rex::run(TEST, case, &[]);
            }
            return;
        };
        let rex = RexClient::for_process(if case == "private" {
            Some("unix:///run/user/1000/rex-agent/server.sock")
        } else if case == "ssh-explicit" {
            Some("ssh://alice@worker.example.invalid")
        } else {
            None
        })
        .unwrap();
        let daemon =
            crate::tailnet::Daemon::new(Some(std::path::Path::new("/nonexistent/tailscaled.sock")))
                .unwrap();
        let launch = WorkerLaunch {
            state_dir: None,
            runtime: None,
            config: None,
            instructions: None,
            model: None,
        };
        let node = local_node(&rex, None, launch, None, &daemon).await.unwrap();
        assert_eq!(node.host_id, fake_rex::HOST);
        if case == "private" {
            assert_eq!(node.rex_server, None);
            assert_eq!(node.name, "fixture-node");
            assert_eq!(fake_rex::methods(), ["whoami"]);
        } else if case == "ssh-peer" {
            assert_eq!(
                node.rex_server.as_deref(),
                Some("ssh://worker.example.invalid:2222")
            );
            assert_eq!(node.name, "fixture-peer");
            assert_eq!(fake_rex::methods(), ["whoami", "hosts"]);
        } else if case == "ssh-explicit" {
            assert_eq!(
                node.rex_server.as_deref(),
                Some("ssh://alice@worker.example.invalid")
            );
            assert_eq!(node.name, "local");
            assert_eq!(fake_rex::methods(), ["whoami"]);
        } else {
            assert_eq!(
                node.rex_server.as_deref(),
                Some("https://fixture-node.example.ts.net")
            );
            assert_eq!(node.name, "fixture-peer");
            assert_eq!(fake_rex::methods(), ["whoami", "hosts"]);
        }
    }

    #[tokio::test]
    async fn ssh_workers_without_tailscale_discover_ssh_endpoints() {
        const TEST: &str =
            "discovery::tests::a_private_node_announces_no_rex_address_and_reads_no_peer_inventory";
        for (case, envs) in [
            (
                "ssh-peer",
                &[
                    ("AGENT_TEST_FAKE_REX_NO_TAILSCALE", "1"),
                    ("AGENT_TEST_FAKE_REX_SSH_PEER", "1"),
                ][..],
            ),
            (
                "ssh-explicit",
                &[
                    ("AGENT_TEST_FAKE_REX_NO_TAILSCALE", "1"),
                    (
                        "AGENT_TEST_FAKE_REX_EXPLICIT_SSH",
                        "ssh://alice@worker.example.invalid",
                    ),
                ][..],
            ),
        ] {
            if fake_rex::case().is_none() {
                fake_rex::run(TEST, case, envs);
            }
        }
    }
}
