import type { ReactNode } from "react";
import { CloseIcon, InfoIcon } from "./Icons";

interface AlertProps {
  children: ReactNode;
  tone?: "danger" | "success" | "info";
  onDismiss?: () => void;
}

export function Alert({ children, tone = "danger", onDismiss }: AlertProps) {
  return (
    <div className={`alert alert--${tone}`} role={tone === "danger" ? "alert" : "status"}>
      <InfoIcon className="alert__icon" />
      <div className="alert__content">{children}</div>
      {onDismiss ? (
        <button className="icon-button alert__dismiss" type="button" onClick={onDismiss} aria-label="Dismiss message">
          <CloseIcon />
        </button>
      ) : null}
    </div>
  );
}
