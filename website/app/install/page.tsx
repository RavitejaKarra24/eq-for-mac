import type { Metadata } from "next";
import Link from "next/link";
import { CopyButton } from "../CopyButton";
import { ThemeToggle } from "../ThemeToggle";

const DOWNLOAD_URL =
  "https://github.com/RavitejaKarra24/eq-for-mac/releases/latest/download/EQ-for-Mac.dmg";
const CHECKSUM_URL = `${DOWNLOAD_URL}.sha256`;
const SOURCE_URL = "https://github.com/RavitejaKarra24/eq-for-mac";
const APPLE_GUIDE_URL = "https://support.apple.com/en-us/102445";

const TAP_COMMAND =
  "brew tap ravitejakarra24/eq-for-mac https://github.com/RavitejaKarra24/eq-for-mac";
const INSTALL_COMMAND = "brew install --cask eq-for-mac";
const UPGRADE_COMMAND = "brew upgrade --cask eq-for-mac";
const VERIFY_COMMAND =
  "cd ~/Downloads && shasum -a 256 -c EQ-for-Mac.dmg.sha256";
const FALLBACK_COMMAND =
  'xattr -dr com.apple.quarantine "/Applications/EQ for Mac.app"';
const OPEN_COMMAND = 'open "/Applications/EQ for Mac.app"';
const UNINSTALL_COMMAND = "brew uninstall --cask eq-for-mac";

export const metadata: Metadata = {
  title: "Install EQ for Mac — Gatekeeper guide",
  description:
    "Download EQ for Mac and follow the illustrated macOS Open Anyway and audio-permission steps.",
};

function Command({ label, command }: { label: string; command: string }) {
  return (
    <div className="command-block">
      <div className="command-label">
        <span>{label}</span>
        <CopyButton text={command} />
      </div>
      <code>{command}</code>
    </div>
  );
}

export default function InstallGuide() {
  return (
    <main id="top" className="install-guide-page">
      <header className="site-header">
        <Link className="brand" href="/" aria-label="EQ for Mac home">
          <img src="/app-icon.png" alt="" />
          <span>EQ for Mac</span>
        </Link>
        <nav aria-label="Installation navigation">
          <a href="#direct">Direct download</a>
          <a href="#homebrew">Homebrew</a>
          <a href="#troubleshooting">Troubleshooting</a>
          <a href={SOURCE_URL}>Source</a>
        </nav>
        <div className="header-controls">
          <ThemeToggle />
          <a className="nav-download" href={DOWNLOAD_URL}>Download</a>
        </div>
      </header>

      <section className="guide-hero">
        <p className="overline">Zero-fee macOS installation</p>
        <h1>Install it safely, warning and all.</h1>
        <p>
          EQ for Mac is free, open source, and ad-hoc signed. It is not
          notarized because this project does not pay Apple&apos;s annual developer
          fee. macOS will therefore ask you to approve the app once.
        </p>
        <div className="hero-actions">
          <a className="button button-dark" href={DOWNLOAD_URL}>Download DMG</a>
          <a className="button button-light" href="#direct">Show me the steps</a>
        </div>
        <div className="safety-callout">
          <strong>Know what is safe to approve.</strong>
          <span>
            Continue only for a “developer cannot be verified” or “Apple cannot
            check it” warning after downloading from this project. Never bypass
            an alert saying the app will damage your Mac or contains malware.
          </span>
        </div>
      </section>

      <section className="guide-section" id="direct">
        <div className="guide-section-heading">
          <p className="overline">Recommended</p>
          <h2>Direct download</h2>
          <p>These screenshots are from macOS 26. Wording may vary slightly on macOS 14 and 15.</p>
        </div>

        <div className="guide-steps">
          <article className="guide-step">
            <div className="step-copy">
              <span className="step-number">01</span>
              <h3>Download and move the app</h3>
              <p>
                Open the DMG and drag <strong>EQ for Mac</strong> into the
                Applications shortcut. Then open it from Applications.
              </p>
            </div>
            <div className="step-shot step-shot-compact">
              <img src="/install/gatekeeper-warning.png" alt="macOS warning that EQ for Mac cannot be opened because the developer cannot be verified" />
              <p>Expected first-launch warning. Choose <strong>Done</strong>.</p>
            </div>
          </article>

          <article className="guide-step">
            <div className="step-copy">
              <span className="step-number">02</span>
              <h3>Open Privacy &amp; Security</h3>
              <p>
                Open <strong>System Settings → Privacy &amp; Security</strong> and
                scroll to Security. Find the message about EQ for Mac and click
                <strong> Open Anyway</strong>. Apple keeps this button available
                for about an hour after the blocked launch.
              </p>
            </div>
            <div className="step-shot">
              <img src="/install/privacy-security-open-anyway.png" alt="macOS Privacy and Security settings with the Open Anyway button for EQ for Mac highlighted" />
              <p>Approval applies only to EQ for Mac—not every downloaded app.</p>
            </div>
          </article>

          <article className="guide-step">
            <div className="step-copy">
              <span className="step-number">03</span>
              <h3>Confirm the exception</h3>
              <p>
                Authenticate with your password or Touch ID when asked, then
                click <strong>Open Anyway</strong> in the final confirmation.
                Future launches work normally unless macOS requests approval
                again after an update.
              </p>
            </div>
            <div className="step-shot step-shot-compact">
              <img src="/install/open-anyway-confirmation.png" alt="Final macOS confirmation dialog with an Open Anyway button for EQ for Mac" />
              <p>The app now appears in the menu bar, not the Dock.</p>
            </div>
          </article>

          <article className="guide-step">
            <div className="step-copy">
              <span className="step-number">04</span>
              <h3>Allow system audio</h3>
              <p>
                In <strong>Privacy &amp; Security → Screen &amp; System Audio
                Recording</strong>, enable EQ for Mac. This permission lets the
                equalizer process sound locally; it does not save or upload audio.
              </p>
            </div>
            <div className="step-shot">
              <img src="/install/system-audio-permission.png" alt="macOS Screen and System Audio Recording settings with EQ for Mac enabled" />
              <p>Toggle the EQ off and on again after granting permission.</p>
            </div>
          </article>
        </div>

        <p className="official-note">
          This is Apple&apos;s supported per-app exception flow. Read the
          <a href={APPLE_GUIDE_URL}> official Apple security guidance</a> before
          overriding a warning for any downloaded app.
        </p>
      </section>

      <section className="guide-section guide-section-toned" id="verify">
        <div className="guide-section-heading">
          <p className="overline">Optional integrity check</p>
          <h2>Verify the download</h2>
          <p>Download the checksum beside the DMG, then verify that the file is exactly the one published by the release workflow.</p>
        </div>
        <div className="verify-actions">
          <a className="button button-light" href={CHECKSUM_URL}>Download checksum</a>
          <Command label="Verify SHA-256" command={VERIFY_COMMAND} />
        </div>
      </section>

      <section className="guide-section" id="homebrew">
        <div className="guide-section-heading">
          <p className="overline">Terminal installation</p>
          <h2>Homebrew</h2>
          <p>
            The custom Cask installs the same checksummed DMG. Homebrew does not
            remove Gatekeeper protection, so complete the same Open Anyway step
            before the first launch.
          </p>
        </div>
        <div className="guide-command-grid">
          <Command label="1 · Add the project tap" command={TAP_COMMAND} />
          <Command label="2 · Install the app" command={INSTALL_COMMAND} />
          <Command label="Later · Upgrade" command={UPGRADE_COMMAND} />
          <Command label="Uninstall" command={UNINSTALL_COMMAND} />
        </div>
      </section>

      <section className="guide-section guide-section-warning" id="troubleshooting">
        <div className="guide-section-heading">
          <p className="overline">Advanced fallback</p>
          <h2>If Open Anyway does not appear</h2>
          <p>
            Try launching the app once more and return to Privacy &amp; Security.
            If the per-app button still does not appear, verify the checksum and
            remove quarantine only from this exact app bundle.
          </p>
        </div>
        <div className="fallback-box">
          <Command label="1 · Remove this app's quarantine flag" command={FALLBACK_COMMAND} />
          <Command label="2 · Open the app" command={OPEN_COMMAND} />
          <p>
            Do not use commands that disable Gatekeeper globally. A work- or
            school-managed Mac may prohibit exceptions; contact its administrator.
          </p>
        </div>
      </section>

      <footer>
        <Link className="brand footer-brand" href="/">
          <img src="/app-icon.png" alt="" />
          <span>EQ for Mac</span>
        </Link>
        <div className="footer-links">
          <a href={DOWNLOAD_URL}>Download</a>
          <a href={SOURCE_URL}>Source</a>
          <a href={`${SOURCE_URL}/issues`}>Support</a>
        </div>
        <p>For macOS 14.2 and later.</p>
      </footer>
    </main>
  );
}
