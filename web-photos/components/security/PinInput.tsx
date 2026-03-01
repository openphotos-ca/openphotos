"use client";

import React, { useEffect, useRef } from "react";

export function PinInput({
  value,
  onChange,
  length = 8,
  autoFocus,
  disabled,
  ariaLabel,
}: {
  value: string;
  onChange: (next: string) => void;
  length?: number;
  autoFocus?: boolean;
  disabled?: boolean;
  ariaLabel?: string;
}) {
  const inputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    if (autoFocus) setTimeout(() => inputRef.current?.focus(), 10);
  }, [autoFocus]);

  const setChars = (raw: string) => {
    if (disabled) return;
    const s = (raw || "").slice(0, length);
    onChange(s);
  };

  return (
    <div className="relative">
      <input
        ref={inputRef}
        type="password"
        maxLength={length}
        value={value}
        onChange={(e) => setChars(e.target.value)}
        onPaste={(e) => {
          const t = e.clipboardData.getData("text");
          setChars(t);
          e.preventDefault();
        }}
        aria-label={ariaLabel || "PIN"}
        className="absolute opacity-0 pointer-events-none"
        disabled={disabled}
      />
      <div
        className={`flex gap-2 select-none ${disabled ? "opacity-60" : ""}`}
        onClick={() => inputRef.current?.focus()}
        aria-hidden
      >
        {Array.from({ length }).map((_, i) => {
          const filled = i < value.length;
          return (
            <div
              key={i}
              className={`w-12 h-14 rounded-xl border grid place-items-center text-2xl ${
                filled ? "border-primary/50 bg-primary/5" : "border-border bg-card"
              }`}
            >
              {filled ? (
                <span className="w-2 h-2 rounded-full bg-foreground inline-block" />
              ) : null}
            </div>
          );
        })}
      </div>
    </div>
  );
}
