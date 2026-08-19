import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { AuthProvider } from "react-oidc-context";
import "./index.css";
import App from "./App.tsx";

// Cognito's OIDC discovery document (at
// https://cognito-idp.<region>.amazonaws.com/<pool id>/.well-known/openid-configuration)
// correctly advertises the Hosted UI domain's authorize/token endpoints, so
// react-oidc-context only needs the issuer URL here, not the Hosted UI
// domain directly (that's used separately for logout — see Layout.tsx).
const cognitoAuthConfig = {
  authority: `https://cognito-idp.${import.meta.env.VITE_AWS_REGION}.amazonaws.com/${
    import.meta.env.VITE_COGNITO_USER_POOL_ID
  }`,
  client_id: import.meta.env.VITE_COGNITO_CLIENT_ID as string,
  redirect_uri: `${window.location.origin}/callback`,
  response_type: "code",
  scope: "openid email profile",
  onSigninCallback: () => {
    // Strip the ?code=...&state=... query params Cognito appended after
    // redirecting back, so a page refresh doesn't try to replay them.
    window.history.replaceState({}, document.title, window.location.pathname);
  },
};

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <AuthProvider {...cognitoAuthConfig}>
      <BrowserRouter>
        <App />
      </BrowserRouter>
    </AuthProvider>
  </StrictMode>
);
