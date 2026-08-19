import { useNavigate } from "react-router-dom";
import { CONTENT_TYPES } from "../contentTypes";

export default function ContentTypeSelect() {
  const navigate = useNavigate();

  return (
    <div className="page">
      <h1>New content request</h1>
      <p className="page-subtitle">What are you creating?</p>

      <div className="card-grid">
        {CONTENT_TYPES.map((type) => (
          <button
            key={type.id}
            className={`content-type-card${type.available ? "" : " disabled"}`}
            onClick={() => navigate(`/new/${type.id}`)}
          >
            <h3>{type.label}</h3>
            <p>{type.description}</p>
            {!type.available && <span className="badge">Coming soon</span>}
          </button>
        ))}
      </div>
    </div>
  );
}
