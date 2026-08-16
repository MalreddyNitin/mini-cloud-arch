import { Link } from "react-router-dom";
import { CloudLogo } from "../components/Icons";

export function NotFoundPage() {
  return (
    <div className="not-found">
      <span><CloudLogo /></span>
      <p className="eyebrow">404 · Route not found</p>
      <h1>This path drifted out of the stack.</h1>
      <p>The application is running, but there is no screen at this address.</p>
      <Link className="button button--primary" to="/overview">Return to overview</Link>
    </div>
  );
}
