# Contributing

Start with the README and run the check for your component. Use synthetic fixtures;
never commit provider keys, conversations, account exports or release certificates.
Changes to original AIM source are contributed under its MIT license. Preserve
third-party notices and identify any new dependency or copied material explicitly.

Keep domain rules in AIMCore, platform behavior in the app's platform layer, and
network details in adapters. Avoid shared mutable global state and account-dependent
singletons. A local storage ID never authorizes a cloud RPC.

Make focused changes. For deletion, check build targets/resources, dynamic tool
registration, scripts, migrations, deployed endpoints and old-client contracts.
An unused-symbol warning alone is not proof that something is removable.

Tests should prove behavior: profile isolation, confirmation boundaries, persistence
or authorization. Do not update expected values merely to hide a regression.
Document whether evidence is a unit test, simulator observation or physical-device
qualification. Never label a mock or a compilation as an end-to-end result.

Do not run paid provider tests without an explicit provider and budget. Do not use
an installed user's app/data for qualification. Follow AGENTS.md where present.
