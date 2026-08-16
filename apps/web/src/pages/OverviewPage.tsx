import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import { ApiError, api, type HealthResponse, type ReadyResponse } from "../api/client";
import {
  ApiIcon,
  ArrowRightIcon,
  CheckIcon,
  DatabaseIcon,
  GlobeIcon,
  RefreshIcon,
  StorageIcon,
} from "../components/Icons";
import { Spinner } from "../components/Spinner";
import { formatTime } from "../utils/format";

type ProbeState = "checking" | "online" | "degraded" | "unknown";

interface Probe<T> {
  state: ProbeState;
  detail: string;
  payload?: T;
}

interface StatusCardProps {
  title: string;
  endpoint: string;
  icon: ReactNode;
  probe: Probe<unknown>;
}

function statusLooksHealthy(status: string | undefined): boolean {
  return ["ok", "healthy", "ready"].includes(status?.toLowerCase() ?? "");
}

function StatusCard({ title, endpoint, icon, probe }: StatusCardProps) {
  return (
    <article className="status-card">
      <div className="status-card__header">
        <span className="status-card__icon">{icon}</span>
        <span className={`status-chip status-chip--${probe.state}`}>
          <span className="status-chip__dot" aria-hidden="true" />
          {probe.state === "checking"
            ? "Checking"
            : probe.state === "online"
              ? "Operational"
              : probe.state === "unknown"
                ? "Not verified"
                : "Needs attention"}
        </span>
      </div>
      <h2>{title}</h2>
      <code>{endpoint}</code>
      <p>{probe.detail}</p>
    </article>
  );
}

const initialProbe: Probe<never> = {
  state: "checking",
  detail: "Contacting the service…",
};

export function OverviewPage() {
  const [health, setHealth] = useState<Probe<HealthResponse>>(initialProbe);
  const [readiness, setReadiness] = useState<Probe<ReadyResponse>>(initialProbe);
  const [checking, setChecking] = useState(false);
  const [lastChecked, setLastChecked] = useState<Date | null>(null);
  const activeRequest = useRef<AbortController | null>(null);

  const refresh = useCallback(async () => {
    activeRequest.current?.abort();
    const controller = new AbortController();
    activeRequest.current = controller;
    setChecking(true);
    setHealth(initialProbe);
    setReadiness(initialProbe);

    const [healthResult, readyResult] = await Promise.allSettled([
      api.health(controller.signal),
      api.ready(controller.signal),
    ]);
    if (controller.signal.aborted) return;

    if (healthResult.status === "fulfilled") {
      const isHealthy = statusLooksHealthy(healthResult.value.status);
      setHealth({
        state: isHealthy ? "online" : "degraded",
        detail: isHealthy
          ? `${healthResult.value.service ?? "API process"} is accepting requests.`
          : `Process reported “${healthResult.value.status}”.`,
        payload: healthResult.value,
      });
    } else {
      setHealth({
        state: "degraded",
        detail:
          healthResult.reason instanceof ApiError
            ? healthResult.reason.message
            : "The process health check did not respond.",
      });
    }

    if (readyResult.status === "fulfilled") {
      const isReady = statusLooksHealthy(readyResult.value.status);
      setReadiness({
        state: isReady ? "online" : "degraded",
        detail: isReady
          ? "The database connection is ready for traffic."
          : `Readiness reported “${readyResult.value.status}”.`,
        payload: readyResult.value,
      });
    } else {
      setReadiness({
        state: "degraded",
        detail:
          readyResult.reason instanceof ApiError
            ? readyResult.reason.message
            : "The dependency readiness check did not respond.",
      });
    }

    setLastChecked(new Date());
    setChecking(false);
  }, []);

  useEffect(() => {
    void refresh();
    const interval = window.setInterval(() => void refresh(), 60_000);
    return () => {
      window.clearInterval(interval);
      activeRequest.current?.abort();
    };
  }, [refresh]);

  const operationalCount = [health, readiness].filter((probe) => probe.state === "online").length + 1;
  const visibleChecksHealthy = health.state === "online" && readiness.state === "online";

  return (
    <div className="page page--overview">
      <section className="page-heading page-heading--split">
        <div>
          <span className="eyebrow">System overview</span>
          <h1>Your small stack, at a glance.</h1>
          <p>Live process and dependency checks for the production-shaped, scale-to-zero path.</p>
        </div>
        <button className="button button--secondary" type="button" onClick={() => void refresh()} disabled={checking}>
          {checking ? <Spinner label="Refreshing service status" /> : <RefreshIcon />}
          Refresh status
        </button>
      </section>

      <section className="summary-banner" aria-label="System summary">
        <div className="summary-banner__score" aria-hidden="true">
          <span>{operationalCount}</span>/4
        </div>
        <div>
          <span className="summary-banner__label">Service path</span>
          <strong>
            {visibleChecksHealthy
              ? "Visible checks healthy; R2 remains unverified"
              : `${operationalCount} of 4 components verified operational`}
          </strong>
          <small>Last checked {formatTime(lastChecked)} · automatic refresh every minute</small>
        </div>
        <div className="summary-banner__meter" aria-hidden="true">
          {[0, 1, 2, 3].map((index) => (
            <span key={index} className={index < operationalCount ? "is-active" : ""} />
          ))}
        </div>
      </section>

      <section className="status-grid" aria-label="Live service checks" aria-live="polite">
        <StatusCard title="API process" endpoint="GET /health" icon={<ApiIcon />} probe={health} />
        <StatusCard title="Data readiness" endpoint="GET /ready" icon={<DatabaseIcon />} probe={readiness} />
        <StatusCard
          title="Static frontend"
          endpoint="Cloudflare Pages"
          icon={<GlobeIcon />}
          probe={{ state: "online", detail: "This immutable frontend bundle loaded successfully." }}
        />
        <StatusCard
          title="Object transfer"
          endpoint="R2 configuration"
          icon={<StorageIcon />}
          probe={{
            state: "unknown",
            detail: "No R2 health probe is exposed. A successful signed upload verifies this path on demand.",
          }}
        />
      </section>

      <section className="architecture-card" aria-labelledby="request-path-title">
        <div className="section-heading">
          <div>
            <span className="eyebrow">Request path</span>
            <h2 id="request-path-title">Built to go quiet when you do.</h2>
          </div>
          <span className="quiet-pill"><CheckIcon /> min instances: 0</span>
        </div>

        <div className="flow" aria-label="Cloud architecture request flow">
          <div className="flow__node">
            <GlobeIcon />
            <span>Cloudflare</span>
            <small>Static edge</small>
          </div>
          <ArrowRightIcon className="flow__arrow" />
          <div className="flow__node flow__node--accent">
            <ApiIcon />
            <span>Cloud Run</span>
            <small>Scale-to-zero API</small>
          </div>
          <ArrowRightIcon className="flow__arrow" />
          <div className="flow__destinations">
            <div className="flow__node">
              <DatabaseIcon />
              <span>Neon</span>
              <small>Relational data</small>
            </div>
            <div className="flow__node">
              <StorageIcon />
              <span>R2</span>
              <small>Object data</small>
            </div>
          </div>
        </div>
      </section>
    </div>
  );
}
