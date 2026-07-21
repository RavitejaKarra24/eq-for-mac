# EQ for Mac website

The public product and download site for EQ for Mac. It is a vinext site built
for OpenAI Sites hosting and lives alongside the native Swift app.

## Local development

```bash
npm install
npm run dev
```

Create the production output with `npm run build`.

The primary download points to the latest universal, ad-hoc-signed DMG on
GitHub. The `/install` route explains the expected Gatekeeper approval with
macOS screenshots, checksum verification, and copyable Homebrew commands.
Product screenshots and the app icon are copied from the native app project so
the website and application stay visually consistent.
