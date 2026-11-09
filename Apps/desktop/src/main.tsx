import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import "./styles/tokens.css";
import "./styles/layout.css";
import "./styles/components.css";
import "./styles/pages.css";
import "./styles/settings.css";
import "./styles/modals.css";
import "./styles/graphics.css";

const container = document.getElementById("root");
if (!container) throw new Error("Root container #root is missing in index.html");

createRoot(container).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
