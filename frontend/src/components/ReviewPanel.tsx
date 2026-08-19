import { useState } from "react";
import { useAuth } from "react-oidc-context";
import { api } from "../api";
import { isReviewer } from "../lib/groups";

interface Props {
  jobId: string;
  /** Called after a decision is submitted, so the parent can refetch the job. */
  onDecided: () => void;
}

/**
 * Inline approve/reject controls for a job currently pending_human_review —
 * shown directly in the same page the job was created from, rather than
 * requiring a trip to the separate /reviews dashboard. That dashboard still
 * exists (useful for a reviewer triaging everyone's pending jobs at once),
 * this is just the "review it right here" path for whoever is already
 * looking at the job.
 */
export default function ReviewPanel({ jobId, onDecided }: Props) {
  const auth = useAuth();
  const token = auth.user?.id_token ?? "";
  const [feedback, setFeedback] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  if (!isReviewer(auth.user)) {
    return (
      <div className="review-panel review-panel-readonly">
        <p className="job-meta">Awaiting reviewer approval.</p>
      </div>
    );
  }

  const decide = async (approved: boolean) => {
    setBusy(true);
    setError("");
    try {
      await api.reviewJob(token, jobId, approved, feedback);
      setFeedback("");
      onDecided();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="review-panel">
      <h3>Review this draft</h3>
      <textarea
        placeholder="Feedback (required if rejecting — this goes straight to the Writer agent)"
        value={feedback}
        onChange={(e) => setFeedback(e.target.value)}
        rows={3}
      />
      {error && <p className="form-error">{error}</p>}
      <div className="review-actions">
        <button className="primary-button" disabled={busy} onClick={() => decide(true)}>
          {busy ? "Submitting…" : "Approve"}
        </button>
        <button
          className="danger-button"
          disabled={busy || !feedback.trim()}
          onClick={() => decide(false)}
        >
          Reject with feedback
        </button>
      </div>
    </div>
  );
}
