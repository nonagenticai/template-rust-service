use axum::Json;
use serde::Serialize;
use utoipa::ToSchema;

#[derive(Debug, Serialize, ToSchema)]
pub struct Health {
    /// Always `ok` when the process is serving HTTP.
    pub status: String,
}

/// Liveness probe.
///
/// Answers 200 while the HTTP server runs. It does not touch the database, so a DB outage
/// does not make the orchestrator restart a healthy process.
#[utoipa::path(
    get,
    path = "/health",
    tag = "health",
    responses((status = 200, description = "Service is up", body = Health))
)]
pub async fn health() -> Json<Health> {
    Json(Health {
        status: "ok".to_owned(),
    })
}
