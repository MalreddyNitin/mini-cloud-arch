import { Navigate, Route, Routes } from "react-router-dom";
import { Layout } from "./components/Layout";
import { ItemsPage } from "./pages/ItemsPage";
import { NotFoundPage } from "./pages/NotFoundPage";
import { OverviewPage } from "./pages/OverviewPage";
import { UploadsPage } from "./pages/UploadsPage";

export function App() {
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<Navigate to="/overview" replace />} />
        <Route path="overview" element={<OverviewPage />} />
        <Route path="items" element={<ItemsPage />} />
        <Route path="uploads" element={<UploadsPage />} />
        <Route path="*" element={<NotFoundPage />} />
      </Route>
    </Routes>
  );
}
