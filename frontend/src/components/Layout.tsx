import type { ReactNode } from "react";
import { Link } from "react-router-dom";
import { useAuth } from "react-oidc-context";
import { isReviewer } from "../lib/groups";

export default function Layout({ children }: { children: ReactNode }) {
  const auth = useAuth();
  const showReviewsLink = isReviewer(auth.user);

  const signOut = () => {
    const domain = import.meta.env.VITE_COGNITO_HOSTED_UI_DOMAIN;
    const clientId = import.meta.env.VITE_COGNITO_CLIENT_ID;
    const logoutUri = `${window.location.origin}/`;
    auth.removeUser();
    window.location.href = `https://${domain}/logout?client_id=${clientId}&logout_uri=${encodeURIComponent(
      logoutUri
    )}`;
  };

  return (
    <div className="app-shell">
      <header className="app-header">
        <Link to="/" className="brand">
          Rennie Content Pipeline
        </Link>
        <nav>
          <Link to="/">New request</Link>
          {showReviewsLink && <Link to="/reviews">Reviews</Link>}
        </nav>
        <div className="user-info">
          <span>{auth.user?.profile?.email as string}</span>
          <button className="link-button" onClick={signOut}>
            Sign out
          </button>
        </div>
      </header>
      <main className="app-main">{children}</main>
    </div>
  );
}
