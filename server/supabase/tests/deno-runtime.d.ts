// Minimal host surface for offline TypeScript checking with the existing compiler.
// Production supplies the Deno runtime; these declarations are never deployed/imported.
declare const Deno: {
  env: { get(name: string): string | undefined };
  serve(handler: (request: Request) => Promise<Response>): unknown;
};
