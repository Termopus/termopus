use base64::Engine;
use std::collections::HashMap;

/// Handles proxying HTTP requests to a local port.
pub struct HttpProxy {
    client: reqwest::Client,
    port: u16,
}

impl HttpProxy {
    pub fn new(port: u16) -> Self {
        let client = reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("Failed to create HTTP client");

        Self { client, port }
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    /// Get a reference to the reqwest client (cheap to clone for spawning).
    pub fn client(&self) -> &reqwest::Client {
        &self.client
    }

    /// Proxy an HTTP request to localhost:PORT and return the response.
    pub async fn proxy_request(
        &self,
        request_id: &str,
        method: &str,
        path: &str,
        headers: &HashMap<String, String>,
        body: Option<&str>,
    ) -> ProxyResponse {
        Self::proxy_request_with(&self.client, self.port, request_id, method, path, headers, body)
            .await
    }

    /// Static version for use from spawned tasks (takes client + port directly).
    pub async fn proxy_request_with(
        client: &reqwest::Client,
        port: u16,
        request_id: &str,
        method: &str,
        path: &str,
        headers: &HashMap<String, String>,
        body: Option<&str>,
    ) -> ProxyResponse {
        let url = format!("http://localhost:{}{}", port, path);

        let http_method = match method.to_uppercase().as_str() {
            "GET" => reqwest::Method::GET,
            "POST" => reqwest::Method::POST,
            "PUT" => reqwest::Method::PUT,
            "DELETE" => reqwest::Method::DELETE,
            "HEAD" => reqwest::Method::HEAD,
            "OPTIONS" => reqwest::Method::OPTIONS,
            "PATCH" => reqwest::Method::PATCH,
            other => {
                return ProxyResponse {
                    request_id: request_id.to_string(),
                    status: 400,
                    headers: HashMap::new(),
                    body: base64::engine::general_purpose::STANDARD
                        .encode(format!("Unsupported method: {}", other)),
                };
            }
        };

        let mut req = client.request(http_method, &url);

        // Forward headers (skip Host — reqwest sets it automatically)
        for (key, value) in headers {
            let lower = key.to_lowercase();
            if lower != "host" && lower != "connection" {
                req = req.header(key.as_str(), value.as_str());
            }
        }

        // Set body if present
        if let Some(body_b64) = body {
            match base64::engine::general_purpose::STANDARD.decode(body_b64) {
                Ok(body_bytes) => {
                    req = req.body(body_bytes);
                }
                Err(e) => {
                    tracing::warn!("Failed to decode request body: {}", e);
                }
            }
        }

        // Execute request
        match req.send().await {
            Ok(response) => {
                let status = response.status().as_u16();

                let mut resp_headers = HashMap::new();
                for (key, value) in response.headers() {
                    if let Ok(v) = value.to_str() {
                        resp_headers.insert(key.to_string(), v.to_string());
                    }
                }

                match response.bytes().await {
                    Ok(body_bytes) => {
                        let body_b64 = base64::engine::general_purpose::STANDARD
                            .encode(&body_bytes);
                        ProxyResponse {
                            request_id: request_id.to_string(),
                            status,
                            headers: resp_headers,
                            body: body_b64,
                        }
                    }
                    Err(e) => {
                        tracing::error!("Failed to read response body: {}", e);
                        ProxyResponse {
                            request_id: request_id.to_string(),
                            status: 502,
                            headers: HashMap::new(),
                            body: base64::engine::general_purpose::STANDARD
                                .encode(format!("Failed to read response: {}", e)),
                        }
                    }
                }
            }
            Err(e) => {
                tracing::error!("HTTP proxy request failed: {} {}: {}", method, url, e);
                ProxyResponse {
                    request_id: request_id.to_string(),
                    status: 502,
                    headers: HashMap::new(),
                    body: base64::engine::general_purpose::STANDARD
                        .encode(format!("Proxy error: {}", e)),
                }
            }
        }
    }
}

/// Response from the proxy, ready to serialize as RelayMessage::HttpResponse.
pub struct ProxyResponse {
    pub request_id: String,
    pub status: u16,
    pub headers: HashMap<String, String>,
    pub body: String,
}
