use std::time::Duration;

use launcher_core::{Error, Result};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use url::Url;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OAuthCallback {
    pub code: String,
    pub state: String,
    /// Exact redirect URI used for the request, including the runtime port.
    pub redirect_uri: String,
}

/// Accepts exactly one loopback redirect and extracts `code`/`state`.
pub async fn wait_for_callback(
    listener: TcpListener,
    expected_state: &str,
    redirect_uri: &str,
    timeout: Duration,
) -> Result<OAuthCallback> {
    let accepted = tokio::time::timeout(timeout, listener.accept())
        .await
        .map_err(|_| {
            Error::Authentication("timed out waiting for the Microsoft sign-in callback".into())
        })?;
    let (mut stream, _peer) = accepted?;

    let mut buffer = vec![0u8; 8192];
    let read = tokio::time::timeout(Duration::from_secs(10), stream.read(&mut buffer))
        .await
        .map_err(|_| Error::Authentication("timed out reading the sign-in callback".into()))??;
    let request = String::from_utf8_lossy(&buffer[..read]);
    let request_line = request.lines().next().unwrap_or_default();
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or_default();
    let target = parts.next().unwrap_or_default();

    if method != "GET" {
        respond(&mut stream, 405, "Method Not Allowed").await;
        return Err(Error::Authentication(
            "unexpected request on the sign-in callback port".into(),
        ));
    }

    let parsed = Url::parse(&format!("http://localhost{target}"))
        .map_err(|e| Error::Authentication(format!("invalid sign-in callback URL: {e}")))?;
    let mut code = None;
    let mut state = None;
    let mut error = None;
    let mut error_description = None;
    for (key, value) in parsed.query_pairs() {
        match key.as_ref() {
            "code" => code = Some(value.to_string()),
            "state" => state = Some(value.to_string()),
            "error" => error = Some(value.to_string()),
            "error_description" => error_description = Some(value.to_string()),
            _ => {}
        }
    }

    if let Some(error) = error {
        let description = error_description.unwrap_or(error);
        respond(
            &mut stream,
            200,
            "Sign-in was cancelled. You can close this window.",
        )
        .await;
        return Err(Error::Authentication(format!(
            "Microsoft sign-in failed: {description}"
        )));
    }
    let code = code.filter(|c| !c.is_empty()).ok_or_else(|| {
        Error::Authentication("Microsoft sign-in callback did not contain a code".into())
    })?;
    let state = state
        .ok_or_else(|| Error::Authentication("sign-in callback did not contain state".into()))?;
    if state != expected_state {
        respond(&mut stream, 400, "State mismatch. Sign-in aborted.").await;
        return Err(Error::Authentication(
            "sign-in callback state did not match the request".into(),
        ));
    }

    respond(
        &mut stream,
        200,
        "Sign-in complete. You can close this window and return to LingXi Launcher.",
    )
    .await;
    Ok(OAuthCallback {
        code,
        state,
        redirect_uri: redirect_uri.to_string(),
    })
}

async fn respond(stream: &mut tokio::net::TcpStream, status: u16, message: &str) {
    let body = format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>LingXi Launcher</title>\
         <style>body{{font-family:-apple-system,Segoe UI,sans-serif;background:#0d0f12;color:#f4f0e8;\
         display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}}\
         div{{max-width:420px;padding:32px;border:1px solid #282f39;border-radius:14px;background:#15191f}}\
         h1{{font-size:18px;margin:0 0 8px}}p{{color:#a8b0bb;font-size:13px;line-height:1.6}}</style>\
         </head><body><div><h1>LingXi Launcher</h1><p>{message}</p></div></body></html>"
    );
    let reason = if status == 200 { "OK" } else { "Error" };
    let response = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn accepts_matching_state() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let redirect = format!("http://localhost:{port}");
        let expected = redirect.clone();
        let task = tokio::spawn(async move {
            wait_for_callback(listener, "expected", &expected, Duration::from_secs(5)).await
        });
        // The server is ready; send a browser-style request.
        let mut client = tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .unwrap();
        client
            .write_all(b"GET /?code=abc&state=expected HTTP/1.1\r\nHost: localhost\r\n\r\n")
            .await
            .unwrap();
        let callback = task.await.unwrap().unwrap();
        assert_eq!(callback.code, "abc");
        assert_eq!(callback.state, "expected");
    }

    #[tokio::test]
    async fn rejects_state_mismatch() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let redirect = format!("http://localhost:{port}");
        let task = tokio::spawn(async move {
            wait_for_callback(listener, "expected", &redirect, Duration::from_secs(5)).await
        });
        let mut client = tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .unwrap();
        client
            .write_all(b"GET /?code=abc&state=other HTTP/1.1\r\nHost: localhost\r\n\r\n")
            .await
            .unwrap();
        assert!(task.await.unwrap().is_err());
    }
}
