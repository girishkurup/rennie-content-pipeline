import { useCallback, useEffect, useState } from "react";
import { useAuth } from "react-oidc-context";
import { api, type ContentJob } from "../api";

export default function ReviewerDashboard() {
  const auth = useAuth();
  const token = auth.user?.id_token ?? "";

  const [jobs, setJobs] = useState<ContentJob[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [feedback, setFeedback] = useState<Record<string, string>>({});
  const [busyJobId, setBusyJobId] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const res = await api.listJobs(token, "pending_human_review");
      setJobs(res.jobs);
      setError("");
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }, [token]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  const decide = async (jobId: string, approved: boolean) => {
    setBusyJobId(jobId);
    try {
      await api.reviewJob(token, jobId, approved, feedback[jobId]);
      setJobs((prev) => prev.filter((j) => j.job_id !== jobId));
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusyJobId(null);
    }
  };

  return (
    <div className="page">
      <h1>Reviewer dashboard</h1>
      <p className="page-subtitle">
        Drafts waiting on human review.{" "}
        <button className="link-button" onClick={refresh}>
          Refresh
        </button>
      </p>

      {error && <p className="form-error">{error}</p>}
      {loading && jobs.length === 0 && <p>Loading…</p>}
      {!loading && jobs.length === 0 && <p>Nothing waiting on review right now.</p>}

      <div className="review-list">
        {jobs.map((job) => (
          <div key={job.job_id} className="review-card">
            <div className="review-card-header">
              <span className="job-id">{job.job_id}</span>
              {typeof job.human_review_rounds === "number" && job.human_review_rounds > 0 && (
                <span className="badge">Revision round {job.human_review_rounds}</span>
              )}
            </div>
            <p className="brief-excerpt">
              <strong>Brief:</strong> {job.brief}
            </p>
            <pre className="draft-preview-inline">{job.draft}</pre>

            <textarea
              placeholder="Feedback (required if rejecting)"
              value={feedback[job.job_id] ?? ""}
              onChange={(e) => setFeedback((f) => ({ ...f, [job.job_id]: e.target.value }))}
              rows={3}
            />

            <div className="review-actions">
              <button
                className="primary-button"
                disabled={busyJobId === job.job_id}
                onClick={() => decide(job.job_id, true)}
              >
                Approve
              </button>
              <button
                className="danger-button"
                disabled={busyJobId === job.job_id || !feedback[job.job_id]?.trim()}
                onClick={() => decide(job.job_id, false)}
              >
                Reject with feedback
              </button>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
