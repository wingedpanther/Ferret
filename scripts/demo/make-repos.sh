#!/bin/zsh
# Builds ~/ferret-demo: five small made-up projects for recording the demo.
# Nothing in here comes from a real project. Run it again to start fresh.
set -euo pipefail
ROOT=${1:-$HOME/ferret-demo}
[[ -e $ROOT && ! -e $ROOT/.ferret-demo ]] && { echo "$ROOT exists and isn't a demo folder; not touching it"; exit 1; }
rm -rf "$ROOT"
mkdir -p "$ROOT" && touch "$ROOT/.ferret-demo"

g() { git -c user.name="Demo" -c user.email="demo@example.com" "$@"; }
commit() {  # commit <repo> <days ago> <message>
  (cd "$ROOT/$1" && g add -A && GIT_AUTHOR_DATE="$(date -v-${2}d -R)" GIT_COMMITTER_DATE="$(date -v-${2}d -R)" g commit -qm "$3")
}
file() { mkdir -p "${1:h}"; cat > "$1"; }

# ---------- pantry: Rust CLI that tracks a kitchen inventory ----------
R=$ROOT/pantry; mkdir -p $R; (cd $R && git init -q -b main)
file $R/Cargo.toml <<'EOF'
[package]
name = "pantry"
version = "0.4.1"
edition = "2021"

[dependencies]
serde = { version = "1", features = ["derive"] }
toml = "0.8"
EOF
file $R/src/main.rs <<'EOF'
mod config;
mod ledger;

use config::Config;
use ledger::Ledger;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let config = match Config::load() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("pantry: {e}");
            return ExitCode::FAILURE;
        }
    };
    let mut ledger = Ledger::open(&config.data_dir).expect("open ledger");

    match args.first().map(String::as_str) {
        Some("add") => {
            let item = &args[1];
            let amount = ledger::parse_amount(&args[2]).expect("amount like 2kg or 500g");
            ledger.add(item, amount);
            println!("added {amount} of {item}");
        }
        Some("low") => {
            for (item, left) in ledger.running_low(config.low_threshold) {
                println!("{item:<20} {left}");
            }
        }
        _ => println!("usage: pantry add <item> <amount> | pantry low"),
    }
    ExitCode::SUCCESS
}
EOF
file $R/src/config.rs <<'EOF'
use serde::Deserialize;
use std::path::PathBuf;

#[derive(Debug, Deserialize)]
pub struct Config {
    pub data_dir: PathBuf,
    pub low_threshold: f64,
    pub units: String,
}

impl Config {
    pub fn load() -> Result<Self, String> {
        let path = dirs_home().join(".config/pantry.toml");
        let text = std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        toml::from_str(&text).map_err(|e| e.to_string())
    }
}

fn dirs_home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default())
}
EOF
file $R/src/ledger.rs <<'EOF'
use std::collections::BTreeMap;
use std::path::Path;

/// Grams of each item on the shelf.
pub struct Ledger {
    items: BTreeMap<String, f64>,
}

impl Ledger {
    pub fn open(dir: &Path) -> std::io::Result<Self> {
        std::fs::create_dir_all(dir)?;
        Ok(Ledger { items: BTreeMap::new() })
    }

    pub fn add(&mut self, item: &str, grams: f64) {
        *self.items.entry(item.to_lowercase()).or_default() += grams;
    }

    pub fn running_low(&self, threshold: f64) -> impl Iterator<Item = (&String, &f64)> {
        self.items.iter().filter(move |(_, g)| **g < threshold)
    }
}

/// "2kg" → 2000.0, "500g" → 500.0
pub fn parse_amount(s: &str) -> Option<f64> {
    let s = s.trim().to_lowercase();
    if let Some(kg) = s.strip_suffix("kg") {
        return kg.parse::<f64>().ok().map(|n| n * 1000.0);
    }
    s.strip_suffix('g').unwrap_or(&s).parse().ok()
}
EOF
file $R/README.md <<'EOF'
# pantry

Keeps track of what's on the kitchen shelf. `pantry add rice 2kg`, `pantry low`.
EOF
commit pantry 9 "First version: add and low"
perl -0pi -e 's/    pub fn running_low/    pub fn remove(&mut self, item: &str, grams: f64) {\n        if let Some(g) = self.items.get_mut(&item.to_lowercase()) {\n            *g = (*g - grams).max(0.0);\n        }\n    }\n\n    pub fn running_low/' $R/src/ledger.rs

# ---------- tidepool: Go job queue ----------
R=$ROOT/tidepool; mkdir -p $R; (cd $R && git init -q -b main)
file $R/go.mod <<'EOF'
module github.com/example/tidepool

go 1.23
EOF
file $R/cmd/tidepool/main.go <<'EOF'
package main

import (
	"context"
	"log"
	"os/signal"
	"syscall"

	"github.com/example/tidepool/internal/config"
	"github.com/example/tidepool/internal/queue"
)

func main() {
	cfg, err := config.Load("tidepool.toml")
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	pool := make([]*queue.Worker, cfg.Workers)
	for i := range pool {
		pool[i] = queue.NewWorker(i, cfg)
		go pool[i].Run(ctx)
	}
	log.Printf("tidepool: %d workers on %s", cfg.Workers, cfg.QueueURL)
	<-ctx.Done()
}
EOF
file $R/internal/config/config.go <<'EOF'
package config

import (
	"os"
	"time"

	"github.com/BurntSushi/toml"
)

type Config struct {
	QueueURL   string        `toml:"queue_url"`
	Workers    int           `toml:"workers"`
	JobTimeout time.Duration `toml:"job_timeout"`
	MaxRetries int           `toml:"max_retries"`
}

func Load(path string) (*Config, error) {
	cfg := &Config{Workers: 4, JobTimeout: 30 * time.Second, MaxRetries: 5}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	_, err = toml.Decode(string(data), cfg)
	return cfg, err
}
EOF
file $R/internal/queue/worker.go <<'EOF'
package queue

import (
	"context"
	"log"
	"math/rand"
	"time"

	"github.com/example/tidepool/internal/config"
)

const (
	baseBackoff = 200 * time.Millisecond
	maxBackoff  = 30 * time.Second
)

// Worker pulls jobs off the queue and runs them one at a time.
type Worker struct {
	id  int
	cfg *config.Config
}

func NewWorker(id int, cfg *config.Config) *Worker {
	return &Worker{id: id, cfg: cfg}
}

func (w *Worker) Run(ctx context.Context) {
	for ctx.Err() == nil {
		job, err := Next(ctx, w.cfg.QueueURL)
		if err != nil {
			continue
		}
		for attempt := 0; attempt <= w.cfg.MaxRetries; attempt++ {
			if err = job.Run(ctx, w.cfg.JobTimeout); err == nil {
				break
			}
			log.Printf("worker %d: job %s failed (attempt %d): %v", w.id, job.ID, attempt+1, err)
			time.Sleep(nextBackoff(attempt))
		}
	}
}

// nextBackoff doubles the wait each attempt, with jitter, up to maxBackoff.
func nextBackoff(attempt int) time.Duration {
	d := baseBackoff << attempt
	if d > maxBackoff {
		d = maxBackoff
	}
	return d/2 + time.Duration(rand.Int63n(int64(d/2)))
}
EOF
file $R/internal/queue/job.go <<'EOF'
package queue

import (
	"context"
	"time"
)

type Job struct {
	ID      string
	Kind    string
	Payload []byte
}

func Next(ctx context.Context, url string) (*Job, error) {
	// Long-polls the queue; returns when a job arrives or ctx ends.
	return &Job{ID: "demo", Kind: "noop"}, ctx.Err()
}

func (j *Job) Run(ctx context.Context, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	<-ctx.Done()
	return nil
}
EOF
file $R/README.md <<'EOF'
# tidepool

A small job queue worker pool. Retries failed jobs with exponential backoff.
EOF
commit tidepool 4 "Worker pool with retries"
perl -pi -e 's/MaxRetries: 5/MaxRetries: 8/' $R/internal/config/config.go
perl -pi -e 's/^\t\t\tcontinue$/\t\t\ttime.Sleep(baseBackoff)\n\t\t\tcontinue/' $R/internal/queue/worker.go

# ---------- orbit-web: TypeScript front end ----------
R=$ROOT/orbit-web; mkdir -p $R; (cd $R && git init -q -b main)
file $R/package.json <<'EOF'
{
  "name": "orbit-web",
  "private": true,
  "scripts": { "dev": "vite", "build": "tsc && vite build" },
  "dependencies": { "react": "^19.0.0", "react-dom": "^19.0.0" },
  "devDependencies": { "typescript": "^5.6.0", "vite": "^6.0.0" }
}
EOF
file $R/src/config.ts <<'EOF'
export interface Config {
  apiBase: string;
  pollIntervalMs: number;
  maxRetries: number;
}

export const config: Config = {
  apiBase: import.meta.env.VITE_API_BASE ?? "http://localhost:8080",
  pollIntervalMs: 5_000,
  maxRetries: 4,
};
EOF
file $R/src/api/client.ts <<'EOF'
import { config } from "../config";

export type Launch = { id: string; name: string; window: string; status: "go" | "hold" | "scrub" };

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Retries 5xx and network errors with exponential backoff. */
export async function fetchWithBackoff(path: string, init?: RequestInit): Promise<Response> {
  let delay = 250;
  for (let attempt = 0; ; attempt++) {
    try {
      const res = await fetch(config.apiBase + path, init);
      if (res.status < 500 || attempt >= config.maxRetries) return res;
    } catch (err) {
      if (attempt >= config.maxRetries) throw err;
    }
    await sleep(delay);
    delay = Math.min(delay * 2, 8_000);
  }
}

export async function listLaunches(): Promise<Launch[]> {
  const res = await fetchWithBackoff("/v1/launches");
  if (!res.ok) throw new Error(`launches: ${res.status}`);
  return res.json();
}
EOF
file $R/src/App.tsx <<'EOF'
import { useEffect, useState } from "react";
import { listLaunches, type Launch } from "./api/client";
import { Timeline } from "./components/Timeline";

export default function App() {
  const [launches, setLaunches] = useState<Launch[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    listLaunches().then(setLaunches).catch((e) => setError(String(e)));
  }, []);

  if (error) return <p className="error">{error}</p>;
  return (
    <main>
      <h1>Upcoming launches</h1>
      <Timeline launches={launches} />
    </main>
  );
}
EOF
file $R/src/components/Timeline.tsx <<'EOF'
import type { Launch } from "../api/client";

const badge = { go: "🟢", hold: "🟡", scrub: "🔴" } as const;

export function Timeline({ launches }: { launches: Launch[] }) {
  return (
    <ol className="timeline">
      {launches.map((l) => (
        <li key={l.id}>
          <span>{badge[l.status]}</span> <strong>{l.name}</strong> <time>{l.window}</time>
        </li>
      ))}
    </ol>
  );
}
EOF
file $R/README.md <<'EOF'
# orbit-web

Launch schedule dashboard. `npm run dev`.
EOF
mkdir -p $R/design
magick -size 1200x800 gradient:'#1d2021'-'#3c3836' \
  -fill '#fbf1c7' -draw 'circle 140,120 142,122' -draw 'circle 980,90 982,92' -draw 'circle 760,210 761,211' \
  -draw 'circle 320,300 321,301' -draw 'circle 1080,380 1082,382' -draw 'circle 520,90 521,91' \
  -fill '#d65d0e' -draw 'circle 600,1500 600,820' \
  -fill '#fabd2f' -font /System/Library/Fonts/Helvetica.ttc -pointsize 120 -annotate +90+420 'ORBIT' \
  -fill '#ebdbb2' -pointsize 44 -annotate +96+500 'Next launch window · Tue 04:12 UTC' \
  $R/design/launch-poster.png
commit orbit-web 2 "Launch timeline"
perl -pi -e 's/Upcoming launches/Next launches/' $R/src/App.tsx
perl -pi -e 's/8_000/10_000/' $R/src/api/client.ts
file $R/src/hooks/usePolling.ts <<'EOF'
import { useEffect } from "react";
import { config } from "../config";

export function usePolling(fn: () => void, ms = config.pollIntervalMs) {
  useEffect(() => {
    const id = setInterval(fn, ms);
    return () => clearInterval(id);
  }, [fn, ms]);
}
EOF

# ---------- weather-bot: Python chat bot ----------
R=$ROOT/weather-bot; mkdir -p $R; (cd $R && git init -q -b main)
file $R/pyproject.toml <<'EOF'
[project]
name = "weather-bot"
version = "1.2.0"
requires-python = ">=3.11"
dependencies = ["httpx>=0.27"]
EOF
file $R/bot/__init__.py <<'EOF'
EOF
file $R/bot/config.py <<'EOF'
from dataclasses import dataclass
import os


@dataclass(frozen=True)
class Config:
    api_key: str
    city: str = "Dublin"
    units: str = "metric"
    max_retries: int = 3

    @classmethod
    def from_env(cls) -> "Config":
        return cls(api_key=os.environ["WEATHER_API_KEY"], city=os.getenv("WEATHER_CITY", "Dublin"))
EOF
file $R/bot/fetch.py <<'EOF'
import random
import time

import httpx

from .config import Config


def retry_with_backoff(fn, retries: int, base: float = 0.5):
    """Calls fn until it succeeds, sleeping base * 2^n (with jitter) between tries."""
    for attempt in range(retries + 1):
        try:
            return fn()
        except httpx.HTTPError:
            if attempt == retries:
                raise
            time.sleep(base * 2**attempt * random.uniform(0.5, 1.0))


def forecast(cfg: Config) -> dict:
    url = f"https://api.example.com/forecast?q={cfg.city}&units={cfg.units}"
    get = lambda: httpx.get(url, headers={"X-Key": cfg.api_key}, timeout=5).raise_for_status()
    return retry_with_backoff(get, cfg.max_retries).json()
EOF
file $R/bot/main.py <<'EOF'
from .config import Config
from .fetch import forecast


def summary(data: dict) -> str:
    today = data["days"][0]
    return f"{today['summary']}, {today['low']}–{today['high']}°"


if __name__ == "__main__":
    print(summary(forecast(Config.from_env())))
EOF
file $R/README.md <<'EOF'
# weather-bot

Posts the day's forecast. Set `WEATHER_API_KEY`, then `python -m bot.main`.
EOF
commit weather-bot 6 "Forecast summary"

# ---------- notes-sync: Swift package ----------
R=$ROOT/notes-sync; mkdir -p $R; (cd $R && git init -q -b main)
file $R/Package.swift <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotesSync",
    platforms: [.macOS(.v14)],
    targets: [.target(name: "NotesSync")]
)
EOF
file $R/Sources/NotesSync/Config.swift <<'EOF'
import Foundation

public struct Config: Sendable {
    public var server: URL
    public var folder: URL
    public var interval: Duration = .seconds(30)

    public init(server: URL, folder: URL) {
        self.server = server
        self.folder = folder
    }
}
EOF
file $R/Sources/NotesSync/SyncEngine.swift <<'EOF'
import Foundation

/// Pushes local note changes to the server and pulls remote ones.
public actor SyncEngine {
    private let config: Config
    private var failures = 0

    public init(config: Config) {
        self.config = config
    }

    public func run() async {
        while !Task.isCancelled {
            do {
                try await syncOnce()
                failures = 0
                try await Task.sleep(for: config.interval)
            } catch {
                failures += 1
                try? await Task.sleep(for: backoff(failures))
            }
        }
    }

    private func syncOnce() async throws {
        let notes = try FileManager.default.contentsOfDirectory(at: config.folder, includingPropertiesForKeys: [.contentModificationDateKey])
        var request = URLRequest(url: config.server.appending(path: "sync"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(notes.map(\.lastPathComponent))
        _ = try await URLSession.shared.data(for: request)
    }

    /// 1s, 2s, 4s… capped at five minutes.
    private func backoff(_ failures: Int) -> Duration {
        .seconds(min(300, 1 << min(failures, 8)))
    }
}
EOF
file $R/README.md <<'EOF'
# NotesSync

Keeps a folder of Markdown notes in sync with a server. Backs off when the server is down.
EOF
commit notes-sync 12 "Sync engine"

echo "built $ROOT"
