use agent_cli::{host::Executor, protocol::HostCommand, rex::RexClient};
use std::io::{self, BufRead};
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let endpoint = std::env::var("AGENT_TEST_REX_SERVER")?;
    let state = std::env::var("AGENT_TEST_WORKSPACE_STATE")?;
    #[allow(clippy::disallowed_methods)] // This fixture is its own process selection boundary.
    let executor = Executor::new(
        std::path::Path::new(&state),
        RexClient::for_process(Some(&endpoint))?,
    );
    for line in io::stdin().lock().lines() {
        let command: HostCommand = serde_json::from_str(&line?)?;
        println!(
            "{}",
            serde_json::to_string(&executor.execute(command).await)?
        );
    }
    Ok(())
}
