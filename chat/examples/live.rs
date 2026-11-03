use std::io::BufRead;
use std::sync::Arc;

use serde_json::{json, Value};
use upgrade_chat::node::Node;

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let node = Node::start(&args[1], Arc::new(|e: Value| eprintln!("event {e}")))
        .await
        .unwrap();
    let call = |v: Value| {
        let node = node.clone();
        async move { node.call(v).await.map_err(|e| e.0) }
    };
    call(json!({"op": "name", "name": args[2]})).await.unwrap();
    let fresh = call(json!({"op": "state"})).await.unwrap()["contacts"] == json!([]);
    if fresh && args[2] == "invite" {
        loop {
            match call(json!({"op": "invite"})).await {
                Ok(v) => break println!("{}", v["code"]),
                Err(e) => eprintln!("invite {e}"),
            }
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        }
    } else if fresh {
        call(json!({"op": "join", "code": args[3]})).await.unwrap();
    }
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let _ = tx.send(line.unwrap());
        }
    });
    loop {
        tokio::select! {
            Some(line) = rx.recv() => {
                let state = call(json!({"op": "state"})).await.unwrap();
                let record = state["contacts"][0]["record"].clone();
                println!("{:?}", call(json!({"op": "send", "record": record, "text": line, "at": 0})).await);
            }
            _ = tokio::time::sleep(std::time::Duration::from_secs(5)) => {
                let state = call(json!({"op": "state"})).await.unwrap();
                eprintln!("state {state}");
                if let Some(record) = state["contacts"][0]["record"].as_str() {
                    eprintln!("messages {}", call(json!({"op": "messages", "record": record})).await.unwrap());
                }
            }
        }
    }
}
