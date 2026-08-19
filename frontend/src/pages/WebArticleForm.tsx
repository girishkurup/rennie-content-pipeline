import { useCallback, useEffect, useRef, useState } from "react";
import { useAuth } from "react-oidc-context";
import {
  ALLOWED_SOURCES,
  BRANDS,
  CONTENT_GOALS,
  LANGUAGES,
  MARKETS,
  PERSONAS,
  TARGET_GROUPS,
} from "../contentTypes";
import { api, canStop, isInFlight, type ContentJob } from "../api";
import StageTracker from "../components/StageTracker";
import ReviewPanel from "../components/ReviewPanel";

interface FormState {
  market: string;
  language: string;
  brand: string;
  targetGroup: string;
  persona: string;
  goal: (typeof CONTENT_GOALS)[number];
  wordLimit: number;
  sourceUrl: string;
  sourceType: string;
  description: string;
}

const initialState: FormState = {
  market: MARKETS[0],
  language: LANGUAGES[0],
  brand: BRANDS[0],
  targetGroup: TARGET_GROUPS[0],
  persona: PERSONAS[0],
  goal: "Educational",
  wordLimit: 500,
  sourceUrl: "",
  sourceType: ALLOWED_SOURCES[0],
  description: "",
};

/**
 * Turns the structured form into the plain-text "brief" the existing
 * /chat -> pipeline_orchestration -> Orchestrator agent contract expects.
 * No backend changes needed — the agents already just take a brief string.
 *
 * The Orchestrator agent has a fetch_url tool and is instructed to use it
 * whenever the brief names a reference source URL, so the source URL below
 * gets actually fetched and used as grounding context for the Writer — not
 * just passed through as an unfetched citation.
 */
function composeBrief(form: FormState): string {
  const lines = [
    "Content type: Web Article",
    `Market: ${form.market}`,
    `Language: ${form.language}`,
    `Brand: ${form.brand}`,
    `Target group: ${form.targetGroup}`,
    `Persona: ${form.persona}`,
    `Goal of content: ${form.goal}`,
    `Word limit: approximately ${form.wordLimit} words`,
  ];
  if (form.sourceUrl.trim()) {
    lines.push("", `Reference source (${form.sourceType}): ${form.sourceUrl.trim()}`);
  }
  lines.push("", "Instructions and compliance/brand rules from the requester:", form.description.trim());
  return lines.join("\n");
}

export default function WebArticleForm() {
  const auth = useAuth();
  const token = auth.user?.id_token ?? "";

  const [form, setForm] = useState<FormState>(initialState);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState("");
  const [job, setJob] = useState<ContentJob | null>(null);
  const pollRef = useRef<number | null>(null);

  const set = <K extends keyof FormState>(key: K, value: FormState[K]) =>
    setForm((f) => ({ ...f, [key]: value }));

  const stopPolling = useCallback(() => {
    if (pollRef.current !== null) {
      window.clearInterval(pollRef.current);
      pollRef.current = null;
    }
  }, []);

  useEffect(() => stopPolling, [stopPolling]);

  const pollJob = useCallback(
    (jobId: string) => {
      stopPolling();
      pollRef.current = window.setInterval(async () => {
        try {
          const latest = await api.getJob(token, jobId);
          setJob(latest);
          if (!isInFlight(latest.status)) stopPolling();
        } catch {
          // transient — next tick retries
        }
      }, 4000);
    },
    [token, stopPolling]
  );

  const refreshJob = useCallback(
    async (jobId: string) => {
      const latest = await api.getJob(token, jobId);
      setJob(latest);
      // A review decision can send the job back into flight (revision loop)
      // or out of it (approved/escalated) — restart polling either way so
      // it keeps tracking whatever happens next.
      if (isInFlight(latest.status)) pollJob(jobId);
      else stopPolling();
    },
    [token, pollJob, stopPolling]
  );

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.description.trim()) {
      setError("Please describe what you want the Creator Agent to generate.");
      return;
    }
    setError("");
    setSubmitting(true);
    setJob(null);
    try {
      const brief = composeBrief(form);
      const result = await api.sendChat(token, brief);
      const initialJob = await api.getJob(token, result.job_id);
      setJob(initialJob);
      pollJob(result.job_id);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSubmitting(false);
    }
  };

  const [stopping, setStopping] = useState(false);

  const handleStop = async () => {
    if (!job) return;
    setStopping(true);
    try {
      await api.stopJob(token, job.job_id);
      const latest = await api.getJob(token, job.job_id);
      setJob(latest);
      stopPolling();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setStopping(false);
    }
  };

  return (
    <div className="page">
      <h1>Web Article</h1>
      <p className="page-subtitle">Fill in the brief. Saving and generating happen together.</p>

      <form className="content-form" onSubmit={handleSubmit}>
        <div className="form-grid">
          <label>
            Market
            <select value={form.market} onChange={(e) => set("market", e.target.value)}>
              {MARKETS.map((m) => (
                <option key={m}>{m}</option>
              ))}
            </select>
          </label>

          <label>
            Language
            <select value={form.language} onChange={(e) => set("language", e.target.value)}>
              {LANGUAGES.map((l) => (
                <option key={l}>{l}</option>
              ))}
            </select>
          </label>

          <label>
            Brand name
            <select value={form.brand} onChange={(e) => set("brand", e.target.value)}>
              {BRANDS.map((b) => (
                <option key={b}>{b}</option>
              ))}
            </select>
          </label>

          <label>
            Target group
            <select value={form.targetGroup} onChange={(e) => set("targetGroup", e.target.value)}>
              {TARGET_GROUPS.map((g) => (
                <option key={g}>{g}</option>
              ))}
            </select>
          </label>

          <label>
            Persona
            <select value={form.persona} onChange={(e) => set("persona", e.target.value)}>
              {PERSONAS.map((p) => (
                <option key={p}>{p}</option>
              ))}
            </select>
          </label>

          <label>
            Goal of content
            <select value={form.goal} onChange={(e) => set("goal", e.target.value as FormState["goal"])}>
              {CONTENT_GOALS.map((g) => (
                <option key={g}>{g}</option>
              ))}
            </select>
          </label>

          <label className="span-2">
            Word limit: <strong>{form.wordLimit}</strong> words
            <input
              type="range"
              min={100}
              max={1000}
              step={50}
              value={form.wordLimit}
              onChange={(e) => set("wordLimit", Number(e.target.value))}
            />
          </label>

          <label>
            Source type
            <select value={form.sourceType} onChange={(e) => set("sourceType", e.target.value)}>
              {ALLOWED_SOURCES.map((s) => (
                <option key={s}>{s}</option>
              ))}
            </select>
          </label>

          <label>
            Source URL <span className="optional">(optional)</span>
            <input
              type="url"
              placeholder="https://www.nhs.uk/…"
              value={form.sourceUrl}
              onChange={(e) => set("sourceUrl", e.target.value)}
            />
          </label>

          <label className="span-2">
            Description — what should the Creator Agent generate? Include any
            compliance or brand rules it must follow.
            <textarea
              rows={6}
              value={form.description}
              onChange={(e) => set("description", e.target.value)}
              placeholder="e.g. Explain how antacids work in plain language for a worried first-time user. Must include the mandatory disclaimer. Avoid the word “cure”."
            />
          </label>
        </div>

        {error && <p className="form-error">{error}</p>}

        <button type="submit" disabled={submitting} className="primary-button">
          {submitting ? "Submitting…" : "Save & Generate Content"}
        </button>
      </form>

      {job && (
        <div className="job-result">
          <div className="job-result-header">
            <div>
              <h2>Job {job.job_id}</h2>
              <p className="job-status">
                Status: <span className={`status-pill status-${job.status}`}>{job.status}</span>
                {isInFlight(job.status) && " — polling for updates…"}
              </p>
              {isInFlight(job.status) && job.current_step && (
                <p className="job-current-step">
                  <span className="live-dot" aria-hidden="true" />
                  {job.current_step}
                </p>
              )}
              {typeof job.ai_review_rounds === "number" && (
                <p className="job-meta">AI review rounds: {job.ai_review_rounds}</p>
              )}
            </div>
            {canStop(job.status) && (
              <button className="danger-button" disabled={stopping} onClick={handleStop}>
                {stopping ? "Stopping…" : "Stop"}
              </button>
            )}
          </div>

          <StageTracker job={job} />

          {job.status === "pending_human_review" && (
            <ReviewPanel jobId={job.job_id} onDecided={() => refreshJob(job.job_id)} />
          )}
        </div>
      )}
    </div>
  );
}
