import { NavLink, Outlet } from "react-router-dom";
import { api } from "../api/client";
import { CloudLogo, ItemsIcon, OverviewIcon, UploadIcon } from "./Icons";

const navItems = [
  { to: "/overview", label: "Overview", icon: OverviewIcon },
  { to: "/items", label: "Items", icon: ItemsIcon },
  { to: "/uploads", label: "Uploads", icon: UploadIcon },
];

export function Layout() {
  return (
    <div className="app-shell">
      <a className="skip-link" href="#main-content">
        Skip to main content
      </a>

      <header className="topbar">
        <NavLink className="brand" to="/overview" aria-label="Zero Cloud Stack home">
          <span className="brand__mark">
            <CloudLogo />
          </span>
          <span>
            <strong>Zero Cloud</strong>
            <small>STACK CONSOLE</small>
          </span>
        </NavLink>

        <div className="environment-pill" title={`API target: ${api.originLabel}`}>
          <span className="environment-pill__dot" aria-hidden="true" />
          <span className="environment-pill__label">{api.originLabel}</span>
        </div>
      </header>

      <aside className="sidebar">
        <nav aria-label="Primary navigation">
          <p className="nav-label">Workspace</p>
          {navItems.map(({ to, label, icon: Icon }) => (
            <NavLink
              className={({ isActive }) => `nav-link${isActive ? " nav-link--active" : ""}`}
              key={to}
              to={to}
            >
              <Icon />
              <span>{label}</span>
            </NavLink>
          ))}
        </nav>

        <div className="sidebar__footer">
          <span className="zero-badge">$0</span>
          <div>
            <strong>Cost bounded</strong>
            <span>Scale-to-zero design</span>
          </div>
        </div>
      </aside>

      <main className="main-content" id="main-content" tabIndex={-1}>
        <Outlet />
      </main>

      <nav className="mobile-nav" aria-label="Mobile navigation">
        {navItems.map(({ to, label, icon: Icon }) => (
          <NavLink
            className={({ isActive }) => `mobile-nav__link${isActive ? " mobile-nav__link--active" : ""}`}
            key={to}
            to={to}
          >
            <Icon />
            <span>{label}</span>
          </NavLink>
        ))}
      </nav>
    </div>
  );
}
