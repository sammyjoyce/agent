//! Service-boundary handlers for requests answered directly by the coordinator
//! without crossing into the Pi runtime (Dreams review/apply and local service status).

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
        ServiceRequest::DreamsList => {
            crate::dreams::ops::native_list(broker.state_dir(), broker.dreams_policy())
                .await
                .map(|(runs, pending_count)| NativeEvent::DreamsList {
                    runs,
                    pending_count,
                })
                .map_err(classify_dreams_error)
        }
        ServiceRequest::DreamsShow { run } => {
            crate::dreams::ops::native_show(broker.state_dir(), broker.dreams_policy(), &run)
                .await
                .map(|detail| NativeEvent::DreamsShow {
                    report: Box::new(detail),
                })
                .map_err(classify_dreams_error)
        }
        ServiceRequest::DreamsApply { run, approve } => {
            if runtime.restore_held() {
                Err((
                    ErrorCode::CoordinatorUnavailable,
                    "Dreams apply is held after a restore until `backup release`".into(),
                ))
            } else {
                match broker.dreams_policy() {
                    None => Err((
                        ErrorCode::InvalidRequest,
                        "Dreams is not configured on this coordinator".into(),
                    )),
                    Some(policy) => {
                        crate::dreams::ops::native_apply(broker.state_dir(), policy, &run, &approve)
                            .await
                            .map(|applied| NativeEvent::DreamsApplied {
                                run: applied.run,
                                commit: applied.commit,
                                already_applied: applied.already_applied,
                            })
                            .map_err(classify_dreams_error)
                    }
                }
            }
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

fn classify_dreams_error(error: anyhow::Error) -> (ErrorCode, String) {
    let code = if error.is::<crate::dreams::apply::DreamsRejected>() {
        ErrorCode::InvalidRequest
    } else {
        ErrorCode::Internal
    };
    (code, format!("{error:#}"))
}
