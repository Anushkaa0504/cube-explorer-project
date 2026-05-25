//! cube-cli — fast terminal client for the Cube REST API.
//!
//! Mirrors `scripts/q` (bash) but compiled Rust: same JWT signing, same endpoints.
//! Cube Store (pre-aggregations) is itself written in Rust — this client talks to
//! the Node/Rust Cube server over HTTP.

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::Path;
use std::time::Duration;

const DEFAULT_BASE: &str = "http://localhost:4000";
const DEFAULT_SECRET: &str = "super-secret-please-change-me";

#[derive(Parser)]
#[command(name = "cube-cli", about = "Query the Cube Explorer semantic layer from the terminal")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// List cubes/views with measures and dimensions (compact)
    Meta,
    /// Run a load query; pass JSON as the last argument or via --query
    Query {
        /// JSON query object, e.g. '{"measures":["transactions.total_expense"]}'
        #[arg(required = true)]
        query: String,
        /// JWT role claim (dev override; groups usually come from config/users.json via cube.js)
        #[arg(short, long)]
        role: Option<String>,
        /// JWT user_id claim for row-level security
        #[arg(short = 'U', long)]
        user_id: Option<u64>,
    },
    /// Validate query without executing (/v1/dry-run)
    DryRun {
        query: String,
    },
    /// Show warehouse SQL for a query (/v1/sql)
    Sql {
        query: String,
    },
    /// List pre-aggregation build jobs
    Preagg,
}

#[derive(Serialize)]
struct JwtClaims {
    #[serde(skip_serializing_if = "Option::is_none")]
    user_id: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    role: Option<String>,
}

struct Config {
    base: String,
    secret: String,
}

fn load_dotenv() -> HashMap<String, String> {
    let mut map = HashMap::new();
    let path = Path::new(".env");
    if !path.exists() {
        return map;
    }
    let Ok(content) = fs::read_to_string(path) else {
        return map;
    };
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, val)) = line.split_once('=') else {
            continue;
        };
        let val = val.trim().trim_matches('"').trim_matches('\'');
        map.insert(key.to_string(), val.to_string());
    }
    map
}

fn config() -> Config {
    let dotenv = load_dotenv();
    let base = env::var("CUBE_BASE")
        .ok()
        .or_else(|| dotenv.get("CUBE_BASE").cloned())
        .unwrap_or_else(|| DEFAULT_BASE.to_string());
    let secret = env::var("CUBEJS_API_SECRET")
        .ok()
        .or_else(|| dotenv.get("CUBEJS_API_SECRET").cloned())
        .unwrap_or_else(|| DEFAULT_SECRET.to_string());
    Config { base, secret }
}

fn sign_jwt(secret: &str, role: Option<&str>, user_id: Option<u64>) -> Result<Option<String>> {
    if role.is_none() && user_id.is_none() {
        return Ok(None);
    }
    let claims = JwtClaims {
        user_id,
        role: role.map(str::to_string),
    };
    let token = encode(
        &Header::new(Algorithm::HS256),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )?;
    Ok(Some(token))
}

struct CubeClient {
    http: Client,
    base: String,
    secret: String,
}

impl CubeClient {
    fn new(cfg: &Config) -> Result<Self> {
        let http = Client::builder()
            .timeout(Duration::from_secs(60))
            .build()?;
        Ok(Self {
            http,
            base: cfg.base.trim_end_matches('/').to_string(),
            secret: cfg.secret.clone(),
        })
    }

    async fn get(
        &self,
        path: &str,
        query: Option<&str>,
        role: Option<&str>,
        user_id: Option<u64>,
    ) -> Result<Value> {
        let mut req = self.http.get(format!("{}{}", self.base, path));
        if let Some(q) = query {
            req = req.query(&[("query", q)]);
        }
        if let Some(token) = sign_jwt(&self.secret, role, user_id)? {
            req = req.header("Authorization", token);
        }
        let resp = req.send().await?.error_for_status()?;
        Ok(resp.json().await?)
    }

    async fn get_system(&self, path: &str) -> Result<Value> {
        let token = sign_jwt(&self.secret, Some("admin"), Some(0))?
            .context("system endpoints need a JWT")?;
        let resp = self
            .http
            .get(format!("{}{}", self.base, path))
            .header("Authorization", token)
            .send()
            .await?
            .error_for_status()?;
        Ok(resp.json().await?)
    }

    async fn load_with_poll(
        &self,
        query_json: &str,
        role: Option<&str>,
        user_id: Option<u64>,
    ) -> Result<Value> {
        for _ in 0..30 {
            let data = self
                .get("/cubejs-api/v1/load", Some(query_json), role, user_id)
                .await?;
            if data.get("error").and_then(|e| e.as_str()) == Some("Continue wait") {
                tokio::time::sleep(Duration::from_secs(1)).await;
                continue;
            }
            return Ok(data);
        }
        anyhow::bail!("timed out waiting for query (Continue wait)")
    }
}

#[derive(Deserialize)]
struct MetaCube {
    name: String,
    #[serde(rename = "type", default)]
    cube_type: Option<String>,
    #[serde(default)]
    public: Option<bool>,
    measures: Vec<MetaMember>,
    dimensions: Vec<MetaMember>,
    segments: Vec<MetaMember>,
}

#[derive(Deserialize)]
struct MetaMember {
    name: String,
}

#[derive(Deserialize)]
struct MetaResponse {
    cubes: Vec<MetaCube>,
}

async fn cmd_meta(client: &CubeClient) -> Result<()> {
    let raw = client.get("/cubejs-api/v1/meta", None, None, None).await?;
    let meta: MetaResponse = serde_json::from_value(raw)?;
    let compact: Vec<Value> = meta
        .cubes
        .iter()
        .map(|c| {
            json!({
                "name": c.name,
                "type": c.cube_type,
                "public": c.public,
                "measures": c.measures.iter().map(|m| &m.name).collect::<Vec<_>>(),
                "dimensions": c.dimensions.iter().map(|d| &d.name).collect::<Vec<_>>(),
                "segments": c.segments.iter().map(|s| &s.name).collect::<Vec<_>>(),
            })
        })
        .collect();
    println!("{}", serde_json::to_string_pretty(&json!({ "cubes": compact }))?);
    Ok(())
}

async fn cmd_query(
    client: &CubeClient,
    query: &str,
    role: Option<&str>,
    user_id: Option<u64>,
) -> Result<()> {
    let _: Value = serde_json::from_str(query).context("query must be valid JSON")?;
    let data = client.load_with_poll(query, role, user_id).await?;
    let rows = data.get("data").cloned().unwrap_or(json!([]));
    let preaggs: Vec<String> = data
        .get("results")
        .and_then(|r| r.as_array())
        .and_then(|a| a.first())
        .and_then(|r| r.get("usedPreAggregations"))
        .and_then(|u| u.as_object())
        .map(|m| m.keys().cloned().collect())
        .unwrap_or_default();
    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            "rowCount": rows.as_array().map(|a| a.len()).unwrap_or(0),
            "data": rows,
            "usedPreAggregations": preaggs,
        }))?
    );
    Ok(())
}

async fn cmd_dry_run(client: &CubeClient, query: &str) -> Result<()> {
    let _: Value = serde_json::from_str(query).context("query must be valid JSON")?;
    let data = client.get("/cubejs-api/v1/dry-run", Some(query), None, None).await?;
    println!("{}", serde_json::to_string_pretty(&data)?);
    Ok(())
}

async fn cmd_sql(client: &CubeClient, query: &str) -> Result<()> {
    let _: Value = serde_json::from_str(query).context("query must be valid JSON")?;
    let data = client
        .get("/cubejs-api/v1/sql", Some(query), None, None)
        .await?;
    println!("{}", serde_json::to_string_pretty(&data)?);
    Ok(())
}

async fn cmd_preagg(client: &CubeClient) -> Result<()> {
    let data = client
        .get_system("/cubejs-system/v1/pre-aggregations/jobs")
        .await?;
    println!("{}", serde_json::to_string_pretty(&data)?);
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let cfg = config();
    let client = CubeClient::new(&cfg)?;

    match cli.command {
        Commands::Meta => cmd_meta(&client).await?,
        Commands::Query {
            query,
            role,
            user_id,
        } => cmd_query(&client, &query, role.as_deref(), user_id).await?,
        Commands::DryRun { query } => cmd_dry_run(&client, &query).await?,
        Commands::Sql { query } => cmd_sql(&client, &query).await?,
        Commands::Preagg => cmd_preagg(&client).await?,
    }
    Ok(())
}
