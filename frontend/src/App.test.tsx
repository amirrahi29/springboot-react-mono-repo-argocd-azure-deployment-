import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import App from "./App.js";

describe("App", () => {
  it("renders welcome message", () => {
    render(<App />);
    expect(screen.getByText(/welcome to frontend app/i)).toBeInTheDocument();
  });
});
