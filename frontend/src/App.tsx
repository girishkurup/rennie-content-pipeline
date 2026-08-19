import { Routes, Route, Navigate } from "react-router-dom";
import { useAuth } from "react-oidc-context";
import Layout from "./components/Layout";
import ContentTypeSelect from "./pages/ContentTypeSelect";
import WebArticleForm from "./pages/WebArticleForm";
import ComingSoon from "./pages/ComingSoon";
import ReviewerDashboard from "./pages/ReviewerDashboard";
import "./App.css";

function App() {
  const auth = useAuth();

  if (auth.isLoading) {
    return (
      <div className="center-screen">
        <p>Loading…</p>
      </div>
    );
  }

  if (auth.error) {
    return (
      <div className="center-screen">
        <div className="login-card">
          <h1>Sign-in error</h1>
          <p>{auth.error.message}</p>
          <button className="primary-button" onClick={() => auth.signinRedirect()}>
            Try again
          </button>
        </div>
      </div>
    );
  }

  if (!auth.isAuthenticated) {
    return (
      <div className="center-screen">
        <div className="login-card">
          <h1>Rennie Content Pipeline</h1>
          <p>Sign in to request or review content.</p>
          <button className="primary-button" onClick={() => auth.signinRedirect()}>
            Sign in
          </button>
        </div>
      </div>
    );
  }

  return (
    <Layout>
      <Routes>
        <Route path="/" element={<ContentTypeSelect />} />
        <Route path="/new/web-article" element={<WebArticleForm />} />
        <Route path="/new/:type" element={<ComingSoon />} />
        <Route path="/reviews" element={<ReviewerDashboard />} />
        <Route path="/callback" element={<Navigate to="/" replace />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </Layout>
  );
}

export default App;
