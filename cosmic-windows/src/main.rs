mod compositor;
type Result<T> = std::result::Result<T, String>;
use serde_json::{Value, json};

fn response(result: Result<Value>) -> Value {
    result.unwrap_or_else(|error| {
        if error == "not_found" {
            json!({"error":"not_found"})
        } else {
            json!({"available":false})
        }
    })
}
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let valid = matches!(args.first().map(String::as_str), Some("list")) && args.len() == 1
        || matches!(args.first().map(String::as_str), Some("activate" | "close"))
            && args.len() == 2
            && !args[1].is_empty()
            && args[1].len() <= 512
            && !args[1].chars().any(char::is_control);
    // Bound even registry roundtrips; only the main thread emits JSON.
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let result = if valid {
            compositor::run(&args)
        } else {
            Err("invalid arguments".into())
        };
        let _ = sender.send(result);
    });
    let result = receiver
        .recv_timeout(std::time::Duration::from_secs(2))
        .unwrap_or_else(|_| Err("deadline".into()));
    println!("{}", response(result));
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn json_responses() {
        assert_eq!(
            response(Err("not_found".into())),
            json!({"error":"not_found"})
        );
        assert_eq!(
            response(Err("no display".into())),
            json!({"available":false})
        );
        assert_eq!(response(Ok(json!({"done":true}))), json!({"done":true}));
    }
}
