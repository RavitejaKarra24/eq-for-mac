import { CopyButton } from "./CopyButton";
import { ThemeToggle } from "./ThemeToggle";

const DOWNLOAD_URL =
  "https://github.com/RavitejaKarra24/eq-for-mac/releases/latest/download/EQ-for-Mac.dmg";
const RELEASES_URL =
  "https://github.com/RavitejaKarra24/eq-for-mac/releases/latest";
const SOURCE_URL = "https://github.com/RavitejaKarra24/eq-for-mac";

const TAP_COMMAND =
  "brew tap ravitejakarra24/eq-for-mac https://github.com/RavitejaKarra24/eq-for-mac";
const INSTALL_COMMAND = "brew install --cask eq-for-mac";
const UPGRADE_COMMAND = "brew upgrade --cask eq-for-mac";

export default function Home() {
  return (
    <main id="top">
      <header className="site-header">
        <a className="brand" href="#top" aria-label="EQ for Mac home">
          <img src="/app-icon.png" alt="" />
          <span>EQ for Mac</span>
        </a>
        <nav aria-label="Main navigation">
          <a href="#features">Features</a>
          <a href="#headphones">Headphones</a>
          <a href="#install">Install</a>
          <a href="/install">Install guide</a>
          <a href={SOURCE_URL}>Source</a>
        </nav>
        <div className="header-controls">
          <ThemeToggle />
          <a className="nav-download" href={DOWNLOAD_URL}>
            Download
          </a>
        </div>
      </header>

      <section className="hero">
        <div className="hero-copy">
          <p className="overline">System-wide equalizer for macOS</p>
          <h1>Make your Mac sound like yours.</h1>
          <p className="hero-lede">
            A native menu-bar equalizer for every app. Tune with 10 or 15
            bands, use headphone-specific curves, or import your own—without a
            virtual audio driver.
          </p>
          <div className="hero-actions">
            <a className="button button-dark" href={DOWNLOAD_URL}>
              Download for macOS
            </a>
            <a className="button button-light" href="#install">
              Homebrew instructions
            </a>
          </div>
          <p className="compatibility">
            Requires macOS 14.2 or later · Apple Silicon and Intel
          </p>
          <p className="notarization-note">
            Free and open source. Not Apple-notarized, so first launch requires
            one approval in Privacy &amp; Security. <a href="/install">See the illustrated guide</a>.
          </p>
        </div>

        <div className="hero-visual">
          <div className="browser-frame">
            <div className="frame-bar">
              <span />
              <span />
              <span />
              <p>EQ for Mac</p>
            </div>
            <img
              src="/menu-bar-overview.jpg"
              alt="EQ for Mac open from the menu bar on a macOS desktop"
            />
          </div>
        </div>

        <div className="proof-row" aria-label="Product highlights">
          <div><strong>System-wide</strong><span>Browser, music, games, and calls</span></div>
          <div><strong>Driver-free</strong><span>Built on Core Audio Process Taps</span></div>
          <div><strong>Private</strong><span>Audio and presets stay on your Mac</span></div>
          <div><strong>Source available</strong><span>Inspect and build it yourself</span></div>
        </div>
      </section>

      <section className="feature-section" id="features">
        <div className="section-intro">
          <p className="overline">Simple when you want it. Precise when you need it.</p>
          <h2>Useful controls, not audio-engineering homework.</h2>
          <p>
            Open the menu bar, make a change, and keep listening. Everything
            important stays close; everything technical stays out of the way.
          </p>
        </div>

        <div className="feature-list">
          <article>
            <span className="feature-index">01</span>
            <div>
              <h3>Live 10- or 15-band EQ</h3>
              <p>Adjust the full frequency range and hear changes immediately across every app.</p>
            </div>
          </article>
          <article>
            <span className="feature-index">02</span>
            <div>
              <h3>Fast presets</h3>
              <p>Start with Flat, Bass Boost, Treble Boost, V-Shape, Vocal, or Podcast.</p>
            </div>
          </article>
          <article>
            <span className="feature-index">03</span>
            <div>
              <h3>Import your own filters</h3>
              <p>Use Equalizer APO, AutoEQ, and PEQdB parametric text files without conversion.</p>
            </div>
          </article>
          <article>
            <span className="feature-index">04</span>
            <div>
              <h3>One-switch bypass</h3>
              <p>Compare the processed and original sound instantly without quitting the app.</p>
            </div>
          </article>
        </div>
      </section>

      <section className="product-detail" id="headphones">
        <div className="product-image">
          <img
            src="/eq-panel-headphone-search.png"
            alt="The 15-band EQ and headphone search in EQ for Mac"
          />
        </div>
        <div className="product-copy">
          <p className="overline">Headphone profiles</p>
          <h2>Find your headphones. Start from a better curve.</h2>
          <p className="detail-lede">
            Search thousands of bundled measurements and apply a tuned profile
            in one click. The entire catalog works offline.
          </p>

          <div className="stats">
            <div><strong>6,808</strong><span>Headphone profiles</span></div>
            <div><strong>17</strong><span>Reference targets</span></div>
            <div><strong>0</strong><span>Accounts required</span></div>
          </div>

          <ul className="check-list">
            <li><span>✓</span>Instant offline search</li>
            <li><span>✓</span>Preamp automatically accounted for</li>
            <li><span>✓</span>Imported curves appear beside the catalog</li>
          </ul>
        </div>
      </section>

      <section className="technical-section">
        <div className="technical-heading">
          <p className="overline">Native by design</p>
          <h2>No virtual audio driver. No strange routing setup.</h2>
        </div>
        <div className="technical-copy">
          <p>
            EQ for Mac is written in Swift and uses Apple&apos;s Core Audio
            Process Taps. It processes system audio locally and returns it to
            your current output device.
          </p>
          <div className="signal-flow" aria-label="Audio processing flow">
            <span>Any app</span><i>→</i><span>Core Audio Tap</span><i>→</i>
            <span>Equalizer</span><i>→</i><span>Your output</span>
          </div>
        </div>
      </section>

      <section className="install-section" id="install">
        <div className="section-intro install-intro">
          <p className="overline">Install EQ for Mac</p>
          <h2>Choose the way you already install Mac apps.</h2>
        </div>

        <div className="install-grid">
          <article className="download-card">
            <div className="card-heading">
              <img src="/app-icon.png" alt="" />
              <div>
                <p>Direct download</p>
                <h3>Install from a DMG</h3>
              </div>
            </div>
            <ol>
              <li><span>1</span>Download and open the disk image.</li>
              <li><span>2</span>Drag EQ for Mac into Applications.</li>
              <li><span>3</span>Approve the first launch in Privacy &amp; Security.</li>
              <li><span>4</span>Allow System Audio Recording.</li>
            </ol>
            <a className="button button-dark button-full" href={DOWNLOAD_URL}>
              Download EQ for Mac
            </a>
            <a className="text-link" href={RELEASES_URL}>Release notes</a>
            <a className="text-link" href="/install">Illustrated installation guide</a>
          </article>

          <article className="brew-card">
            <div className="brew-heading">
              <div>
                <p>Homebrew</p>
                <h3>Install from Terminal</h3>
              </div>
              <span className="brew-badge">brew</span>
            </div>
            <p className="brew-description">
              Add the project tap once, then install the app. Each command has
              its own copy button. The same first-launch approval is required.
            </p>

            <div className="command-list">
              <div className="command-block">
                <div className="command-label"><span>1 · Add tap</span><CopyButton text={TAP_COMMAND} /></div>
                <code>{TAP_COMMAND}</code>
              </div>
              <div className="command-block">
                <div className="command-label"><span>2 · Install</span><CopyButton text={INSTALL_COMMAND} /></div>
                <code>{INSTALL_COMMAND}</code>
              </div>
              <div className="command-block command-block-muted">
                <div className="command-label"><span>Later · Upgrade</span><CopyButton text={UPGRADE_COMMAND} /></div>
                <code>{UPGRADE_COMMAND}</code>
              </div>
            </div>
          </article>
        </div>
      </section>

      <section className="faq-section">
        <div className="faq-heading">
          <p className="overline">Questions</p>
          <h2>Before you install.</h2>
        </div>
        <div className="faq-list">
          <details open>
            <summary>Why does it need System Audio Recording permission?</summary>
            <p>
              macOS places system-audio capture under that privacy permission.
              EQ for Mac uses it only to process audio locally; it does not save
              or upload what you hear.
            </p>
          </details>
          <details>
            <summary>Does it work with Bluetooth headphones?</summary>
            <p>Yes. It follows your current wired, USB, or Bluetooth output device.</p>
          </details>
          <details>
            <summary>Can I build it myself?</summary>
            <p>The full Swift source, offline catalog, and build instructions are available on GitHub.</p>
          </details>
        </div>
      </section>

      <footer>
        <a className="brand footer-brand" href="#top">
          <img src="/app-icon.png" alt="" />
          <span>EQ for Mac</span>
        </a>
        <div className="footer-links">
          <a href={DOWNLOAD_URL}>Download</a>
          <a href="/install">Install guide</a>
          <a href={SOURCE_URL}>Source</a>
          <a href={`${SOURCE_URL}/issues`}>Support</a>
        </div>
        <p>For macOS 14.2 and later.</p>
      </footer>
    </main>
  );
}
