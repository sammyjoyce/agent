use super::{Running, ShutdownReason, attached_command, write_frame};
use crate::{
    TEST_HANG_LIMIT,
    protocol::{HostResult, RuntimeCommand, RuntimeEventKind},
    runtime::FrameReader,
};
use std::{
    ffi::CString,
    fs::{File, OpenOptions},
    io::{ErrorKind, Read},
    os::unix::{ffi::OsStrExt, fs::OpenOptionsExt},
    path::Path,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, BufReader},
    time::{Duration, sleep, timeout},
};

struct WriteGate {
    reader: File,
    bytes: Vec<u8>,
}

impl WriteGate {
    fn new(path: &Path) -> Self {
        let path_c = CString::new(path.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(path_c.as_ptr(), 0o600) }, 0);
        Self {
            reader: OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NONBLOCK)
                .open(path)
                .unwrap(),
            bytes: Vec::new(),
        }
    }

    async fn started(&mut self) {
        timeout(TEST_HANG_LIMIT, async {
            while self.bytes.is_empty() {
                self.read_available();
                sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
    }

    fn read_available(&mut self) {
        let mut buffer = [0; 8192];
        match self.reader.read(&mut buffer) {
            Ok(count) => self.bytes.extend_from_slice(&buffer[..count]),
            Err(error) if error.kind() == ErrorKind::WouldBlock => {}
            Err(error) => panic!("Could not read fixture write: {error}"),
        }
    }

    async fn collect(&mut self) {
        loop {
            self.read_available();
            sleep(Duration::from_millis(1)).await;
        }
    }

    fn remaining(&mut self) {
        loop {
            let before = self.bytes.len();
            self.read_available();
            if self.bytes.len() == before {
                return;
            }
        }
    }
}

async fn fixture(body: &str) -> Running {
    let directory = tempfile::tempdir().unwrap();
    let script = directory.path().join("fixture.mjs");
    std::fs::write(
        &script,
        format!(
            r#"
import {{createInterface}} from 'node:readline';
import {{writeFileSync}} from 'node:fs';
import {{join}} from 'node:path';
const state=process.argv[2];
const emit=(id,event)=>process.stdout.write(JSON.stringify({{version:1,id,event}})+'\n');
createInterface({{input:process.stdin}}).on('line',line=>{{
 const {{id,command}}=JSON.parse(line);
 {body}
}});
"#
        ),
    )
    .unwrap();
    Running::start_script(directory, script, ShutdownReason::Requested).await
}

#[tokio::test]
async fn noninteractive_worker_interrupt_reaches_its_own_request() {
    let service = fixture(
        r#"
 if(command.type==='run_task') emit(id,{type:'notice',task_id:null,text:'Working'});
 else if(command.type==='interrupt') emit(id,{type:'done'});
"#,
    )
    .await;
    let mut client = service.client().await;
    write_frame(&mut client, &attached_command()).await.unwrap();
    let (reader, mut writer) = client.into_split();
    let mut reader = FrameReader::new(BufReader::new(reader));
    let event: RuntimeEventKind =
        serde_json::from_slice(&reader.next_frame().await.unwrap().unwrap()).unwrap();
    assert!(matches!(event, RuntimeEventKind::Notice { .. }));
    write_frame(&mut writer, &RuntimeCommand::Interrupt)
        .await
        .unwrap();
    let completed = timeout(TEST_HANG_LIMIT, async {
        loop {
            let event: RuntimeEventKind =
                serde_json::from_slice(&reader.next_frame().await.unwrap().unwrap()).unwrap();
            if matches!(event, RuntimeEventKind::Done) {
                return;
            }
        }
    })
    .await;
    drop((reader, writer));
    service.stop().await;
    assert!(
        completed.is_ok(),
        "The service admitted an interrupt that the runtime ignored"
    );
}

#[tokio::test]
async fn a_client_host_reply_is_rejected_and_cannot_answer_an_effect_the_service_owns() {
    let service = fixture(
        r#"
 if(command.type==='run_task') emit(id,{type:'task_ready',conversation_id:'fixture',title:'Attached'});
 else if(command.type==='logout') emit(id,{type:'host_call',call_id:'owned',command:{type:'exec',program:process.execPath,
  args:['--eval',`const fs=require('node:fs');fs.writeFileSync(${JSON.stringify(join(state,'started'))},'yes');
   const wait=()=>fs.existsSync(${JSON.stringify(join(state,'release'))})?process.stdout.write('owned result'):setTimeout(wait,5);wait()`],
  cwd:state,timeout_seconds:30}});
 else if(command.type==='host_reply') {
  writeFileSync(join(state,'replies'),JSON.stringify({id,result:command.result})+'\n',{flag:'a'});
  emit(id,{type:'auth_status',status:{state:'signed_out'}});emit(id,{type:'done'});
 } else if(command.type==='detach_worker') { writeFileSync(join(state,'detached'),String(id));emit(id,{type:'done'}); }
 "#,
    )
    .await;
    let state = service.directory.path().to_owned();
    let mut owner = service.client().await;
    write_frame(&mut owner, &RuntimeCommand::Logout)
        .await
        .unwrap();
    service.wait_for("started").await;

    let mut terminal = service.client().await;
    let mut attached = attached_command();
    if let RuntimeCommand::RunTask { interactive, .. } = &mut attached {
        *interactive = Some(true);
    }
    write_frame(&mut terminal, &attached).await.unwrap();
    let (reader, mut writer) = terminal.into_split();
    let mut reader = BufReader::new(reader);
    reader.read_line(&mut String::new()).await.unwrap();
    write_frame(
        &mut writer,
        &RuntimeCommand::HostReply {
            call_id: "owned".into(),
            result: HostResult::Written,
        },
    )
    .await
    .unwrap();
    let mut rest = Vec::new();
    timeout(TEST_HANG_LIMIT, reader.read_to_end(&mut rest))
        .await
        .expect("The service must close a client that sends a host reply")
        .unwrap();
    service.wait_for("detached").await;
    assert!(
        !state.join("replies").exists(),
        "A client's host reply must never reach the runtime"
    );

    std::fs::write(state.join("release"), "").unwrap();
    let mut owner = FrameReader::new(BufReader::new(owner));
    loop {
        let event: RuntimeEventKind =
            serde_json::from_slice(&owner.next_frame().await.unwrap().unwrap()).unwrap();
        if matches!(event, RuntimeEventKind::Done) {
            break;
        }
    }
    #[derive(serde::Deserialize)]
    struct Reply {
        result: HostResult,
    }
    let replies = std::fs::read_to_string(state.join("replies")).unwrap();
    let replies: Vec<Reply> = replies
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(
        replies.len(),
        1,
        "The owned effect is answered exactly once"
    );
    assert!(
        matches!(&replies[0].result, HostResult::Process { exit_code: 0, stdout, .. } if stdout == "owned result"),
        "{:?}",
        replies[0].result
    );
    drop((owner, writer));
    service.stop().await;
}

#[tokio::test]
async fn observers_cannot_submit_input_through_their_connection() {
    use crate::protocol::InputMode;
    let service = fixture(
        r#"
 if(command.type==='observe_main') emit(id,{type:'worker_idle'});
 else if(command.type==='submit_input') {
  writeFileSync(join(state,'unexpected-input'),command.input);
  emit(id,{type:'done'});
 } else if(command.type==='detach_main') emit(id,{type:'done'});
 "#,
    )
    .await;
    let mut client = service.client().await;
    write_frame(
        &mut client,
        &RuntimeCommand::ObserveMain { input_ids: vec![] },
    )
    .await
    .unwrap();
    let (reader, mut writer) = client.into_split();
    let mut reader = BufReader::new(reader);
    reader.read_line(&mut String::new()).await.unwrap();
    write_frame(
        &mut writer,
        &RuntimeCommand::SubmitInput {
            origin: None,
            input_id: "observer-input".into(),
            input: "must stay read-only".into(),
            mode: InputMode::Steer,
            attachments: None,
        },
    )
    .await
    .unwrap();
    let mut bytes = Vec::new();
    timeout(TEST_HANG_LIMIT, reader.read_to_end(&mut bytes))
        .await
        .unwrap()
        .unwrap();
    let submitted = service.directory.path().join("unexpected-input").exists();
    service.stop().await;
    assert!(!submitted, "An observer submitted connection-bound input");
}

#[tokio::test]
async fn shutdown_waits_for_an_inflight_write_and_records_its_real_receipt() {
    let service = fixture(r#"
 if(command.type==='logout') emit(id,{type:'host_call',call_id:'write',command:{type:'write_file',path:join(state,'write-fifo'),content:'x'.repeat(131072)}});
 else if(command.type==='host_reply') {
  writeFileSync(join(state,'write-receipt.json'),JSON.stringify(command.result));
  emit(id,{type:'done'});
 }
 "#).await;
    let mut gate = WriteGate::new(&service.directory.path().join("write-fifo"));
    let mut client = service.client().await;
    write_frame(&mut client, &RuntimeCommand::Logout)
        .await
        .unwrap();
    gate.started().await;
    let Running {
        directory,
        stop,
        mut task,
    } = service;
    stop.send(()).unwrap();
    let early = timeout(Duration::from_millis(1300), &mut task).await;
    let stopped_early = early.is_ok();
    let completed = match early {
        Ok(result) => result,
        Err(_) => tokio::select! {
            result = timeout(TEST_HANG_LIMIT, task) => result.unwrap(),
            () = gate.collect() => unreachable!(),
        },
    };
    gate.remaining();
    assert!(
        !stopped_early,
        "Service released the write owner before the write completed"
    );
    completed.unwrap().unwrap();
    assert_eq!(gate.bytes, vec![b'x'; 131072]);
    let receipt: HostResult = serde_json::from_slice(
        &std::fs::read(directory.path().join("write-receipt.json")).unwrap(),
    )
    .unwrap();
    assert!(
        matches!(receipt, HostResult::Written),
        "The write's actual receipt was lost: {receipt:?}"
    );
}

#[tokio::test]
async fn ordinary_requests_preserve_more_than_32_concurrent_effects() {
    let service = fixture(r#"
 if(command.type==='logout') {
  globalThis.results=[];
  for(let i=0;i<40;i++) emit(id,{type:'host_call',call_id:'write-'+i,command:{type:'write_file',path:join(state,'write-fifo'),content:'x'.repeat(131072)}});
 } else if(command.type==='host_reply') {
  globalThis.results.push(command.result);
  if(globalThis.results.length===40) {
   writeFileSync(join(state,'receipts.json'),JSON.stringify(globalThis.results));
   emit(id,{type:'done'});
  }
 }
 "#).await;
    let mut gate = WriteGate::new(&service.directory.path().join("write-fifo"));
    let mut client = service.client().await;
    write_frame(&mut client, &RuntimeCommand::Logout)
        .await
        .unwrap();
    gate.started().await;
    let mut reader = FrameReader::new(BufReader::new(client));
    tokio::select! {
        result = timeout(TEST_HANG_LIMIT, async {
            loop {
                let event: RuntimeEventKind = serde_json::from_slice(&reader.next_frame().await.unwrap().unwrap()).unwrap();
                if matches!(event, RuntimeEventKind::Done) { return; }
            }
        }) => result.unwrap(),
        () = gate.collect() => unreachable!(),
    }
    gate.remaining();
    let receipts: Vec<HostResult> = serde_json::from_slice(
        &std::fs::read(service.directory.path().join("receipts.json")).unwrap(),
    )
    .unwrap();
    service.stop().await;
    assert_eq!(receipts.len(), 40);
    assert!(
        receipts
            .iter()
            .all(|receipt| matches!(receipt, HostResult::Written))
    );
    assert_eq!(gate.bytes.len(), 40 * 131072);
}
