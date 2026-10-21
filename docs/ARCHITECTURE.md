# Architecture

The Mac UI and permanent helper share an agent runtime, explicit ownership and
persistent checkpoints. Tool execution still requires normal permissions and
approvals. iOS has native chat storage plus a Remote client; it is not the Mac's
system-tool executor. AIMCore is a single shared Swift package.

AppIdentity distinguishes a persistent LocalProfile from an AuthenticatedUser.
The storage ID scopes histories, preferences and credentials. authenticatedUser is
nil locally, so cloud services must be absent or unavailable, not provided with a
fabricated user. Account changes must cancel/reconcile in-flight work and swap
storage context before the composer can send again.

Cloud content, session liveness, encryption and Remote use service protocols with
Supabase adapters. Supabase remains the only implemented server stack. It may be
managed or self-hosted on a chosen infrastructure provider. New server software
requires a new adapter and tested security behavior; changing a URL alone is not
compatibility.

Remote uses the existing authenticated encrypted relay. Direct LAN/Internet
transport and relay fallback optimization are deferred. Local execution has no
financial admission service. Existing deployments have a separate compatibility
migration for older cache-shaped availability responses; new clients do not use it.

Provider usage/cost budgets are operational user protections. They are unrelated to
AIM feature access and must not be removed with Stripe/StoreKit code.
