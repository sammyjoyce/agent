//! Offline adapter harness: stdin is PollSources JSON; PATH supplies an invented feed.
use std::io::{self, Read};
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let request = serde_json::from_str(&input)?;
    let response = agent_cli::background::execute(request).await?;
    println!("{}", serde_json::to_string(&response)?);
    Ok(())
}
