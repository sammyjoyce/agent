mod boundary;

use std::{
    collections::HashSet,
    fs,
    future::{Future, pending},
    io,
    os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use crate::{
    broker::Broker,
    host::effects::{Admission, Capacity, HostEffects},
    native::{NativeEvent, NativeRequest},
    protocol::{CoordinatorBootstrap, RuntimeCommand, RuntimeEventKind},
    runtime::lifecycle::RequestLifecycle,
};
use anyhow::{Context, Result, ensure};
use serde::Serialize;
use tokio::{
    io::{AsyncBufRead, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    task::JoinSet,
};

use crate::runtime::{
    FrameReader, OwnerClaim, OwnerFenced, Runtime, ShutdownSignal, StartRecord,
    effects::SurvivingEffects,
};

const SOCKET_NAME: &str = "agent.sock";
/// How long a fenced owner waits for the authority to take its stop evidence.
const RELEASE_LIMIT: Duration = Duration::from_secs(30);

pub async fn connect(state: &Path) -> io::Result<UnixStream> {
    UnixStream::connect(state.join(SOCKET_NAME)).await
}

/// SSH carries this same local protocol without another database or listener.
pub async fn relay(stream: UnixStream) -> Result<()> {
    let (mut reader, mut writer) = stream.into_split();
    let mut input = tokio::io::stdin();
    let mut output = tokio::io::stdout();
    let incoming = async {
        tokio::io::copy(&mut input, &mut writer).await?;
        writer.shutdown().await?;
        Ok::<(), io::Error>(())
    };
    let outgoing = async {
        tokio::io::copy(&mut reader, &mut output).await?;
        output.flush().await?;
        Ok::<(), io::Error>(())
    };
    tokio::pin!(incoming, outgoing);
    tokio::select! {
        result = &mut incoming => { result?; outgoing.await?; }
        result = &mut outgoing => { result?; }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub async fn serve_configured(
    script: &Path,
    claim: OwnerClaim,
    port: Option<u16>,
    policy: crate::tailnet::PeerPolicy,
    daemon: crate::tailnet::Daemon,
    rex: crate::rex::RexClient,
    bootstrap: CoordinatorBootstrap,
    dreams: Option<crate::dreams::DreamsPolicy>,
    dreams_source: crate::dreams::DreamsPolicySource,
) -> Result<()> {
    serve_with_transport(
        script,
        claim,
        port,
        policy,
        daemon,
        rex,
        Some(bootstrap),
        dreams,
        dreams_source,
        shutdown_signal(),
    )
    .await
}

#[derive(Clone, Copy)]
enum ShutdownReason {
    Signal(ShutdownSignal),
    #[cfg(test)]
    Requested,
}

async fn shutdown_signal() -> Result<ShutdownReason> {
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let signal = tokio::select! {
        result = tokio::signal::ctrl_c() => { result?; ShutdownSignal::Sigint }
        _ = terminate.recv() => ShutdownSignal::Sigterm,
    };
    Ok(ShutdownReason::Signal(signal))
}

#[cfg(test)]
#[allow(clippy::disallowed_methods)]
async fn serve_until(
    script: &Path,
    state: &Path,
    shutdown: impl Future<Output = Result<ShutdownReason>>,
) -> Result<()> {
    serve_with_transport(
        script,
        OwnerClaim::acquire(state, script, None)?,
        None,
        crate::tailnet::PeerPolicy::new(&[], &[])?,
        crate::tailnet::Daemon::default(),
        crate::rex::RexClient::for_process(None)?,
        None,
        None,
        crate::dreams::DreamsPolicySource::Unconfigured,
        shutdown,
    )
    .await
}

/// Runs the coordinator, then posts a fenced owner's stop evidence.
#[allow(clippy::too_many_arguments)]
async fn serve_with_transport(
    script: &Path,
    claim: OwnerClaim,
    port: Option<u16>,
    policy: crate::tailnet::PeerPolicy,
    daemon: crate::tailnet::Daemon,
    rex: crate::rex::RexClient,
    bootstrap: Option<CoordinatorBootstrap>,
    dreams: Option<crate::dreams::DreamsPolicy>,
    dreams_source: crate::dreams::DreamsPolicySource,
    shutdown: impl Future<Output = Result<ShutdownReason>>,
) -> Result<()> {
    let session = claim.pi_session();
    let state = claim.state().to_owned();
    let served = serve_owner(
        script,
        claim,
        port,
        policy,
        daemon,
        rex,
        bootstrap,
        dreams,
        dreams_source,
        shutdown,
    )
    .await;
    if let (Err(error), Some(session)) = (&served, session)
        && let Some(OwnerFenced::Runtime) = error.downcast_ref()
        && let Some(epoch) = session.epoch
    {
        match crate::failover::commands::post_released(
            script,
            &state,
            &session,
            epoch,
            RELEASE_LIMIT,
        )
        .await
        {
            Ok(true) => eprintln!(
                "Told the failover authority that this coordinator stopped its effects at epoch {}",
                epoch.get()
            ),
            Ok(false) => {}
            Err(error) if error.is::<SurvivingEffects>() => eprintln!(
                "Did not tell the failover authority that this coordinator stopped. {error:#}"
            ),
            Err(error) => eprintln!(
                "Could not tell the failover authority that this coordinator stopped: {error:#}. Run `beep-boop failover release` on this host"
            ),
        }
    }
    served
}

#[allow(clippy::too_many_arguments)]
async fn serve_owner(
    script: &Path,
    claim: OwnerClaim,
    port: Option<u16>,
    policy: crate::tailnet::PeerPolicy,
    daemon: crate::tailnet::Daemon,
    rex: crate::rex::RexClient,
    bootstrap: Option<CoordinatorBootstrap>,
    dreams: Option<crate::dreams::DreamsPolicy>,
    dreams_source: crate::dreams::DreamsPolicySource,
    shutdown: impl Future<Output = Result<ShutdownReason>>,
) -> Result<()> {
    tokio::pin!(shutdown);
    let state = &claim.state().to_owned();
    let background = bootstrap
        .as_ref()
        .and_then(|value| value.background.clone());
    let config = bootstrap
        .as_ref()
        .and_then(|value| value.node.as_ref())
        .and_then(|node| node.launch.config.as_deref())
        .map(|path| crate::config::load(Some(Path::new(path))))
        .transpose()?;
    let owner = Runtime::start_with_notifications(
        script,
        claim,
        config.as_ref().and_then(|config| config.apns.as_ref()),
        StartRecord::for_config(config.as_ref()),
    )?;
    let background = if owner.restore_held() {
        eprintln!("{}", crate::backup::hold_notice(state));
        None
    } else {
        background
    };
    let broker = match Broker::with_tailscale_and_dreams(
        bootstrap.as_ref(),
        state,
        daemon.clone(),
        rex,
        dreams,
        dreams_source,
    ) {
        Ok(broker) => Arc::new(broker),
        Err(error) => {
            owner.close().await?;
            return Err(error);
        }
    };
    if let Some(bootstrap) = bootstrap {
        let initialized = tokio::select! {
            biased;
            result = &mut shutdown => {
                if let Ok(ShutdownReason::Signal(signal)) = &result {
                    owner.record_shutdown(*signal);
                }
                owner.close().await?;
                return result.map(|_| ());
            }
            result = crate::broker::initialize(&owner, bootstrap) => result,
        };
        if let Err(error) = initialized {
            owner.close().await?;
            return Err(error);
        }
    }
    let (listener, socket) = match SocketOwner::bind(state.join(SOCKET_NAME)) {
        Ok(bound) => bound,
        Err(error) => {
            owner.close().await?;
            return Err(error);
        }
    };
    let owner = Arc::new(owner);
    let tailnet = match port {
        Some(port) => match crate::tailnet::listen(port, &daemon).await {
            Ok(listener) => Some(listener),
            Err(error) => {
                drop(listener);
                drop(socket);
                Arc::try_unwrap(owner)
                    .map_err(|_| anyhow::anyhow!("Coordinator ownership leaked"))?
                    .close()
                    .await?;
                return Err(error);
            }
        },
        None => None,
    };
    let mut clients = JoinSet::new();
    let mut background = background.map(|settings| {
        let runtime = owner.clone();
        let broker = broker.clone();
        tokio::spawn(async move { crate::background::run(runtime, broker, settings).await })
    });
    let result = loop {
        tokio::select! {
            accepted = listener.accept() => match accepted {
                Ok((stream, _)) => {
                    let runtime = owner.clone();
                    let broker = broker.clone();
                    clients.spawn(async move { handle(stream, runtime, broker).await });
                }
                Err(error) => break Err(error.into()),
            },
            accepted = async {
                match &tailnet {
                    Some(listener) => listener.accept().await,
                    None => pending().await,
                }
            } => match accepted {
                Ok((stream, peer)) => {
                    let local = match stream.local_addr() {
                        Ok(local) => local,
                        Err(error) => break Err(error.into()),
                    };
                    let runtime = owner.clone();
                    let policy = policy.clone();
                    let daemon = daemon.clone();
                    let broker = broker.clone();
                    clients.spawn(async move {
                        authenticated(stream, runtime, broker, peer, crate::tailnet::validate_connection(local, peer, &policy, &daemon)).await
                    });
                }
                Err(error) => break Err(error.into()),
            },
            _ = owner.stopped() => {
                break Err(anyhow::anyhow!("The Pi runtime stopped; saved work is retained"));
            }
            result = async {
                match &mut background {
                    Some(task) => task.await,
                    None => pending().await,
                }
            } => {
                background = None;
                break Err(anyhow::anyhow!("The background transport stopped; saved work is retained: {result:?}"));
            },
            result = &mut shutdown => {
                if let Ok(ShutdownReason::Signal(signal)) = &result {
                    owner.record_shutdown(*signal);
                }
                break result.map(|_| ());
            },
            Some(_) = clients.join_next(), if !clients.is_empty() => {}
        }
    };
    drop(listener);
    drop(tailnet);
    // Stop admission while Pi remains alive to persist real effect receipts.
    owner.stop_requests();
    while clients.join_next().await.is_some() {}
    if let Some(task) = background {
        let _ = task.await;
    }
    let runtime = Arc::try_unwrap(owner)
        .map_err(|_| anyhow::anyhow!("A client retained coordinator ownership"))?;
    let closed = runtime.close().await;
    drop(socket);
    closed?;
    result
}

pub(crate) async fn write_frame<W: AsyncWrite + Unpin + ?Sized, T: Serialize>(
    writer: &mut W,
    value: &T,
) -> Result<()> {
    let mut bytes = serde_json::to_vec(value)?;
    bytes.push(b'\n');
    writer.write_all(&bytes).await?;
    writer.flush().await?;
    Ok(())
}

async fn write_client_frame<W: AsyncWrite + Unpin, T: Serialize>(
    writer: &mut W,
    value: &T,
    runtime: &Runtime,
) -> Result<()> {
    tokio::select! {
        result = write_frame(writer, value) => result,
        _ = runtime.stopping() => anyhow::bail!("The coordinator is shutting down"),
    }
}

async fn authenticated(
    stream: tokio::net::TcpStream,
    runtime: Arc<Runtime>,
    broker: Arc<Broker>,
    peer: std::net::SocketAddr,
    authorization: impl Future<Output = Result<()>>,
) -> Result<()> {
    let authorization = tokio::select! {
        result = authorization => result,
        _ = runtime.stopping() => return Ok(()),
    };
    if let Err(error) = authorization {
        runtime.record_peer_rejected(peer, &error.to_string());
        return Err(error);
    }
    crate::tailnet::keepalive(&stream)?;
    handle(stream, runtime, broker).await
}

async fn handle<S: AsyncRead + AsyncWrite + Unpin>(
    stream: S,
    runtime: Arc<Runtime>,
    broker: Arc<Broker>,
) -> Result<()> {
    let (reader, mut writer) = tokio::io::split(stream);
    let mut reader = FrameReader::new(BufReader::new(reader));
    let initial = tokio::select! {
        frame = reader.next_frame() => frame?.context("Client sent no command")?,
        _ = runtime.stopping() => return Ok(()),
    };
    let mut command: RuntimeCommand =
        serde_json::from_slice(&initial).context("Client sent an invalid command")?;
    if matches!(
        command,
        RuntimeCommand::Native {
            request: NativeRequest::Identify
        }
    ) {
        let Some(next) = identify(&mut reader, &mut writer, &runtime).await? else {
            return Ok(());
        };
        command = next;
    }
    let attachment = match &command {
        RuntimeCommand::Attachment { request } => Some((request.clone(), false)),
        RuntimeCommand::Native {
            request: crate::native::NativeRequest::Attachment { request },
        } => Some((request.clone(), true)),
        _ => None,
    };
    if let Some((mut request, native)) = attachment {
        // One authenticated owner transfers a file sequentially, without a
        // new socket or a live main-conversation observer for every chunk.
        loop {
            let mut call = runtime
                .request(RuntimeCommand::Attachment { request })
                .await?;
            let mut completed = false;
            while let Some(event) = call.events.recv().await {
                let done = matches!(event, RuntimeEventKind::Done);
                if native {
                    if let Some(event) = crate::native::project(&event) {
                        write_client_frame(&mut writer, &event, &runtime).await?;
                    }
                } else {
                    write_client_frame(&mut writer, &event, &runtime).await?;
                }
                if done {
                    completed = true;
                    break;
                }
            }
            anyhow::ensure!(completed, "Attachment transfer ended without completion");
            let Some(frame) = (tokio::select! {
                frame = tokio::time::timeout(std::time::Duration::from_secs(60), reader.next_frame()) => frame??,
                _ = runtime.stopping() => return Ok(()),
            }) else {
                return Ok(());
            };
            request = match serde_json::from_slice::<RuntimeCommand>(&frame)? {
                RuntimeCommand::Attachment { request } if !native => request,
                RuntimeCommand::Native {
                    request: crate::native::NativeRequest::Attachment { request },
                } if native => request,
                next if matches!(&next, RuntimeCommand::Native { .. }) == native => {
                    command = next;
                    break;
                }
                _ => anyhow::bail!("An attachment connection must preserve its protocol envelope"),
            };
        }
    }
    let native = matches!(command, RuntimeCommand::Native { .. });
    // Older native clients use a closed event enum. Their observation stream
    // keeps its original wire until the client explicitly requests coverage.
    let native_sources = matches!(
        &command,
        RuntimeCommand::Native {
            request: crate::native::NativeRequest::Observe {
                source_status: Some(true),
                ..
            }
        }
    );
    let command = match command {
        RuntimeCommand::Native { request } => {
            match crate::native::prepare(request).unwrap_or_else(|error| {
                crate::native::Operation::Local(crate::native::NativeEvent::Failure {
                    message: error.to_string(),
                    code: Some(crate::protocol::ErrorCode::InvalidRequest),
                })
            }) {
                crate::native::Operation::Runtime(command) => *command,
                crate::native::Operation::Local(event) => {
                    write_client_frame(&mut writer, &event, &runtime).await?;
                    write_client_frame(&mut writer, &crate::native::NativeEvent::Done, &runtime)
                        .await?;
                    return Ok(());
                }
                crate::native::Operation::Service(service_request) => {
                    return boundary::handle(&mut writer, &runtime, &broker, service_request).await;
                }
            }
        }
        command => command,
    };
    if let RuntimeCommand::ConnectWorker { node } = command {
        return broker.worker(reader, writer, &runtime, node).await;
    }
    if matches!(command, RuntimeCommand::Watch) {
        let mut notices = runtime.subscribe();
        loop {
            tokio::select! {
                notice = notices.recv() => match notice {
                    Ok(notice) => write_client_frame(&mut writer, &notice.event, &runtime).await?,
                    Err(_) => anyhow::bail!("Live updates were interrupted; saved task updates remain available"),
                },
                _ = runtime.stopped() => anyhow::bail!("Coordinator stopped; saved updates remain available"),
                _ = runtime.stopping() => return Ok(()),
                input = reader.next_frame() => {
                    ensure!(input?.is_none(), "A live-update subscriber cannot submit another command");
                    return Ok(());
                }
            }
        }
    }
    let lifecycle = RequestLifecycle::for_command(&command)
        .context("Control commands require their active chat or login connection")?;
    ensure!(
        !lifecycle.is_service_owned(),
        "Coordinator metadata is owned by its local service"
    );
    if runtime.restore_held()
        && let Some(message) = crate::backup::held_after_restore(&command)
    {
        let refusal = RuntimeEventKind::Failure {
            code: crate::protocol::ErrorCode::CoordinatorUnavailable,
            message: message.into(),
        };
        return write_client_frame(&mut writer, &refusal, &runtime).await;
    }
    if native && lifecycle.is_view() {
        write_client_frame(
            &mut writer,
            &crate::native::NativeEvent::Commands {
                commands: crate::native::commands(),
            },
            &runtime,
        )
        .await?;
    }
    let mut call = runtime.request(command).await?;
    let mut input_closed = false;
    let mut output_closed = false;
    let mut client_reads = HashSet::new();
    let mut effects = HostEffects::new(Capacity::Unbounded);
    let result: Result<()> = async {
        loop {
            tokio::select! {
                completed = effects.next(), if !effects.is_empty() => {
                    let reply = completed?.context("Owned effect queue closed")?;
                    runtime.reply(call.request_id, reply.call_id, reply.result).await?;
                }
                _ = runtime.stopping() => return Ok(()),
                event = call.events.recv() => {
                    let event = event.context("Coordinator closed before completing the request")?;
                    if let RuntimeEventKind::HostCall { call_id, command } = &event {
                        if lifecycle.serves_client_history(command) {
                            if input_closed {
                                runtime.reply(call.request_id, call_id.clone(), client_history_lost()).await?;
                                continue;
                            }
                            client_reads.insert(call_id.clone());
                        } else if !lifecycle.owns_host_effects() {
                            runtime.reply(call.request_id, call_id.clone(), terminal_effect_refused()).await?;
                            continue;
                        } else {
                            let broker = broker.clone(); let command = (**command).clone(); let call_id = call_id.clone();
                            if let Admission::Rejected(reply) = effects.spawn(call_id, |cancelled| async move {
                                broker.execute_cancelled(command, cancelled).await
                            })? {
                                runtime.reply(call.request_id, reply.call_id, reply.result).await?;
                            }
                            continue;
                        }
                    }
                    if let RuntimeEventKind::HostCancel { call_id } = &event {
                        effects.cancel(call_id);
                        continue;
                    }
                    let done = matches!(event, RuntimeEventKind::Done);
                    if native && !native_sources && matches!(event, RuntimeEventKind::Sources { .. }) {
                        continue;
                    }
                    let written = if native {
                        match crate::native::project(&event) {
                            Some(mut projected) if !output_closed => {
                                if matches!(&event, RuntimeEventKind::MainReady { .. })
                                    && broker.dreams_available()
                                    && let NativeEvent::Ready { dreams, .. } = &mut projected
                                {
                                    *dreams = Some(true);
                                }
                                write_client_frame(&mut writer, &projected, &runtime).await
                            }
                            _ => Ok(()),
                        }
                    } else if !output_closed { write_client_frame(&mut writer, &event, &runtime).await } else { Ok(()) };
                    if let Err(error) = written {
                        if lifecycle.is_worker() || lifecycle.is_view() { return Err(error); }
                        input_closed = true;
                        output_closed = true;
                        release_client_reads(&runtime, call.request_id, &mut client_reads).await?;
                    }
                    if done { return Ok(()); }
                }
                frame = reader.next_frame(), if !input_closed => {
                    let bytes = match frame {
                        Ok(bytes) => bytes,
                        Err(_) if !lifecycle.is_worker() && !lifecycle.is_view() => {
                            // A dropped CLI does not revoke work it already
                            // admitted. Keep the effect owner alive through its
                            // real result, as with EOF or a failed output write.
                            input_closed = true;
                            output_closed = true;
                            release_client_reads(&runtime, call.request_id, &mut client_reads).await?;
                            continue;
                        }
                        Err(error) => return Err(error),
                    };
                    let Some(bytes) = bytes else {
                        if lifecycle.is_view() { return Ok(()); }
                        input_closed = true;
                        if lifecycle.allows(&RuntimeCommand::DetachWorker) {
                            runtime.worker_control(call.request_id, lifecycle.disconnect_command().context("Missing worker detach control")?).await?;
                        }
                        release_client_reads(&runtime, call.request_id, &mut client_reads).await?;
                        continue;
                    };
                    let control: RuntimeCommand = serde_json::from_slice(&bytes)
                        .context("Client sent an invalid control")?;
                    match control {
                        RuntimeCommand::HostReply { call_id, result } if client_reads.remove(&call_id) => {
                            runtime.reply(call.request_id, call_id, result).await?;
                        }
                        command if lifecycle.allows(&command) => {
                            match command {
                                RuntimeCommand::OAuthCallback { target } => runtime.callback(call.request_id, target).await?,
                                command => runtime.worker_control(call.request_id, command).await?,
                            }
                        }
                        _ => anyhow::bail!("An active client may only send its own controls"),
                    }
                }
            }
        }
    }.await;
    let mut draining = effects.shutdown();
    let mut drained = Ok(());
    while let Some(reply) = draining.next().await {
        let delivery = match reply {
            Ok(reply) => {
                runtime
                    .reply(call.request_id, reply.call_id, reply.result)
                    .await
            }
            Err(error) => Err(error),
        };
        drained = drained.and(delivery);
    }
    runtime.detach(call.request_id).await;
    result.and(drained)
}

/// Answers the `Identify` preamble, then reads the connection's real first
/// command. Returns `None` when the client only asked who answers.
async fn identify<R: AsyncBufRead + Unpin, W: AsyncWrite + Unpin>(
    reader: &mut FrameReader<R>,
    writer: &mut W,
    runtime: &Runtime,
) -> Result<Option<RuntimeCommand>> {
    write_client_frame(
        writer,
        &NativeEvent::Identity {
            coordinator_id: runtime.coordinator_id().to_string(),
        },
        runtime,
    )
    .await?;
    let Some(frame) = (tokio::select! {
        frame = tokio::time::timeout(std::time::Duration::from_secs(60), reader.next_frame()) => frame??,
        _ = runtime.stopping() => return Ok(None),
    }) else {
        return Ok(None);
    };
    let next: RuntimeCommand =
        serde_json::from_slice(&frame).context("Client sent an invalid command")?;
    ensure!(
        matches!(next, RuntimeCommand::Native { .. }),
        "An identified connection must carry native requests"
    );
    Ok(Some(next))
}

async fn release_client_reads(
    runtime: &Runtime,
    request_id: u32,
    client_reads: &mut HashSet<String>,
) -> Result<()> {
    for call_id in client_reads.drain() {
        runtime
            .reply(request_id, call_id, client_history_lost())
            .await?;
    }
    Ok(())
}

fn client_history_lost() -> crate::protocol::HostResult {
    crate::protocol::HostResult::Failed {
        delivery: Some(crate::protocol::HostDelivery::OutcomeUncertain),
        message: "The client serving this import disconnected; run the import again to resume."
            .into(),
    }
}

fn terminal_effect_refused() -> crate::protocol::HostResult {
    crate::protocol::HostResult::Failed {
        delivery: Some(crate::protocol::HostDelivery::NotStarted),
        message: "A task terminal never runs host commands; nothing was started and no fallback host was used.".into(),
    }
}

struct SocketOwner {
    path: PathBuf,
    device: u64,
    inode: u64,
}

impl SocketOwner {
    fn bind(path: PathBuf) -> Result<(UnixListener, Self)> {
        match fs::symlink_metadata(&path) {
            Ok(metadata) => {
                ensure!(
                    metadata.file_type().is_socket(),
                    "Coordinator socket path contains a foreign non-socket; preserving it"
                );
                fs::remove_file(&path)?;
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        let listener = UnixListener::bind(&path)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        let metadata = fs::symlink_metadata(&path)?;
        Ok((
            listener,
            Self {
                path,
                device: metadata.dev(),
                inode: metadata.ino(),
            },
        ))
    }
}

impl Drop for SocketOwner {
    fn drop(&mut self) {
        if let Ok(metadata) = fs::symlink_metadata(&self.path)
            && metadata.file_type().is_socket()
            && metadata.dev() == self.device
            && metadata.ino() == self.inode
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}

#[cfg(test)]
#[path = "service/reset_tests.rs"]
#[allow(clippy::disallowed_methods)]
mod reset_tests;

#[cfg(test)]
#[allow(clippy::disallowed_methods)]
mod tests {
    mod ownership;
    mod scrawl_feedback;
    mod startup;
    use crate::TEST_HANG_LIMIT;
    use crate::native::{NativeEvent, NativeRequest};
    use crate::protocol::{AuthStatus, HostResult, InputMode, RuntimeCommand, RuntimeEventKind};
    use crate::runtime::{FrameReader, OwnerClaim, Runtime, ShutdownSignal};
    use crate::service::{
        SOCKET_NAME, ShutdownReason, SocketOwner, authenticated, connect, serve_until, write_frame,
    };
    use anyhow::Result;
    use std::{fs, path::PathBuf, sync::Arc, time::Duration};
    use tokio::{
        io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader},
        net::{TcpListener, TcpStream, UnixStream},
        sync::oneshot,
        task::JoinHandle,
        time::{Instant, sleep, timeout},
    };

    const FIXTURE: &str = r#"
      import { createHash } from 'node:crypto';
      import { createInterface } from 'node:readline';
      import { appendFileSync, existsSync, renameSync, writeFileSync } from 'node:fs';
      import { join } from 'node:path';
      const uploads = new Map();
      const histories = new Map();
      const emit = (id,event) => process.stdout.write(JSON.stringify({version:1,id,event})+'\n');
      const finish = id => { emit(id,{type:'auth_status',status:{state:'signed_out'}}); emit(id,{type:'done'}); };
      const publish = (name, value) => {
        const path = join(process.argv[2],name), temporary = path+'.'+process.pid+'.tmp';
        writeFileSync(temporary,value); renameSync(temporary,path);
      };
      createInterface({input:process.stdin}).on('line', line => {
        const {id,command}=JSON.parse(line);
        publish('admitted','yes');
        if(command.type==='login') {
          publish('login-id',String(id));
          const complete = () => {
            emit(id,{type:'notice',task_id:'22222222-2222-4222-8222-222222222222',text:'Synthetic task completed.'});
            publish('completed','yes'); finish(id);
          };
          const held = join(process.argv[2],'hold-login');
          if(existsSync(held)) {
            const gate = setInterval(() => { if(!existsSync(held)) { clearInterval(gate); complete(); } },5);
          } else setTimeout(complete,60);
        } else if(typeof command.target==='string') {
          publish('callback.json',JSON.stringify({id,target:command.target}));
        } else if(command.type==='run_task'&&command.interactive) {
          emit(id,{type:'task_ready',conversation_id:'persisted-task',title:'Interactive fixture'});
          emit(id,{type:'worker_idle'});
        } else if(command.type==='chat') {
          emit(id,{type:'notice',task_id:null,text:'Chat ready'});
        } else if(command.type==='observe_main') {
          emit(id,{type:'sources',sources:[{source:{provider:'google',account:'mail-primary'},checkpoint:null,
            coverage:{status:'unavailable',message:'Provider read failed'},checked_at:1}]});
          emit(id,{type:'worker_idle'}); emit(id,{type:'done'});
        } else if(command.type==='submit_input') {
          publish('input-'+command.input_id+'.json',JSON.stringify({id,input:command.input,mode:command.mode}));
          emit(id,{type:'input_accepted',input_id:command.input_id});
        } else if(command.type==='interrupt') {
          finish(id);
        } else if(command.type==='worker_input') {
          publish('worker-input.json',JSON.stringify({id,input:command.input}));
          emit(id,{type:'answer',conversation_id:'persisted-task',text:command.input}); emit(id,{type:'worker_idle'});
        } else if(command.type==='detach_worker') {
          publish('worker-detached',String(id)); emit(id,{type:'done'});
        } else if(command.type==='run_task'||command.type==='logout') {
          emit(id,{type:'host_call',call_id:'11111111-1111-4111-8111-111111111111',command:{
            type:'exec',program:'node',args:['--eval','process.stdout.write("synthetic\\n")'],cwd:'/',timeout_seconds:60}});
        } else if(command.type==='import_chatgpt') {
          if(command.package.parts[0]==='mixed.zip') for (const [call,delay] of [[1,0],[2,10000]])
            emit(id,{type:'host_call',call_id:'exec-'+call,command:{type:'exec',program:'node',cwd:'/',timeout_seconds:60,
              args:['--eval','setTimeout(()=>process.stdout.write("synthetic\\n"),'+delay+')']}});
          for (const call of [1,2]) emit(id,{type:'host_call',call_id:'history-'+call,
            command:{type:'history',request:{type:'list',archived:false,cursor:null}}});
        } else if(command.type==='host_reply'&&command.call_id.startsWith('history-')) {
          publish(command.call_id+'.json',JSON.stringify(command.result));
          histories.set(id,(histories.get(id)??0)+1);
          if(histories.get(id)===1) emit(id,{type:'notice',task_id:null,text:'Invented history progress'});
          else { emit(id,{type:'done'}); }
        } else if(command.type==='host_reply'&&command.call_id.startsWith('exec-')) {
          publish(command.call_id+'.json',JSON.stringify(command.result));
        } else if(command.type==='host_reply') {
          publish('reply.json',JSON.stringify(command.result)); finish(id);
        } else if(command.type==='attachment'&&command.request.type==='upload') {
          const upload = command.request, bytes = Buffer.from(upload.data_base64,'base64');
          const received = Buffer.concat([uploads.get(upload.id) ?? Buffer.alloc(0), bytes]);
          uploads.set(upload.id, received);
          const attachment = upload.complete ? {id:upload.id,name:upload.name,media_type:upload.media_type,
            size_bytes:upload.size_bytes,sha256:createHash('sha256').update(received).digest('hex')} : null;
          emit(id,{type:'attachment',response:{type:'uploaded',next_offset:received.length,attachment}});
          emit(id,{type:'done'});
        } else if(command.type==='main_feedback') {
          appendFileSync(join(process.argv[2],'main-feedback.jsonl'),JSON.stringify(command)+'\n');
          if(existsSync(join(process.argv[2],'reject-feedback'))) {
            emit(id,{type:'input_rejected',input_id:command.input_id,message:'Invented: feedback is paused here'});
          } else if(!existsSync(join(process.argv[2],'unconfirmed-feedback'))) {
            emit(id,{type:'input_accepted',input_id:command.input_id});
            emit(id,{type:'feedback_ready',input_id:command.input_id,receipt:{id:command.input_id,
              path:'feedback/'+command.input_id,task_id:'22222222-2222-4222-8222-222222222222',agent_id:null}});
          }
          emit(id,{type:'done'});
        } else if(command.type==='list_tasks') { process.exit(0); }
        else { finish(id); }
      });
    "#;

    fn attached_command() -> RuntimeCommand {
        RuntimeCommand::RunTask {
            task_id: crate::protocol::TaskId::new(),
            agent_id: None,
            allocation_id: "fixture".into(),
            binding: crate::protocol::WorkerRef {
                host_id: "11111111-1111-4111-8111-111111111111".into(),
                session_id: "fixture".into(),
                window_id: "fixture".into(),
                block_id: "fixture".into(),
                rex_instance_id: None,
            },
            instructions: String::new(),
            model: crate::models::ModelSelection::default(),
            cwd: "/".into(),
            interactive: None,
        }
    }

    #[tokio::test]
    async fn submitted_inputs_stay_on_their_active_chat_or_worker_connection() {
        #[derive(serde::Deserialize)]
        struct Submitted {
            id: u32,
            input: String,
            mode: InputMode,
        }
        let service = Running::start().await;
        let mut unscoped = service.client().await;
        write_frame(
            &mut unscoped,
            &RuntimeCommand::SubmitInput {
                origin: None,
                attachments: None,
                input_id: "unscoped".into(),
                input: "Rejected".into(),
                mode: InputMode::Steer,
            },
        )
        .await
        .unwrap();
        let mut bytes = Vec::new();
        unscoped.read_to_end(&mut bytes).await.unwrap();
        assert!(bytes.is_empty());
        assert!(
            !service
                .directory
                .path()
                .join("input-unscoped.json")
                .exists()
        );

        let mut chat = service.client().await;
        write_frame(
            &mut chat,
            &RuntimeCommand::Chat {
                origin: None,
                attachments: None,
                input: "Start chat".into(),
                input_id: None,
                instructions: String::new(),
                model: None,
                origin_host_id: None,
                cwd: "/".into(),
                hosts: vec![],
                reply_to: None,
            },
        )
        .await
        .unwrap();
        let (read, mut write) = chat.into_split();
        let mut chat = FrameReader::new(BufReader::new(read));
        chat.next_frame().await.unwrap().unwrap();
        for (input_id, mode) in [("steer", InputMode::Steer), ("queue", InputMode::FollowUp)] {
            write_frame(
                &mut write,
                &RuntimeCommand::SubmitInput {
                    origin: None,
                    attachments: None,
                    input_id: input_id.into(),
                    input: input_id.into(),
                    mode,
                },
            )
            .await
            .unwrap();
            let event: RuntimeEventKind =
                serde_json::from_slice(&chat.next_frame().await.unwrap().unwrap()).unwrap();
            assert!(
                matches!(event, RuntimeEventKind::InputAccepted { input_id: accepted, .. } if accepted == input_id)
            );
        }
        let read = |name: &str| -> Submitted {
            serde_json::from_slice(
                &fs::read(service.directory.path().join(format!("input-{name}.json"))).unwrap(),
            )
            .unwrap()
        };
        let steer = read("steer");
        let queue = read("queue");
        assert_eq!(steer.id, queue.id);
        assert_eq!(steer.input, "steer");
        assert_eq!(steer.mode, InputMode::Steer);
        assert_eq!(queue.mode, InputMode::FollowUp);
        status(service.client().await).await;
        write_frame(&mut write, &RuntimeCommand::Interrupt)
            .await
            .unwrap();
        loop {
            let event: RuntimeEventKind =
                serde_json::from_slice(&chat.next_frame().await.unwrap().unwrap()).unwrap();
            if matches!(event, RuntimeEventKind::Done) {
                break;
            }
        }
        drop((chat, write));
        service.stop().await;
    }

    struct Running {
        directory: tempfile::TempDir,
        stop: oneshot::Sender<()>,
        task: JoinHandle<Result<()>>,
    }

    impl Running {
        async fn start() -> Self {
            Self::start_with_shutdown(ShutdownReason::Requested).await
        }

        async fn start_with_shutdown(reason: ShutdownReason) -> Self {
            let directory = tempfile::tempdir().unwrap();
            let script = directory.path().join("fixture.mjs");
            fs::write(&script, FIXTURE).unwrap();
            Self::start_script(directory, script, reason).await
        }

        async fn start_script(
            directory: tempfile::TempDir,
            script: PathBuf,
            reason: ShutdownReason,
        ) -> Self {
            let state = directory.path().to_path_buf();
            let (stop, stopped) = oneshot::channel();
            let task = tokio::spawn(async move {
                serve_until(&script, &state, async {
                    let _ = stopped.await;
                    Ok(reason)
                })
                .await
            });
            let result = Self {
                directory,
                stop,
                task,
            };
            drop(result.client().await);
            result
        }

        async fn client(&self) -> UnixStream {
            let deadline = Instant::now() + TEST_HANG_LIMIT;
            loop {
                match connect(self.directory.path()).await {
                    Ok(stream) => return stream,
                    Err(_) => {
                        assert!(Instant::now() < deadline, "Coordinator did not bind");
                        sleep(Duration::from_millis(5)).await;
                    }
                }
            }
        }

        async fn stop(self) {
            self.stop.send(()).unwrap();
            timeout(TEST_HANG_LIMIT, self.task)
                .await
                .unwrap()
                .unwrap()
                .unwrap();
            assert!(!self.directory.path().join(SOCKET_NAME).exists());
        }

        async fn wait_for(&self, filename: &str) -> PathBuf {
            let path = self.directory.path().join(filename);
            let deadline = Instant::now() + TEST_HANG_LIMIT;
            while !path.exists() {
                assert!(
                    Instant::now() < deadline,
                    "Expected fixture result {filename}"
                );
                sleep(Duration::from_millis(5)).await;
            }
            path
        }
    }

    #[tokio::test]
    async fn source_coverage_reaches_opted_in_native_observers_and_raw_clients_only() {
        use crate::native::{NativeEvent, NativeRequest};
        let service = Running::start().await;
        for source_status in [None, Some(false), Some(true)] {
            let mut socket = service.client().await;
            let command = RuntimeCommand::Native {
                request: NativeRequest::Observe {
                    input_ids: vec![],
                    source_status,
                    task_graph: None,
                },
            };
            write_frame(&mut socket, &command).await.unwrap();
            let mut reader = FrameReader::new(BufReader::new(socket));
            let mut sources = 0;
            loop {
                let bytes = timeout(TEST_HANG_LIMIT, reader.next_frame())
                    .await
                    .unwrap()
                    .unwrap()
                    .unwrap();
                match serde_json::from_slice::<NativeEvent>(&bytes).unwrap() {
                    NativeEvent::Sources { sources: states } => {
                        sources += 1;
                        assert_eq!(states.len(), 1);
                        assert!(matches!(
                            states[0].coverage,
                            crate::sources::SourceCoverage::Unavailable { .. }
                        ));
                    }
                    NativeEvent::Done => break,
                    NativeEvent::Commands { .. } | NativeEvent::Idle => {}
                    event => panic!("Unexpected observation event: {event:?}"),
                }
            }
            assert_eq!(sources, usize::from(source_status == Some(true)));
        }
        let mut socket = service.client().await;
        write_frame(
            &mut socket,
            &RuntimeCommand::ObserveMain {
                input_ids: vec![],
                task_graph: None,
            },
        )
        .await
        .unwrap();
        let mut reader = FrameReader::new(BufReader::new(socket));
        let bytes = reader.next_frame().await.unwrap().unwrap();
        assert!(matches!(
            serde_json::from_slice::<RuntimeEventKind>(&bytes).unwrap(),
            RuntimeEventKind::Sources { .. }
        ));
        drop(reader);
        service.stop().await;
    }

    #[tokio::test]
    async fn real_attachment_store_transfers_multiple_chunks_on_one_socket_and_reads_through_native_envelope()
     {
        use crate::attachments::{
            ATTACHMENT_CHUNK_BYTES, AttachmentRequest, AttachmentResponse, upload_file,
        };
        use crate::native::{NativeEvent, NativeRequest};
        use base64::{Engine, engine::general_purpose::STANDARD};
        let directory = tempfile::tempdir().unwrap();
        let script = std::env::var_os("AGENT_RUNTIME_PATH")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("runtime/dist/src/bridge.js")
            });
        let service = Running::start_script(directory, script, ShutdownReason::Requested).await;
        let bytes = vec![b'a'; ATTACHMENT_CHUNK_BYTES as usize + 11];
        let source = service.directory.path().join("upload.txt");
        fs::write(&source, &bytes).unwrap();
        let stream = service.client().await;
        let (reader, writer) = stream.into_split();
        let connection = Arc::new(tokio::sync::Mutex::new((
            FrameReader::new(BufReader::new(reader)),
            writer,
        )));
        let attachment = upload_file(&source, |request| {
            let connection = connection.clone();
            async move {
                let mut connection = connection.lock().await;
                let (reader, writer) = &mut *connection;
                write_frame(writer, &RuntimeCommand::Attachment { request }).await?;
                let mut response = None;
                loop {
                    let frame = reader.next_frame().await?.unwrap();
                    match serde_json::from_slice::<RuntimeEventKind>(&frame)? {
                        RuntimeEventKind::Attachment { response: received } => {
                            response = Some(received)
                        }
                        RuntimeEventKind::Done => {
                            return response
                                .ok_or_else(|| anyhow::anyhow!("Missing attachment response"));
                        }
                        RuntimeEventKind::Failure { message, .. } => anyhow::bail!(message),
                        _ => anyhow::bail!("Unexpected transfer event"),
                    }
                }
            }
        })
        .await
        .unwrap();
        assert_eq!(attachment.size_bytes as usize, bytes.len());
        drop(connection);
        let mut native = service.client().await;
        write_frame(
            &mut native,
            &RuntimeCommand::Native {
                request: NativeRequest::Attachment {
                    request: AttachmentRequest::Download {
                        id: attachment.id,
                        offset: ATTACHMENT_CHUNK_BYTES,
                        limit: 32,
                    },
                },
            },
        )
        .await
        .unwrap();
        let (native_read, mut native_write) = native.into_split();
        let mut reader = FrameReader::new(BufReader::new(native_read));
        let event: NativeEvent =
            serde_json::from_slice(&reader.next_frame().await.unwrap().unwrap()).unwrap();
        assert!(
            matches!(event, NativeEvent::Attachment { response: AttachmentResponse::Download { data_base64, next_offset: None } } if STANDARD.decode(&data_base64).unwrap() == bytes[ATTACHMENT_CHUNK_BYTES as usize..])
        );
        assert!(matches!(
            serde_json::from_slice::<NativeEvent>(&reader.next_frame().await.unwrap().unwrap())
                .unwrap(),
            NativeEvent::Done
        ));
        write_frame(
            &mut native_write,
            &RuntimeCommand::Native {
                request: NativeRequest::Submit {
                    origin: None,
                    input_id: uuid::Uuid::new_v4().to_string(),
                    text: "/help".into(),
                    mode: InputMode::Steer,
                    attachments: None,
                    reply_to: None,
                },
            },
        )
        .await
        .unwrap();
        assert!(matches!(
            serde_json::from_slice::<NativeEvent>(&reader.next_frame().await.unwrap().unwrap())
                .unwrap(),
            NativeEvent::Notice { .. }
        ));
        assert!(matches!(
            serde_json::from_slice::<NativeEvent>(&reader.next_frame().await.unwrap().unwrap())
                .unwrap(),
            NativeEvent::Done
        ));
        drop(reader);
        drop(native_write);
        service.stop().await;
    }

    #[tokio::test]
    async fn signal_shutdown_records_exact_intent_before_stopping_active_requests() {
        #[derive(serde::Deserialize)]
        #[serde(tag = "event", rename_all = "snake_case")]
        enum StopEvent {
            ServiceShutdown {
                signal: ShutdownSignal,
            },
            RuntimeStopped {
                code: crate::protocol::ErrorCode,
            },
            #[serde(other)]
            Other,
        }
        #[derive(serde::Deserialize)]
        struct StopRecord {
            timestamp_ms: u64,
            request_id: u32,
            elapsed_ms: Option<u64>,
            conversation_id: Option<String>,
            task_id: Option<String>,
            agent_id: Option<String>,
            #[serde(flatten)]
            event: StopEvent,
        }
        let now = || {
            u64::try_from(
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_millis(),
            )
            .unwrap()
        };
        for signal in [ShutdownSignal::Sigint, ShutdownSignal::Sigterm] {
            let service = Running::start_with_shutdown(ShutdownReason::Signal(signal)).await;
            let mut client = service.client().await;
            write_frame(
                &mut client,
                &RuntimeCommand::Chat {
                    origin: None,
                    attachments: None,
                    input: "Keep this synthetic request active".into(),
                    input_id: None,
                    instructions: String::new(),
                    model: None,
                    origin_host_id: None,
                    cwd: "/".into(),
                    hosts: vec![],
                    reply_to: None,
                },
            )
            .await
            .unwrap();
            let mut client = FrameReader::new(BufReader::new(client));
            let event: RuntimeEventKind =
                serde_json::from_slice(&client.next_frame().await.unwrap().unwrap()).unwrap();
            assert!(matches!(event, RuntimeEventKind::Notice { .. }));
            let before = now();
            let Running {
                directory,
                stop,
                task,
            } = service;
            stop.send(()).unwrap();
            timeout(TEST_HANG_LIMIT, task)
                .await
                .unwrap()
                .unwrap()
                .unwrap();
            let after = now();
            let records = timeout(TEST_HANG_LIMIT, async {
                loop {
                    let text =
                        fs::read_to_string(directory.path().join("diagnostics/runtime.jsonl"))
                            .unwrap_or_default();
                    let complete = text.rsplit_once('\n').map_or("", |(complete, _)| complete);
                    let records = complete
                        .lines()
                        .map(serde_json::from_str::<StopRecord>)
                        .collect::<Result<Vec<_>, _>>()
                        .unwrap();
                    if records
                        .iter()
                        .any(|record| matches!(record.event, StopEvent::RuntimeStopped { .. }))
                    {
                        break records;
                    }
                    sleep(Duration::from_millis(5)).await;
                }
            })
            .await
            .unwrap();
            let shutdowns = records
                .iter()
                .enumerate()
                .filter(|(_, record)| matches!(record.event, StopEvent::ServiceShutdown { .. }))
                .collect::<Vec<_>>();
            assert_eq!(shutdowns.len(), 1);
            let (intent_index, intent) = shutdowns[0];
            assert!(
                matches!(intent.event, StopEvent::ServiceShutdown { signal: actual } if actual == signal)
            );
            assert!((before..=after).contains(&intent.timestamp_ms));
            assert_eq!(intent.request_id, 0);
            assert!(
                intent.elapsed_ms.is_none()
                    && intent.conversation_id.is_none()
                    && intent.task_id.is_none()
                    && intent.agent_id.is_none()
            );
            assert!(
                records
                    .iter()
                    .enumerate()
                    .any(|(index, record)| index > intent_index
                        && record.request_id == 1
                        && matches!(
                            record.event,
                            StopEvent::RuntimeStopped {
                                code: crate::protocol::ErrorCode::Internal
                            }
                        ))
            );
            drop(client);
        }
    }

    async fn status<S: AsyncRead + AsyncWrite + Unpin>(mut stream: S) {
        write_frame(&mut stream, &RuntimeCommand::Status)
            .await
            .unwrap();
        let mut reader = FrameReader::new(BufReader::new(stream));
        let event: RuntimeEventKind =
            serde_json::from_slice(&reader.next_frame().await.unwrap().unwrap()).unwrap();
        assert!(matches!(
            event,
            RuntimeEventKind::AuthStatus {
                status: AuthStatus::SignedOut
            }
        ));
        let event: RuntimeEventKind =
            serde_json::from_slice(&reader.next_frame().await.unwrap().unwrap()).unwrap();
        assert!(matches!(event, RuntimeEventKind::Done));
    }

    async fn exchange(mut stream: UnixStream, commands: &[RuntimeCommand], close: bool) -> String {
        for command in commands {
            write_frame(&mut stream, command).await.unwrap();
        }
        if close {
            stream.shutdown().await.unwrap();
        }
        let mut bytes = Vec::new();
        timeout(TEST_HANG_LIMIT, stream.read_to_end(&mut bytes))
            .await
            .unwrap()
            .unwrap();
        String::from_utf8(bytes).unwrap()
    }

    #[tokio::test]
    async fn identify_names_the_coordinator_before_the_unchanged_first_request() {
        use crate::native::NativeRequest::{Identify, Observe};
        let native = |request| RuntimeCommand::Native { request };
        let service = Running::start().await;
        let identity = format!(
            "{{\"type\":\"identity\",\"coordinator_id\":\"{}\"}}\n",
            fs::read_to_string(service.directory.path().join("coordinator-id")).unwrap()
        );
        let observe = || {
            native(Observe {
                input_ids: vec![],
                source_status: None,
                task_graph: None,
            })
        };
        let plain = exchange(service.client().await, &[observe()], false).await;
        assert!(plain.starts_with(r#"{"type":"commands""#), "{plain}");
        assert_eq!(
            exchange(
                service.client().await,
                &[native(Identify), observe()],
                false
            )
            .await,
            identity.clone() + &plain
        );
        assert_eq!(
            exchange(service.client().await, &[native(Identify)], true).await,
            identity
        );
        assert_eq!(
            exchange(
                service.client().await,
                &[native(Identify), native(Identify)],
                false
            )
            .await,
            identity.clone()
                + r#"{"type":"failure","message":"Identify must be the first request on a connection","code":"invalid_request"}"#
                + "\n"
                + r#"{"type":"done"}"#
                + "\n"
        );
        fs::remove_file(service.directory.path().join("admitted")).unwrap();
        assert_eq!(
            exchange(
                service.client().await,
                &[native(Identify), RuntimeCommand::Status],
                false
            )
            .await,
            identity
        );
        assert!(!service.directory.path().join("admitted").exists());
        status(service.client().await).await;
        service.stop().await;
    }

    #[tokio::test]
    async fn independent_clients_share_one_writer_and_do_not_block_each_other() {
        let service = Running::start().await;
        let held = service.directory.path().join("hold-login");
        fs::write(
            &held,
            "Keep Login open until both independent clients finish.",
        )
        .unwrap();
        let mut slow = service.client().await;
        write_frame(&mut slow, &RuntimeCommand::Login)
            .await
            .unwrap();
        let completed = timeout(TEST_HANG_LIMIT, async {
            service.wait_for("login-id").await;
            let first = service.client().await;
            let second = service.client().await;
            tokio::join!(status(first), status(second));
            assert!(
                !service.directory.path().join("completed").exists(),
                "Both status requests must finish while Login is still held"
            );
            fs::remove_file(&held).unwrap();
            service.wait_for("completed").await;
        })
        .await;
        if held.exists() {
            fs::remove_file(held).unwrap();
        }
        drop(slow);
        service.stop().await;
        completed.unwrap();
    }

    #[tokio::test]
    async fn disconnected_client_keeps_admitted_work_running() {
        let service = Running::start().await;
        let mut client = service.client().await;
        write_frame(&mut client, &RuntimeCommand::Login)
            .await
            .unwrap();
        drop(client);
        service.wait_for("completed").await;
        status(service.client().await).await;
        service.stop().await;
    }

    fn chatgpt_import(part: &str) -> RuntimeCommand {
        RuntimeCommand::ImportChatGpt {
            package: crate::history::chatgpt::ChatGptPackageSummary {
                digest: "0".repeat(64),
                parts: vec![part.into()],
                conversations: 1,
                archived: 0,
                shards: 1,
                attachments: 0,
                missing_attachments: 0,
                excluded_messages: 0,
                unsupported: Vec::new(),
                dropped_library_files: 0,
                unreferenced_files: 0,
                notes: Vec::new(),
                problems: Vec::new(),
            },
        }
    }

    async fn delegated_history_calls<R: AsyncRead + Unpin>(reader: &mut FrameReader<BufReader<R>>) {
        for expected in ["history-1", "history-2"] {
            let event: RuntimeEventKind =
                serde_json::from_slice(&reader.next_frame().await.unwrap().unwrap()).unwrap();
            assert!(
                matches!(&event, RuntimeEventKind::HostCall { call_id, .. } if call_id == expected),
                "{event:?}"
            );
        }
    }

    async fn disconnected_reply(directory: &std::path::Path, call: &str) {
        let path = directory.join(format!("{call}.json"));
        let deadline = Instant::now() + TEST_HANG_LIMIT;
        while !path.exists() {
            assert!(Instant::now() < deadline, "{call} was not failed promptly");
            sleep(Duration::from_millis(5)).await;
        }
        let reply = fs::read_to_string(path).unwrap();
        assert!(reply.contains("disconnected"), "{reply}");
    }

    #[tokio::test]
    async fn history_client_eof_fails_outstanding_reads_promptly() {
        let service = Running::start().await;
        let mut client = service.client().await;
        write_frame(&mut client, &chatgpt_import("export.zip"))
            .await
            .unwrap();
        let (reader, mut writer) = client.into_split();
        let mut reader = FrameReader::new(BufReader::new(reader));
        delegated_history_calls(&mut reader).await;
        writer.shutdown().await.unwrap();
        for call in ["history-1", "history-2"] {
            disconnected_reply(service.directory.path(), call).await;
        }
        drop(reader);
        service.stop().await;
    }

    #[tokio::test]
    async fn history_client_read_error_fails_outstanding_reads_promptly() {
        let service = Running::start().await;
        let mut client = service.client().await;
        write_frame(&mut client, &chatgpt_import("export.zip"))
            .await
            .unwrap();
        let (reader, mut writer) = client.into_split();
        let mut reader = FrameReader::new(BufReader::new(reader));
        delegated_history_calls(&mut reader).await;
        writer.write_all(br#"{"type":"host_reply","#).await.unwrap();
        writer.shutdown().await.unwrap();
        for call in ["history-1", "history-2"] {
            disconnected_reply(service.directory.path(), call).await;
        }
        drop(reader);
        service.stop().await;
    }

    /// A client whose output side fails while its input stays open, which a socket cannot
    /// produce on demand.
    struct FailingOutput {
        inner: tokio::io::DuplexStream,
        failed: Arc<std::sync::atomic::AtomicBool>,
    }

    impl AsyncRead for FailingOutput {
        fn poll_read(
            mut self: std::pin::Pin<&mut Self>,
            context: &mut std::task::Context<'_>,
            buffer: &mut tokio::io::ReadBuf<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            std::pin::Pin::new(&mut self.inner).poll_read(context, buffer)
        }
    }

    impl AsyncWrite for FailingOutput {
        fn poll_write(
            mut self: std::pin::Pin<&mut Self>,
            context: &mut std::task::Context<'_>,
            buffer: &[u8],
        ) -> std::task::Poll<std::io::Result<usize>> {
            if self.failed.load(std::sync::atomic::Ordering::SeqCst) {
                return std::task::Poll::Ready(Err(std::io::ErrorKind::BrokenPipe.into()));
            }
            std::pin::Pin::new(&mut self.inner).poll_write(context, buffer)
        }

        fn poll_flush(
            mut self: std::pin::Pin<&mut Self>,
            context: &mut std::task::Context<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            std::pin::Pin::new(&mut self.inner).poll_flush(context)
        }

        fn poll_shutdown(
            mut self: std::pin::Pin<&mut Self>,
            context: &mut std::task::Context<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            std::pin::Pin::new(&mut self.inner).poll_shutdown(context)
        }
    }

    #[tokio::test]
    async fn history_client_output_failure_fails_outstanding_reads_promptly() {
        let directory = tempfile::tempdir().unwrap();
        let script = directory.path().join("fixture.mjs");
        fs::write(&script, FIXTURE).unwrap();
        let runtime = Arc::new(
            Runtime::start(
                &script,
                OwnerClaim::acquire(directory.path(), &script, None).unwrap(),
            )
            .unwrap(),
        );
        let broker = Arc::new(
            crate::broker::Broker::new(
                None,
                directory.path(),
                crate::rex::RexClient::for_process(None).unwrap(),
            )
            .unwrap(),
        );
        let (client, server) = tokio::io::duplex(1 << 20);
        let failed = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let handled = tokio::spawn(crate::service::handle(
            FailingOutput {
                inner: server,
                failed: failed.clone(),
            },
            runtime.clone(),
            broker,
        ));
        let (reader, mut writer) = tokio::io::split(client);
        write_frame(&mut writer, &chatgpt_import("export.zip"))
            .await
            .unwrap();
        let mut reader = FrameReader::new(BufReader::new(reader));
        delegated_history_calls(&mut reader).await;
        failed.store(true, std::sync::atomic::Ordering::SeqCst);
        write_frame(
            &mut writer,
            &RuntimeCommand::HostReply {
                call_id: "history-1".into(),
                result: HostResult::Failed {
                    delivery: None,
                    message: "Invented first reply".into(),
                },
            },
        )
        .await
        .unwrap();
        disconnected_reply(directory.path(), "history-2").await;
        timeout(TEST_HANG_LIMIT, handled)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        drop((reader, writer));
        Arc::try_unwrap(runtime)
            .ok()
            .unwrap()
            .close()
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn history_client_is_sent_only_reads_and_cannot_answer_the_services_calls() {
        let service = Running::start().await;
        let mut client = service.client().await;
        write_frame(&mut client, &chatgpt_import("mixed.zip"))
            .await
            .unwrap();
        let (reader, mut writer) = client.into_split();
        let mut reader = FrameReader::new(BufReader::new(reader));
        delegated_history_calls(&mut reader).await;
        let executed = service.wait_for("exec-1.json").await;
        let result: HostResult = serde_json::from_slice(&fs::read(&executed).unwrap()).unwrap();
        assert!(
            matches!(&result, HostResult::Process { exit_code: 0, stdout, .. } if stdout == "synthetic\n"),
            "{result:?}"
        );
        write_frame(
            &mut writer,
            &RuntimeCommand::HostReply {
                call_id: "exec-2".into(),
                result: HostResult::Failed {
                    delivery: None,
                    message: "Invented forged reply".into(),
                },
            },
        )
        .await
        .unwrap();
        let running = fs::read_to_string(service.wait_for("exec-2.json").await).unwrap();
        assert!(!running.contains("Invented forged reply"), "{running}");
        for call in ["history-1", "history-2"] {
            disconnected_reply(service.directory.path(), call).await;
        }
        drop((reader, writer));
        service.stop().await;
    }

    #[tokio::test]
    async fn half_closed_input_still_receives_the_requested_result() {
        let service = Running::start().await;
        let mut client = service.client().await;
        write_frame(&mut client, &RuntimeCommand::Status)
            .await
            .unwrap();
        client.shutdown().await.unwrap();
        let mut reader = FrameReader::new(BufReader::new(client));
        let frame = reader.next_frame().await.unwrap().unwrap();
        let event: RuntimeEventKind = serde_json::from_slice(&frame).unwrap();
        assert!(matches!(event, RuntimeEventKind::AuthStatus { .. }));
        let frame = reader.next_frame().await.unwrap().unwrap();
        let event: RuntimeEventKind = serde_json::from_slice(&frame).unwrap();
        assert!(matches!(event, RuntimeEventKind::Done));
        service.stop().await;
    }

    #[tokio::test]
    async fn interactive_input_and_eof_stay_on_the_attached_request_and_release_it() {
        let service = Running::start().await;
        let mut client = service.client().await;
        let mut command = attached_command();
        if let RuntimeCommand::RunTask { interactive, .. } = &mut command {
            *interactive = Some(true);
        }
        write_frame(&mut client, &command).await.unwrap();
        let (reader, mut writer) = client.into_split();
        let mut reader = FrameReader::new(BufReader::new(reader));
        let ready: RuntimeEventKind =
            serde_json::from_slice(&reader.next_frame().await.unwrap().unwrap()).unwrap();
        assert!(
            matches!(ready, RuntimeEventKind::TaskReady { conversation_id, .. } if conversation_id == "persisted-task")
        );
        reader.next_frame().await.unwrap().unwrap();
        write_frame(
            &mut writer,
            &RuntimeCommand::WorkerInput {
                attachments: None,
                input_id: "input-one".into(),
                input: "A reply in the existing tab".into(),
            },
        )
        .await
        .unwrap();
        let answer: RuntimeEventKind =
            serde_json::from_slice(&reader.next_frame().await.unwrap().unwrap()).unwrap();
        assert!(
            matches!(answer, RuntimeEventKind::Answer { conversation_id, text, .. } if conversation_id == "persisted-task" && text == "A reply in the existing tab")
        );
        reader.next_frame().await.unwrap().unwrap();
        writer.shutdown().await.unwrap();
        let done = timeout(TEST_HANG_LIMIT, reader.next_frame())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert!(matches!(
            serde_json::from_slice::<RuntimeEventKind>(&done).unwrap(),
            RuntimeEventKind::Done
        ));
        #[derive(serde::Deserialize)]
        struct Input {
            id: u32,
            input: String,
        }
        let admitted: Input =
            serde_json::from_slice(&fs::read(service.wait_for("worker-input.json").await).unwrap())
                .unwrap();
        assert_eq!(admitted.input, "A reply in the existing tab");
        assert_eq!(
            fs::read_to_string(service.wait_for("worker-detached").await).unwrap(),
            admitted.id.to_string()
        );
        status(service.client().await).await;
        drop((reader, writer));
        service.stop().await;
    }

    #[tokio::test]
    async fn browser_requests_use_the_registered_host_and_never_reach_the_requesting_client() {
        use crate::browser::{BrowserAction, BrowserRequest, BrowserResponse, BrowserUserTab};
        use crate::protocol::HostCommand;

        let directory = tempfile::tempdir().unwrap();
        let script = directory.path().join("browser-routing.mjs");
        fs::write(&script, r#"
          import {createInterface} from 'node:readline';
          import {readFileSync,writeFileSync} from 'node:fs';
          import {join} from 'node:path';
          const emit=(id,event)=>process.stdout.write(JSON.stringify({version:1,id,event})+'\n');
          const calls=new Map();
          function next(id) {
            const call=calls.get(id);
            if(call.results.length===call.commands.length) {
              writeFileSync(join(process.argv[2],'browser-replies.json'),JSON.stringify(call.results));
              calls.delete(id);emit(id,{type:'done'});return;
            }
            emit(id,{type:'host_call',call_id:'step-'+call.results.length,command:call.commands[call.results.length]});
          }
          createInterface({input:process.stdin}).on('line',line=>{
            const {id,command}=JSON.parse(line);
            if(command.type==='logout') {
              calls.set(id,{commands:JSON.parse(readFileSync(join(process.argv[2],'browser-commands.json'),'utf8')),results:[]});
              next(id);
            } else if(command.type==='host_reply') {calls.get(id).results.push(command.result);next(id);}
            else {emit(id,{type:'configured'});emit(id,{type:'done'});}
          });
        "#).unwrap();
        let legacy = "11111111-1111-4111-8111-111111111111";
        let missing = "22222222-2222-4222-8222-222222222222";
        let session_id = uuid::Uuid::new_v4();
        let original_session = uuid::Uuid::new_v4();
        let browser = |host: &str, session_id, operation: &str, action| HostCommand::Browser {
            host_id: host.into(),
            request: BrowserRequest {
                owner_id: "fixture-owner".into(),
                session_id,
                operation_id: operation.into(),
                action,
            },
        };
        let commands = vec![
            browser(legacy, session_id, "discover", BrowserAction::ListUserTabs),
            browser(
                legacy,
                session_id,
                "claim",
                BrowserAction::ClaimUserTab {
                    tab: BrowserUserTab {
                        target_id: "fixture-target".into(),
                        url: "https://example.com/account".into(),
                        title: "Fixture account".into(),
                    },
                },
            ),
            browser(
                legacy,
                original_session,
                "original-status",
                BrowserAction::Status,
            ),
            browser(missing, session_id, "missing-host", BrowserAction::Status),
        ];
        fs::write(
            directory.path().join("browser-commands.json"),
            serde_json::to_vec(&commands).unwrap(),
        )
        .unwrap();
        let service = Running::start_script(directory, script, ShutdownReason::Requested).await;
        let mut worker = service.client().await;
        // Exact legacy registration: it advertises Browser, with no user-tab capability.
        worker.write_all(br#"{"type":"connect_worker","node":{"host_id":"11111111-1111-4111-8111-111111111111","name":"legacy-fixture","rex_server":null,"agent_program":"/example/agent","home_directory":"/example","coordinator":"tailscale://100.64.0.10","launch":{"model":null,"state_dir":null,"runtime":null,"config":null,"instructions":null},"machine":null,"capabilities":{"resume_agent":true,"browser":true}}}"#).await.unwrap();
        worker.write_all(b"\n").await.unwrap();
        let (worker_read, mut worker_write) = worker.into_split();
        let mut worker_read = FrameReader::new(BufReader::new(worker_read));
        let ready: RuntimeEventKind =
            serde_json::from_slice(&worker_read.next_frame().await.unwrap().unwrap()).unwrap();
        assert!(matches!(ready, RuntimeEventKind::WorkerReady { .. }));

        let mut client = service.client().await;
        write_frame(&mut client, &RuntimeCommand::Logout)
            .await
            .unwrap();
        let (client_read, client_write) = client.into_split();
        let mut client_read = FrameReader::new(BufReader::new(client_read));
        let (from_worker, first) = timeout(TEST_HANG_LIMIT, async {
            tokio::select! {
                frame = worker_read.next_frame() => (true, frame),
                frame = client_read.next_frame() => (false, frame),
            }
        })
        .await
        .unwrap();
        let first: RuntimeEventKind = serde_json::from_slice(&first.unwrap().unwrap()).unwrap();
        if !from_worker {
            drop((worker_read, worker_write, client_read, client_write));
            service.stop().await;
            panic!("Explicit browser requests must not reach the requesting client: {first:?}");
        }
        let RuntimeEventKind::HostCall { call_id, command } = first else {
            panic!("Expected the original browser connection's status");
        };
        let HostCommand::Browser { host_id, request } = *command else {
            panic!("Expected browser status on its named host");
        };
        assert_eq!(host_id, legacy);
        assert_eq!(request.owner_id, "fixture-owner");
        assert_eq!(request.session_id, original_session);
        assert_eq!(request.operation_id, "original-status");
        assert!(matches!(request.action, BrowserAction::Status));
        write_frame(
            &mut worker_write,
            &RuntimeCommand::HostReply {
                call_id,
                result: HostResult::Browser {
                    response: BrowserResponse::Disconnected {
                        session_id: original_session,
                        message: "Original connection is unavailable; inspect before continuing."
                            .into(),
                    },
                },
            },
        )
        .await
        .unwrap();

        let done: RuntimeEventKind =
            serde_json::from_slice(&client_read.next_frame().await.unwrap().unwrap()).unwrap();
        assert!(matches!(done, RuntimeEventKind::Done));
        let replies: Vec<HostResult> = serde_json::from_slice(
            &fs::read(service.wait_for("browser-replies.json").await).unwrap(),
        )
        .unwrap();
        assert_eq!(replies.len(), 4);
        for reply in &replies[..2] {
            assert!(
                matches!(reply, HostResult::Browser { response: BrowserResponse::Failed { session_id: actual, message } }
                if *actual == session_id && message.contains("Update Beep Boop"))
            );
        }
        assert!(
            matches!(&replies[2], HostResult::Browser { response: BrowserResponse::Disconnected { session_id, .. } } if *session_id == original_session)
        );
        assert!(
            matches!(&replies[3], HostResult::Failed { message, .. } if message.contains("no fallback host"))
        );
        assert!(
            timeout(Duration::from_millis(25), worker_read.next_frame())
                .await
                .is_err(),
            "No new browser session or replay may follow an unavailable original handle"
        );
        drop((worker_read, worker_write, client_read, client_write));
        service.stop().await;
    }

    #[tokio::test]
    async fn ordinary_requests_execute_owned_effects_without_delegating_to_the_sending_cli() {
        let service = Running::start().await;
        let mut client = service.client().await;
        write_frame(&mut client, &RuntimeCommand::Logout)
            .await
            .unwrap();
        let mut reader = FrameReader::new(BufReader::new(client));
        let event: RuntimeEventKind =
            serde_json::from_slice(&reader.next_frame().await.unwrap().unwrap()).unwrap();
        assert!(matches!(event, RuntimeEventKind::AuthStatus { .. }));
        let event: RuntimeEventKind =
            serde_json::from_slice(&reader.next_frame().await.unwrap().unwrap()).unwrap();
        assert!(matches!(event, RuntimeEventKind::Done));
        let result: HostResult =
            serde_json::from_slice(&fs::read(service.wait_for("reply.json").await).unwrap())
                .unwrap();
        assert!(
            matches!(&result,HostResult::Process{exit_code:0,stdout,..} if stdout=="synthetic\n"),
            "{result:?}"
        );
        drop(reader);
        service.stop().await;
    }

    #[tokio::test]
    async fn ordinary_clients_cannot_mutate_authoritative_node_connectivity() {
        let service = Running::start().await;
        let mut client = service.client().await;
        write_frame(
            &mut client,
            &RuntimeCommand::SetConnectedNodes {
                host_ids: vec!["forged".into()],
            },
        )
        .await
        .unwrap();
        let mut reader = FrameReader::new(BufReader::new(client));
        assert!(reader.next_frame().await.unwrap().is_none());
        assert!(!service.directory.path().join("admitted").exists());
        drop(reader);
        service.stop().await;
    }

    #[tokio::test]
    async fn a_task_terminal_request_is_refused_its_host_call_and_never_receives_it() {
        let service = Running::start().await;
        let mut client = service.client().await;
        write_frame(&mut client, &attached_command()).await.unwrap();
        let mut reader = FrameReader::new(BufReader::new(client));
        let mut frames = Vec::new();
        loop {
            let frame = timeout(TEST_HANG_LIMIT, reader.next_frame())
                .await
                .unwrap()
                .unwrap()
                .unwrap();
            let event: RuntimeEventKind = serde_json::from_slice(&frame).unwrap();
            let done = matches!(event, RuntimeEventKind::Done);
            frames.push(event);
            if done {
                break;
            }
        }
        assert!(
            !frames.iter().any(|event| matches!(
                event,
                RuntimeEventKind::HostCall { .. } | RuntimeEventKind::HostCancel { .. }
            )),
            "A task terminal must never be sent an effect to run: {frames:?}"
        );
        let reply: HostResult =
            serde_json::from_slice(&fs::read(service.wait_for("reply.json").await).unwrap())
                .unwrap();
        assert!(
            matches!(
                reply,
                HostResult::Failed {
                    delivery: Some(crate::protocol::HostDelivery::NotStarted),
                    ..
                }
            ),
            "{reply:?}"
        );
        drop(reader);
        service.stop().await;
    }

    #[tokio::test]
    async fn child_exit_closes_the_listener_and_preserves_saved_state() {
        let service = Running::start().await;
        let mut client = service.client().await;
        write_frame(&mut client, &RuntimeCommand::ListTasks)
            .await
            .unwrap();
        let mut reader = FrameReader::new(BufReader::new(client));
        let frame = reader.next_frame().await.unwrap().unwrap();
        let event: RuntimeEventKind = serde_json::from_slice(&frame).unwrap();
        assert!(matches!(event, RuntimeEventKind::Failure { .. }));
        drop(reader);
        let Running {
            directory,
            stop,
            task,
        } = service;
        drop(stop);
        assert!(
            timeout(TEST_HANG_LIMIT, task)
                .await
                .unwrap()
                .unwrap()
                .is_err()
        );
        assert!(!directory.path().join(SOCKET_NAME).exists());
        assert!(directory.path().join("writer.lock").is_file());
    }

    #[tokio::test]
    async fn notices_reach_watchers_without_finishing_the_worker_request() {
        let service = Running::start().await;
        let mut watcher = service.client().await;
        write_frame(&mut watcher, &RuntimeCommand::Watch)
            .await
            .unwrap();
        let mut watcher = FrameReader::new(BufReader::new(watcher));
        let mut worker = service.client().await;
        write_frame(&mut worker, &RuntimeCommand::Login)
            .await
            .unwrap();
        let mut worker = FrameReader::new(BufReader::new(worker));
        let frame = timeout(TEST_HANG_LIMIT, watcher.next_frame())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let event: RuntimeEventKind = serde_json::from_slice(&frame).unwrap();
        assert!(matches!(event, RuntimeEventKind::Notice { .. }));
        let mut notice_count = 0;
        let mut answer_count = 0;
        loop {
            let frame = worker.next_frame().await.unwrap().unwrap();
            match serde_json::from_slice::<RuntimeEventKind>(&frame).unwrap() {
                RuntimeEventKind::Notice { .. } => notice_count += 1,
                RuntimeEventKind::AuthStatus { .. } => answer_count += 1,
                RuntimeEventKind::Done => break,
                _ => panic!("Unexpected worker event"),
            }
        }
        assert_eq!((notice_count, answer_count), (1, 1));
        drop((watcher, worker));
        service.stop().await;
    }

    #[tokio::test]
    async fn network_authorization_finishes_before_protocol_admission() {
        let directory = tempfile::tempdir().unwrap();
        let script = directory.path().join("fixture.mjs");
        fs::write(&script, FIXTURE).unwrap();
        let runtime = Arc::new(
            Runtime::start(
                &script,
                OwnerClaim::acquire(directory.path(), &script, None).unwrap(),
            )
            .unwrap(),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut denied_client = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (server, peer) = listener.accept().await.unwrap();
        let denied_peer = peer;
        let rejected_runtime = runtime.clone();
        let rejected_state = directory.path().to_owned();
        let rejected = tokio::spawn(async move {
            authenticated(
                server,
                rejected_runtime,
                Arc::new(
                    crate::broker::Broker::new(
                        None,
                        &rejected_state,
                        crate::rex::RexClient::for_process(None).unwrap(),
                    )
                    .unwrap(),
                ),
                peer,
                async {
                    anyhow::bail!("Rejected synthetic peer");
                },
            )
            .await
        });
        let _ = write_frame(&mut denied_client, &RuntimeCommand::Status).await;
        assert!(rejected.await.unwrap().is_err());
        let mut bytes = Vec::new();
        let _ = denied_client.read_to_end(&mut bytes).await;
        assert!(bytes.is_empty());
        assert!(!directory.path().join("admitted").exists());

        let allowed_client = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (server, peer) = listener.accept().await.unwrap();
        let options = socket2::SockRef::from(&server).try_clone().unwrap();
        let allowed_state = directory.path().to_owned();
        let allowed_runtime = runtime.clone();
        let allowed = tokio::spawn(async move {
            authenticated(
                server,
                allowed_runtime,
                Arc::new(
                    crate::broker::Broker::new(
                        None,
                        &allowed_state,
                        crate::rex::RexClient::for_process(None).unwrap(),
                    )
                    .unwrap(),
                ),
                peer,
                async { Ok(()) },
            )
            .await
        });
        status(allowed_client).await;
        allowed.await.unwrap().unwrap();
        assert!(options.keepalive().unwrap());
        assert_eq!(
            options.tcp_keepalive_time().unwrap(),
            Duration::from_secs(30)
        );
        assert_eq!(
            options.tcp_keepalive_interval().unwrap(),
            Duration::from_secs(10)
        );
        assert_eq!(options.tcp_keepalive_retries().unwrap(), 3);
        drop(options);
        assert!(directory.path().join("admitted").exists());
        Arc::try_unwrap(runtime)
            .ok()
            .unwrap()
            .close()
            .await
            .unwrap();
        #[derive(serde::Deserialize)]
        #[serde(tag = "event", rename_all = "snake_case")]
        enum Receipt {
            PeerRejected {
                peer: std::net::SocketAddr,
                reason: String,
            },
            #[serde(other)]
            Other,
        }
        timeout(TEST_HANG_LIMIT, async {
            loop {
                let saved = fs::read_to_string(directory.path().join("diagnostics/runtime.jsonl")).unwrap_or_default();
                if saved.lines().any(|line| matches!(serde_json::from_str::<Receipt>(line).unwrap(), Receipt::PeerRejected { peer, reason } if peer == denied_peer && reason == "Rejected synthetic peer")) { break; }
                sleep(Duration::from_millis(5)).await;
            }
        }).await.unwrap();
    }

    #[tokio::test]
    async fn oauth_callbacks_keep_the_active_login_id_and_are_rejected_on_other_calls() {
        #[derive(serde::Deserialize)]
        struct Callback {
            id: u32,
            target: String,
        }
        let service = Running::start().await;
        let mut login = service.client().await;
        write_frame(&mut login, &RuntimeCommand::Login)
            .await
            .unwrap();
        let target = "http://127.0.0.1:1455/auth/callback?code=synthetic&state=expected";
        write_frame(
            &mut login,
            &RuntimeCommand::OAuthCallback {
                target: target.into(),
            },
        )
        .await
        .unwrap();
        let callback = service.wait_for("callback.json").await;
        let value: Callback = serde_json::from_slice(&fs::read(&callback).unwrap()).unwrap();
        assert_eq!(value.target, target);
        assert_eq!(
            value.id,
            fs::read_to_string(service.wait_for("login-id").await)
                .unwrap()
                .parse::<u32>()
                .unwrap()
        );
        let mut login = FrameReader::new(BufReader::new(login));
        let mut results = 0;
        loop {
            let frame = login.next_frame().await.unwrap().unwrap();
            match serde_json::from_slice::<RuntimeEventKind>(&frame).unwrap() {
                RuntimeEventKind::AuthStatus { .. } => results += 1,
                RuntimeEventKind::Done => break,
                _ => {}
            }
        }
        assert_eq!(results, 1);
        fs::remove_file(callback).unwrap();
        let mut other = service.client().await;
        let mut attached = attached_command();
        if let RuntimeCommand::RunTask { interactive, .. } = &mut attached {
            *interactive = Some(true);
        }
        write_frame(&mut other, &attached).await.unwrap();
        let (other_read, mut other_write) = other.into_split();
        let mut other = FrameReader::new(BufReader::new(other_read));
        other.next_frame().await.unwrap().unwrap();
        // A separate socket cannot smuggle a callback through a non-login call.
        write_frame(
            &mut other_write,
            &RuntimeCommand::OAuthCallback {
                target: target.into(),
            },
        )
        .await
        .unwrap();
        service.wait_for("worker-detached").await;
        assert!(!service.directory.path().join("callback.json").exists());
        drop((login, other, other_write));
        service.stop().await;
    }

    #[tokio::test]
    async fn a_disconnected_task_terminal_gets_no_fallback_host_execution() {
        let service = Running::start().await;
        let mut client = service.client().await;
        write_frame(&mut client, &attached_command()).await.unwrap();
        drop(client);
        let path = service.wait_for("reply.json").await;
        let reply: HostResult = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
        assert!(
            matches!(
                reply,
                HostResult::Failed {
                    delivery: Some(crate::protocol::HostDelivery::NotStarted),
                    ..
                }
            ),
            "{reply:?}"
        );
        status(service.client().await).await;
        service.stop().await;
    }

    #[tokio::test]
    async fn socket_cleanup_preserves_foreign_replacements() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join(SOCKET_NAME);
        fs::write(&path, "foreign file").unwrap();
        assert!(SocketOwner::bind(path.clone()).is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), "foreign file");
        fs::remove_file(&path).unwrap();
        let (listener, owner) = SocketOwner::bind(path.clone()).unwrap();
        fs::remove_file(&path).unwrap();
        fs::write(&path, "replacement").unwrap();
        drop(owner);
        drop(listener);
        assert_eq!(fs::read_to_string(path).unwrap(), "replacement");
    }

    struct BoundaryService {
        state: PathBuf,
        stop: oneshot::Sender<()>,
        task: tokio::task::JoinHandle<Result<()>>,
    }

    impl BoundaryService {
        async fn start(state: PathBuf, config_file: Option<PathBuf>) -> Self {
            fs::create_dir_all(&state).unwrap();
            let dreams_source = match config_file {
                Some(file) => crate::dreams::DreamsPolicySource::Config(Some(file)),
                None => crate::dreams::DreamsPolicySource::Unconfigured,
            };
            let policy = dreams_source.load(&state).unwrap();
            let script = state.join("fixture.mjs");
            fs::write(
                &script,
                "import readline from 'node:readline';\nconst rl = readline.createInterface({ input: process.stdin });\nrl.on('line', (line) => {\n  const req = JSON.parse(line);\n  if (req.command.type === 'configure_coordinator' || req.command.type === 'set_connected_nodes' || req.command.type === 'run_background') {\n    process.stdout.write(JSON.stringify({ version: 1, id: req.id, event: { type: 'done' } }) + '\\n');\n  } else if (req.command.type === 'observe_main') {\n    process.stdout.write(JSON.stringify({ version: 1, id: req.id, event: { type: 'main_ready', conversation_id: '1', cwd: '/', model: { provider: 'openai', model_id: 'fixture', reasoning: null, fast: false } } }) + '\\n');\n    process.stdout.write(JSON.stringify({ version: 1, id: req.id, event: { type: 'worker_idle' } }) + '\\n');\n  } else if (req.command.type === 'read_task_graph') {\n    process.stdout.write(JSON.stringify({ version: 1, id: req.id, event: { type: 'task_graph', graph: { nodes: [], conversations: [], omitted: 0, work: [] } } }) + '\\n');\n    process.stdout.write(JSON.stringify({ version: 1, id: req.id, event: { type: 'done' } }) + '\\n');\n  } else {\n    process.stderr.write('UNEXPECTED_RUNTIME_COMMAND:' + req.command.type + '\\n');\n  }\n});\n",
            )
            .unwrap();
            let (stop, stopped) = oneshot::channel::<()>();
            let state_for_task = state.clone();
            let task = tokio::spawn(async move {
                super::serve_with_transport(
                    &script,
                    OwnerClaim::acquire(&state_for_task, &script, None).unwrap(),
                    None,
                    crate::tailnet::PeerPolicy::new(&[], &[]).unwrap(),
                    crate::tailnet::Daemon::default(),
                    crate::rex::RexClient::for_process(None).unwrap(),
                    None,
                    policy,
                    dreams_source,
                    async {
                        let _ = stopped.await;
                        Ok(ShutdownReason::Requested)
                    },
                )
                .await
            });
            Self { state, stop, task }
        }

        async fn connect(&self) -> UnixStream {
            let deadline = Instant::now() + TEST_HANG_LIMIT;
            loop {
                match connect(&self.state).await {
                    Ok(stream) => return stream,
                    Err(_) => {
                        assert!(Instant::now() < deadline);
                        sleep(Duration::from_millis(5)).await;
                    }
                }
            }
        }

        async fn request_events(&self, request: NativeRequest) -> Vec<NativeEvent> {
            let stream = self.connect().await;
            let (r, mut w) = stream.into_split();
            write_frame(&mut w, &RuntimeCommand::Native { request })
                .await
                .unwrap();
            let mut reader = FrameReader::new(BufReader::new(r));
            let mut events = Vec::new();
            loop {
                let Some(frame) = timeout(TEST_HANG_LIMIT, reader.next_frame())
                    .await
                    .unwrap()
                    .unwrap()
                else {
                    break;
                };
                let event: NativeEvent = serde_json::from_slice(&frame).unwrap();
                let done = matches!(event, NativeEvent::Done);
                events.push(event);
                if done {
                    break;
                }
            }
            events
        }

        async fn shutdown(self) {
            let _ = self.stop.send(());
            let _ = self.task.await;
        }
    }

    #[tokio::test]
    async fn dreams_service_boundary_lists_shows_and_applies_without_touching_pi() {
        use crate::dreams::ContentDigest;

        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        let repo = dir.path().join("repo");
        let sample = crate::dreams::ops::test_support::write_sample_proposal(
            &repo,
            &state,
            "service-run-1",
            "# Before\n",
            "# After service apply\n",
        );
        let config = dir.path().join("config.toml");
        fs::write(&config, dreams_config(&repo, "AGENTS.md")).unwrap();
        let service = BoundaryService::start(state, Some(config)).await;

        // Observe advertises dreams: Some(true) from service boundary.
        let mut observe_sock = service.connect().await;
        write_frame(
            &mut observe_sock,
            &RuntimeCommand::Native {
                request: NativeRequest::Observe {
                    input_ids: vec![],
                    source_status: None,
                    task_graph: None,
                },
            },
        )
        .await
        .unwrap();
        let (obs_read, _obs_write) = observe_sock.into_split();
        let mut obs_reader = FrameReader::new(BufReader::new(obs_read));
        let advertised_dreams;
        loop {
            let frame = timeout(TEST_HANG_LIMIT, obs_reader.next_frame())
                .await
                .unwrap()
                .unwrap()
                .unwrap();
            match serde_json::from_slice::<NativeEvent>(&frame).unwrap() {
                NativeEvent::Ready { dreams, .. } => {
                    advertised_dreams = dreams;
                    break;
                }
                NativeEvent::Commands { .. } => continue,
                other => panic!("Unexpected observe event: {other:?}"),
            }
        }
        assert_eq!(advertised_dreams, Some(true));
        drop(_obs_write);
        drop(obs_reader);

        let list_events = service.request_events(NativeRequest::DreamsList).await;
        assert!(matches!(
            list_events.first(),
            Some(NativeEvent::DreamsList {
                pending_count: 1,
                ..
            })
        ));

        let show_events = service
            .request_events(NativeRequest::DreamsShow {
                run: sample.run.as_str().to_owned(),
            })
            .await;
        let Some(NativeEvent::DreamsShow { report }) = show_events.into_iter().next() else {
            panic!("Expected DreamsShow");
        };
        assert!(report.can_apply);
        let approval = report.outcome_sha256.unwrap();

        let bad_events = service
            .request_events(NativeRequest::DreamsApply {
                run: sample.run.as_str().to_owned(),
                approve: ContentDigest::of(b"wrong").as_str().to_owned(),
            })
            .await;
        assert!(matches!(
            bad_events.first(),
            Some(NativeEvent::Failure { .. })
        ));

        let ok_events = service
            .request_events(NativeRequest::DreamsApply {
                run: sample.run.as_str().to_owned(),
                approve: approval,
            })
            .await;
        assert!(matches!(
            ok_events.first(),
            Some(NativeEvent::DreamsApplied {
                already_applied: false,
                ..
            })
        ));
        assert_eq!(
            fs::read_to_string(repo.join("AGENTS.md")).unwrap(),
            "# After service apply\n"
        );

        service.shutdown().await;
    }

    fn dreams_config(repository: &std::path::Path, editable: &str) -> String {
        format!(
            "[dreams]\nrepository = {repository:?}\neditable = [{editable:?}]\nwindow_hours = 24\n\n[[dreams.checks]]\nname = \"ok\"\nargv = [\"true\"]\ntimeout_seconds = 10\n"
        )
    }

    #[tokio::test]
    async fn dreams_requests_use_the_policy_that_the_configuration_gives_now() {
        use crate::{native::DreamsProposalStatus, protocol::ErrorCode};

        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        let repo = dir.path().join("repo");
        let sample = crate::dreams::ops::test_support::write_sample_proposal(
            &repo,
            &state,
            "service-policy-1",
            "# Before\n",
            "# After policy apply\n",
        );
        let config = dir.path().join("config.toml");
        fs::write(&config, dreams_config(&repo, "AGENTS.md")).unwrap();
        let service = BoundaryService::start(state, Some(config.clone())).await;
        let run = sample.run.as_str().to_owned();
        let list = || async {
            service
                .request_events(NativeRequest::DreamsList)
                .await
                .into_iter()
                .next()
                .unwrap()
        };
        let show = || async {
            service
                .request_events(NativeRequest::DreamsShow { run: run.clone() })
                .await
                .into_iter()
                .next()
                .unwrap()
        };
        let NativeEvent::DreamsShow { report } = show().await else {
            panic!("Expected DreamsShow");
        };
        assert!(report.can_apply);
        let approval = report.outcome_sha256.unwrap();
        let apply = || async {
            service
                .request_events(NativeRequest::DreamsApply {
                    run: run.clone(),
                    approve: approval.clone(),
                })
                .await
                .into_iter()
                .next()
                .unwrap()
        };
        let unchanged = || {
            assert_eq!(
                fs::read_to_string(repo.join("AGENTS.md")).unwrap(),
                "# Before\n"
            );
            assert_eq!(
                crate::dreams::ops::test_support::git(&repo, &["rev-list", "--count", "HEAD"])
                    .trim(),
                "1"
            );
        };

        for narrowed_or_removed in [
            dreams_config(&repo, "NOTES.md"),
            "poll_interval_seconds = 60\n".to_owned(),
        ] {
            fs::write(&config, narrowed_or_removed).unwrap();
            let NativeEvent::DreamsList {
                runs,
                pending_count,
            } = list().await
            else {
                panic!("Expected DreamsList");
            };
            assert_eq!(pending_count, 0);
            assert_eq!(
                runs[0].proposal_status,
                Some(DreamsProposalStatus::PolicyChanged)
            );
            let NativeEvent::DreamsShow { report } = show().await else {
                panic!("Expected DreamsShow");
            };
            assert!(!report.can_apply);
            let refused = apply().await;
            assert!(
                matches!(
                    &refused,
                    NativeEvent::Failure {
                        code: Some(ErrorCode::InvalidRequest),
                        message,
                    } if message == crate::dreams::apply::POLICY_CHANGED
                ),
                "{refused:?}"
            );
            unchanged();
        }

        fs::write(&config, "[dreams\n").unwrap();
        for answer in [list().await, show().await, apply().await] {
            assert!(
                matches!(
                    &answer,
                    NativeEvent::Failure { message, .. }
                        if message.contains("Invalid agent TOML configuration")
                ),
                "{answer:?}"
            );
        }
        unchanged();

        fs::write(&config, dreams_config(&repo, "AGENTS.md")).unwrap();
        assert!(matches!(
            apply().await,
            NativeEvent::DreamsApplied {
                already_applied: false,
                ..
            }
        ));
        assert_eq!(
            fs::read_to_string(repo.join("AGENTS.md")).unwrap(),
            "# After policy apply\n"
        );

        service.shutdown().await;
    }

    #[tokio::test]
    async fn dreams_apply_is_refused_while_restore_held_while_reads_stay_available() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        let repo = dir.path().join("repo");
        let sample = crate::dreams::ops::test_support::write_sample_proposal(
            &repo,
            &state,
            "service-held-1",
            "# Before\n",
            "# After held apply\n",
        );
        fs::write(state.join("restore-hold.json"), "{}").unwrap();
        let config = dir.path().join("config.toml");
        fs::write(&config, dreams_config(&repo, "AGENTS.md")).unwrap();
        let service = BoundaryService::start(state, Some(config)).await;

        let list_events = service.request_events(NativeRequest::DreamsList).await;
        assert!(matches!(
            list_events.first(),
            Some(NativeEvent::DreamsList {
                pending_count: 1,
                ..
            })
        ));

        let show_events = service
            .request_events(NativeRequest::DreamsShow {
                run: sample.run.as_str().to_owned(),
            })
            .await;
        let Some(NativeEvent::DreamsShow { report }) = show_events.into_iter().next() else {
            panic!("Expected DreamsShow");
        };
        let approval = report.outcome_sha256.unwrap();

        let apply_events = service
            .request_events(NativeRequest::DreamsApply {
                run: sample.run.as_str().to_owned(),
                approve: approval,
            })
            .await;
        assert!(matches!(
            apply_events.first(),
            Some(NativeEvent::Failure {
                code: Some(crate::protocol::ErrorCode::CoordinatorUnavailable),
                message,
            }) if message.contains("backup release")
        ));
        assert_eq!(
            fs::read_to_string(repo.join("AGENTS.md")).unwrap(),
            "# Before\n"
        );

        service.shutdown().await;
    }

    #[tokio::test]
    async fn service_status_reports_running_coordinator_metadata() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        let service = BoundaryService::start(state.clone(), None).await;

        let events = service.request_events(NativeRequest::ServiceStatus).await;
        assert_eq!(events.len(), 2);
        match &events[0] {
            NativeEvent::ServiceStatus {
                coordinator_id,
                pid,
                version,
                executable_path,
                state_dir,
            } => {
                assert_eq!(coordinator_id, &runtime_coordinator_id(&state));
                assert_eq!(*pid, std::process::id());
                assert_eq!(version, env!("CARGO_PKG_VERSION"));
                assert!(executable_path.is_some());
                assert_eq!(state_dir, &state.to_string_lossy());
            }
            other => panic!("Expected ServiceStatus event, got {other:?}"),
        }
        assert!(matches!(events[1], NativeEvent::Done));

        service.shutdown().await;
    }

    #[tokio::test]
    async fn native_task_graph_delivers_snapshot_and_done() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        let service = BoundaryService::start(state, None).await;

        let events = service.request_events(NativeRequest::TaskGraph).await;
        assert_eq!(events.len(), 2);
        assert!(matches!(events[0], NativeEvent::TaskGraph { .. }));
        assert!(matches!(events[1], NativeEvent::Done));

        service.shutdown().await;
    }

    fn runtime_coordinator_id(state: &std::path::Path) -> String {
        crate::coordinator_id::CoordinatorId::load_or_mint(state)
            .unwrap()
            .to_string()
    }
}
