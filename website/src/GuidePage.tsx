import { sourceUrl } from "./components/landing/releaseLinks";
import { InformationPage } from "./InformationPage";
export function GuidePage() {
  return (
    <InformationPage title="Set up AIM">
      <section>
        <h2>Mac</h2>
        <p>
          Build from the repository using the macOS instructions, or wait for a
          qualified public release. No public binary is enabled by default on
          this site. Check the build’s system requirements before installing.
        </p>
        {sourceUrl && (
          <p>
            <a href={sourceUrl} target="_blank" rel="noopener noreferrer">
              Open the source repository and build instructions
            </a>
          </p>
        )}
        <p>
          Connect your own supported provider API key and pay that provider
          directly. For supported local models, install and configure a
          compatible local runtime on your Mac. Model availability and
          performance depend on the runtime and your hardware.
        </p>
      </section>
      <section>
        <h2>iPhone and Remote</h2>
        <p>
          Remote requires an account, a configured backend, device pairing and
          an awake Mac running AIM. The official backend may enforce capacity
          and cost limits; self-hosting requires infrastructure. This site does
          not publish internal iPhone invitations or promise on-device local
          inference on iPhone.
        </p>
      </section>
      <section>
        <h2>Permissions and costs</h2>
        <p>
          Choose a folder and review permissions before asking an agent to act.
          Agent activity can make multiple API requests; usage is billed by your
          provider. AIM has no subscription or paid feature gates.
        </p>
      </section>
    </InformationPage>
  );
}
