import { useState } from "react";
import { useAuth } from "react-oidc-context";
import { api, type ArtifactStage, type ContentJob } from "../api";

interface StageDef {
  stage: ArtifactStage;
  label: string;
  description: string;
  content: (job: ContentJob) => string | undefined;
  done: (job: ContentJob) => boolean;
}

const STAGES: StageDef[] = [
  {
    stage: "initial",
    label: "Initial draft",
    description: "Completed by the Writer agent",
    content: (job) => job.initial_draft,
    done: (job) => Boolean(job.initial_draft),
  },
  {
    stage: "ai_reviewed",
    label: "Brand & compliance check",
    description: "Completed by the AI Reviewer agent",
    content: (job) => job.ai_reviewed_draft,
    done: (job) => Boolean(job.ai_reviewed_draft),
  },
  {
    stage: "current",
    label: "Human-in-loop feedback",
    description:
      "Completed once a reviewer has requested at least one revision",
    content: (job) => job.draft,
    done: (job) => (job.human_review_rounds ?? 0) > 0,
  },
  {
    stage: "final",
    label: "Final version",
    description: "Completed once approved, post human-in-loop feedback",
    content: (job) => job.final_draft,
    done: (job) => Boolean(job.final_draft),
  },
];

export default function StageTracker({ job }: { job: ContentJob }) {
  const auth = useAuth();
  const token = auth.user?.id_token ?? "";
  const [openStage, setOpenStage] = useState<ArtifactStage | null>(null);
  const [savingStage, setSavingStage] = useState<ArtifactStage | null>(null);
  const [saveError, setSaveError] = useState("");

  const toggle = (stage: ArtifactStage) => setOpenStage((s) => (s === stage ? null : stage));

  const save = async (stage: ArtifactStage) => {
    setSavingStage(stage);
    setSaveError("");
    try {
      const { download_url } = await api.getArtifactUrl(token, job.job_id, stage);
      window.open(download_url, "_blank", "noopener");
    } catch (err) {
      setSaveError(err instanceof Error ? err.message : String(err));
    } finally {
      setSavingStage(null);
    }
  };

  return (
    <div className="stage-tracker">
      {STAGES.map((def, i) => {
        const isDone = def.done(job);
        const isOpen = openStage === def.stage;
        return (
          <div key={def.stage} className={`stage-item${isDone ? " stage-done" : ""}`}>
            <button
              className="stage-header"
              disabled={!isDone}
              onClick={() => toggle(def.stage)}
              aria-expanded={isOpen}
            >
              <span className={`stage-dot${isDone ? " stage-dot-done" : ""}`}>
                {isDone ? "✓" : i + 1}
              </span>
              <span className="stage-labels">
                <span className="stage-label">{def.label}</span>
                <span className="stage-description">{def.description}</span>
              </span>
              {isDone && <span className="stage-chevron">{isOpen ? "▾" : "▸"}</span>}
            </button>

            {isOpen && isDone && (
              <div className="stage-body">
                <pre>{def.content(job)}</pre>
                <button
                  className="link-button"
                  disabled={savingStage === def.stage}
                  onClick={() => save(def.stage)}
                >
                  {savingStage === def.stage ? "Preparing download…" : "Save this version"}
                </button>
              </div>
            )}
          </div>
        );
      })}
      {saveError && <p className="form-error">{saveError}</p>}
    </div>
  );
}
