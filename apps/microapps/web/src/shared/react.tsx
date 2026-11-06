import React from "react";
import { buttonClass } from "./components.js";
import "./components.css";

export function Toolbar({
  heading,
  children,
}: {
  heading: string;
  children?: React.ReactNode;
}) {
  return React.createElement("app-toolbar", { heading }, children);
}
export function Status({ state, label }: { state: string; label?: string }) {
  return React.createElement("app-status", { state, label });
}
export function Icon({ name }: { name: string }) {
  return React.createElement("app-icon", { name });
}
export function Empty({ children }: { children: React.ReactNode }) {
  return React.createElement("app-empty", {}, children);
}
export function Button({
  variant = "default",
  className = "",
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: Parameters<typeof buttonClass>[0];
}) {
  return (
    <button
      type="button"
      className={`${buttonClass(variant)} ${className}`}
      {...props}
    />
  );
}
