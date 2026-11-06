export async function api<T>(
  path: string,
  body?: unknown,
  csrf?: string,
): Promise<T> {
  const response = await fetch("/api" + path, {
    method: body === undefined ? "GET" : "POST",
    credentials: "same-origin",
    headers: {
      "Content-Type": "application/json",
      ...(csrf ? { "X-CSRF-Token": csrf } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) {
    const value = await response.json();
    throw new Error(
      typeof value.detail === "string"
        ? value.detail
        : "Request could not be completed",
    );
  }
  return response.json();
}
