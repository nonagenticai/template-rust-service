//! HTTP-level tests that need no database: the pool is lazy and never connects.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::routing::get;
use http_body_util::BodyExt;
use sqlx::postgres::PgPoolOptions;
use tower::ServiceExt;

use template_rust_service::tenant::TenantId;
use template_rust_service::{AppState, app, openapi};

fn state() -> AppState {
    let pool = PgPoolOptions::new()
        .connect_lazy("postgres://unused:unused@127.0.0.1:1/unused")
        .expect("lazy pool");
    AppState { pool }
}

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.expect("body").to_bytes();
    serde_json::from_slice(&bytes).expect("json body")
}

#[tokio::test]
async fn health_returns_ok() {
    let resp = app(state())
        .oneshot(Request::get("/health").body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(body_json(resp).await, serde_json::json!({ "status": "ok" }));
}

#[tokio::test]
async fn unknown_route_is_404() {
    let resp = app(state())
        .oneshot(Request::get("/nope").body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[test]
fn openapi_documents_health() {
    let spec = serde_json::to_value(openapi()).unwrap();
    assert!(spec["openapi"].as_str().unwrap().starts_with("3."));
    assert!(spec["paths"]["/health"]["get"].is_object(), "{spec:#}");
    assert_eq!(spec["info"]["title"], env!("CARGO_PKG_NAME"));
}

fn tenant_app() -> Router {
    Router::new().route("/t", get(|t: TenantId| async move { t.0 }))
}

async fn tenant_call(header: Option<&str>) -> (StatusCode, Vec<u8>) {
    let mut req = Request::get("/t");
    if let Some(h) = header {
        req = req.header("x-tenant-id", h);
    }
    let resp = tenant_app()
        .oneshot(req.body(Body::empty()).unwrap())
        .await
        .unwrap();
    let status = resp.status();
    let body = resp
        .into_body()
        .collect()
        .await
        .unwrap()
        .to_bytes()
        .to_vec();
    (status, body)
}

#[tokio::test]
async fn tenant_extractor_accepts_trusted_header() {
    let (status, body) = tenant_call(Some("5f868d42-aaaa-bbbb")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, b"5f868d42-aaaa-bbbb");
}

#[tokio::test]
async fn tenant_extractor_rejects_missing_or_invalid_header() {
    for h in [None, Some(""), Some("  "), Some("a b"), Some("../x")] {
        let (status, body) = tenant_call(h).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED, "header {h:?}");
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(v["detail"].as_str().unwrap().contains("X-Tenant-Id"), "{v}");
    }
    let long = "a".repeat(129);
    assert_eq!(tenant_call(Some(&long)).await.0, StatusCode::UNAUTHORIZED);
}
