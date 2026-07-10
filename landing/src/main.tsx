import { StrictMode } from "react";
import { hydrateRoot } from "react-dom/client";
import "./index.css";
import { LandingPage } from "./LandingPage.tsx";

hydrateRoot(
  document.getElementById("root")!,
  <StrictMode>
    <LandingPage />
  </StrictMode>
);