import { useParams, Link } from "react-router-dom";
import { CONTENT_TYPES } from "../contentTypes";

export default function ComingSoon() {
  const { type } = useParams();
  const def = CONTENT_TYPES.find((t) => t.id === type);

  return (
    <div className="page">
      <h1>{def?.label ?? "This content type"}</h1>
      <p className="page-subtitle">
        Not built yet — <Link to="/">go back and pick Web Article</Link> for now.
      </p>
    </div>
  );
}
