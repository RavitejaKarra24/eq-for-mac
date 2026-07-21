"use client";

import { useEffect, useRef, useState } from "react";

export function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    return () => {
      if (timer.current) clearTimeout(timer.current);
    };
  }, []);

  async function copy() {
    await navigator.clipboard.writeText(text);
    setCopied(true);
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => setCopied(false), 1800);
  }

  return (
    <button
      className="copy-button"
      type="button"
      onClick={copy}
      aria-label={copied ? "Command copied" : "Copy command"}
    >
      <span aria-hidden="true">{copied ? "✓" : "□"}</span>
      {copied ? "Copied" : "Copy"}
    </button>
  );
}
