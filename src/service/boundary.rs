//! Service-boundary handlers for requests answered directly by the coordinator
//! without crossing into the Pi runtime (local service status).

use anyhow::Result;
use tokio::io::AsyncWrite;

use crate::{
    broker::Broker,
    native::{NativeEvent, ServiceRequest},
    protocol::ErrorCode,
    runtime::Runtime,
};

pub(super) async fn handle<W: AsyncWrite + Unpin>(
    writer: &mut W,
    runtime: &Runtime,
    broker: &Broker,
    request: ServiceRequest,
) -> Result<()> {
    let outcome: std::result::Result<NativeEvent, (ErrorCode, String)> = match request {
        ServiceRequest::ServiceStatus => {
            let executable_path = std::env::current_exe().ok().map(|path| {
                path.canonicalize()
                    .unwrap_or(path)
                    .to_string_lossy()
                    .into_owned()
            });
            Ok(NativeEvent::ServiceStatus {
                coordinator_id: runtime.coordinator_id().to_string(),
                pid: std::process::id(),
                version: env!("CARGO_PKG_VERSION").to_owned(),
                executable_path,
                state_dir: broker.state_dir().to_string_lossy().into_owned(),
            })
        }
    };
    match outcome {
        Ok(event) => super::write_client_frame(writer, &event, runtime).await?,
        Err((code, message)) => {
            super::write_client_frame(
                writer,
                &NativeEvent::Failure {
                    code: Some(code),
                    message,
                },
                runtime,
            )
            .await?;
        }
    }
    super::write_client_frame(writer, &NativeEvent::Done, runtime).await
}
