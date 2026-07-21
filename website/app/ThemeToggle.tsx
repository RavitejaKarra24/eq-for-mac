"use client";

import { useEffect, useState } from "react";

type Theme = "light" | "dark";

export function ThemeToggle() {
  const [theme, setTheme] = useState<Theme>("light");

  useEffect(() => {
    const root = document.documentElement;
    const media = window.matchMedia("(prefers-color-scheme: dark)");

    function syncWithSystem() {
      if (!localStorage.getItem("eq-theme")) {
        const systemTheme: Theme = media.matches ? "dark" : "light";
        root.dataset.theme = systemTheme;
        setTheme(systemTheme);
      }
    }

    const initialTheme: Theme = root.dataset.theme === "dark" ? "dark" : "light";
    const frame = window.requestAnimationFrame(() => setTheme(initialTheme));
    media.addEventListener("change", syncWithSystem);
    return () => {
      window.cancelAnimationFrame(frame);
      media.removeEventListener("change", syncWithSystem);
    };
  }, []);

  function toggleTheme() {
    const nextTheme: Theme = theme === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = nextTheme;
    localStorage.setItem("eq-theme", nextTheme);
    setTheme(nextTheme);
  }

  const nextLabel = theme === "dark" ? "Light" : "Dark";

  return (
    <button
      className="theme-toggle"
      type="button"
      onClick={toggleTheme}
      aria-label={`Switch to ${nextLabel.toLowerCase()} mode`}
      title={`Switch to ${nextLabel.toLowerCase()} mode`}
    >
      <span aria-hidden="true">{theme === "dark" ? "☀" : "◐"}</span>
      {nextLabel}
    </button>
  );
}
