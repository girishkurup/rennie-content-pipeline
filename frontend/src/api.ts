const API_ENDPOINT = import.meta.env.VITE_API_ENDPOINT as string;

export interface ContentJob {
  job_id: string;
  conversation_id: string;
  brief: string;
  status: "queued" | "pending_human_review" | "completed" | "escalated" | "stopped" | string;
  /** Live "which agent is working right now" text written by the
   * Orchestrator/Writer as they work — e.g. "Writer agent is drafting the
   * first version…". Only meaningful while the job is in flight. */
  current_step?: string;
  initial_draft?: string;
  ai_reviewed_draft?: string;
  ai_approved?: boolean;
  draft?: string;
  final_draft?: string;
  ai_review_rounds?: number;
  human_review_rounds?: number;
  created_at: string;
  updated_at: string;
}

export interface Conversation {
  conversation_id: string;
  user_id: string;
  created_at: string;
  last_message_at: string;
}

export type ArtifactStage = "initial" | "ai_reviewed" | "current" | "final";

async function request<T>(path: string, token: string, options: RequestInit = {}): Promise<T> {
  const res = await fetch(`${API_ENDPOINT}${path}`, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
      ...options.headers,
    },
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`${res.status} ${res.statusText}${body ? `: ${body}` : ""}`);
  }
  return (await res.json()) as T;
}

export const api = {
  sendChat: (token: string, message: string, conversationId?: string) =>
    request<{ conversation_id: string; job_id: string; status: string }>("/chat", token, {
      method: "POST",
      body: JSON.stringify({ message, conversation_id: conversationId }),
    }),

  listConversations: (token: string) =>
    request<{ conversations: Conversation[] }>("/conversations", token),

  getJob: (token: string, jobId: string) => request<ContentJob>(`/jobs/${jobId}`, token),

  listJobs: (token: string, status = "pending_human_review") =>
    request<{ jobs: ContentJob[] }>(`/jobs?status=${encodeURIComponent(status)}`, token),

  reviewJob: (token: string, jobId: string, approved: boolean, feedback?: string) =>
    request<{ job_id: string; approved: boolean; human_review_rounds: number }>(
      `/jobs/${jobId}/review`,
      token,
      { method: "POST", body: JSON.stringify({ approved, feedback: feedback ?? "" }) }
    ),

  stopJob: (token: string, jobId: string) =>
    request<{ job_id: string; status: string }>(`/jobs/${jobId}/stop`, token, { method: "POST" }),

  /** Returns a presigned S3 URL (valid 5 min) to download that stage's draft. */
  getArtifactUrl: (token: string, jobId: string, stage: ArtifactStage) =>
    request<{ download_url: string; expires_in: number }>(`/jobs/${jobId}/artifacts/${stage}`, token),
};

/** Jobs still moving through the pipeline — worth polling, and worth allowing Stop on. */
export function isInFlight(status: string): boolean {
  return status === "queued" || status === "pending_human_review";
}

export function canStop(status: string): boolean {
  return isInFlight(status);
}
