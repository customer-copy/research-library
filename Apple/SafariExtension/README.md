# Save to Research Library for Safari

The extension is bundled inside the macOS Research Library app. It has two entry points:

- Click its book icon in Safari's toolbar, then **Save to Research Library** to capture the current article or PDF URL.
- Click **+ Research Library** beside an individual Google search result to send that result without leaving Google. New results added while scrolling are detected automatically.

The toolbar reads publisher citation title, DOI, PMID, and a declared PDF link when the page exposes them. Safari's built-in PDF viewer may disallow script injection; capturing its HTTP/HTTPS URL still works. Captures go through the same durable Inbox queue, metadata resolution, duplicate detection, PDF organization, and original-Inbox cleanup as other captures. **Sent** means handed to the app; processing and PDF availability appear in Research Library. Login-only PDFs may require importing the downloaded PDF directly.

## Enable the local build

1. Open the installed Research Library app and select your library folder if you haven't already.
2. In Safari → Settings → Advanced, enable **Show features for web developers**.
3. In Safari → Settings → Developer, enable **Allow unsigned extensions**. **Do not quit or restart Safari after this step**: quitting resets the option and can hide the extension again.
4. In Safari → Settings → Extensions, enable **Save to Research Library**. You can open this pane from Research Library → Library → **Enable Safari Extension…**.
5. Allow the extension on Google when Safari asks, then reload an existing search-results page. The toolbar can capture other sites on demand using its active-tab permission.

This Mac's local build uses ad-hoc signing. Safari resets **Allow unsigned extensions** when you quit Safari, so enable it again after relaunching. Signing the app and extension in Xcode with an Apple development identity avoids relying on the unsigned testing option. See Apple's [Safari extension testing instructions](https://developer.apple.com/documentation/safariservices/running-your-safari-web-extension).

If the Extensions pane is empty after a restart, re-enable **Allow unsigned extensions**, then switch directly to Extensions while Safari stays open. macOS plugin registration alone does not confirm Safari has accepted the extension; a scoped `--safari-extension-report <path>` launch argument asks Safari's own extension API for recognition/enabled state.

## Privacy and permissions

Automatic content-script access is limited to Google search pages on the listed domains in `Resources/manifest.json`. The toolbar uses `activeTab` and `scripting` only when invoked. The extension sends the selected result/page URL and citation hints to the app through native messaging and a validated URL handoff. It has no access to the selected library folder or its bookmark. It does not read or transmit stored papers, notes, cookies, or browser history. No third-party extension server is used.

## Development

Run `python3 Scripts/generate-project.py` after changing target configuration or resource filenames, then build the **Research Library** macOS scheme in Xcode. It embeds the `Save to Research Library.appex` target. `Scripts/build-macos.sh` signs the extension with its sandbox entitlement before signing the parent app. Swift-package-only builds omit the Safari extension; use the Xcode build for Safari capture.

Core tests cover validated handoff fields, unsafe URLs, and preservation of completed requests on retry. `Scripts/test-safari-extension.cjs` uses Playwright and a disposable browser to check result buttons, dynamic/reused results, send/retry state, citation metadata, and the PDF-viewer fallback. Native activation and permissions must still be tested in Safari after enabling the extension.
