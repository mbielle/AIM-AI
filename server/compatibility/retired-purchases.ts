// For explicitly retiring existing checkout/portal/purchase routes after owner review.
// This does not grant access, authenticate a payment or acknowledge provider events.
export function retiredPurchases(request: Request): Response {
  const origin = request.headers.get("Origin");
  return Response.json(
    {
      error: "update_required",
      message:
        "AIM is now free. Update the application; no purchase is required.",
    },
    {
      status: 410,
      headers: {
        "Cache-Control": "no-store",
        ...(origin ? { Vary: "Origin" } : {}),
      },
    },
  );
}
