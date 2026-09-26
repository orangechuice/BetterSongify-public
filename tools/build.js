const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const sourcePath = path.join(root, "src", "index.js");
const chromeSrcDir = path.join(root, "src", "chrome");
const desktopOutputPath = path.join(root, "dist", "BetterSongify.js");
const chromeOutDir = path.join(root, "dist", "chrome");

function write(outputPath, contents) {
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, contents);
  console.log(`Wrote ${path.relative(root, outputPath)}`);
}

// The base styles live in the ensureBaseStyles template literal so the
// injected desktop build stays a single file. The Chrome build also ships
// them as manifest CSS, which the page CSP cannot block.
function extractBaseCss(source) {
  const match = source.match(/style\.textContent = `([^`]*)`/);
  if (!match) throw new Error("Could not find the ensureBaseStyles CSS template literal in src/index.js");
  return match[1].trim() + "\n";
}

// Targets are independent: the macOS installer only needs the desktop bundle,
// so `--target=desktop` skips the Chrome extension entirely (and vice versa).
const VALID_TARGETS = ["desktop", "chrome"];

function parseTargets(argv) {
  const requested = [];
  for (const arg of argv) {
    const value = arg.startsWith("--target=") ? arg.slice("--target=".length) : arg;
    for (const name of value.split(",")) {
      const target = name.trim();
      if (!target) continue;
      if (target === "all") {
        requested.push(...VALID_TARGETS);
      } else if (VALID_TARGETS.includes(target)) {
        requested.push(target);
      } else {
        throw new Error(`Unknown build target "${target}". Use one of: ${VALID_TARGETS.join(", ")}, all`);
      }
    }
  }
  return requested.length ? [...new Set(requested)] : VALID_TARGETS;
}

// `--no-notifier` builds the desktop bundle for an install without
// BetterSongifyNotifier.app (install-macos.sh --no-notifier): the script then
// hides the menu-bar toggle and never calls the loopback companion. The flag is
// a literal in src/index.js rather than a runtime probe so the panel is right
// from its first render; a missing literal throws instead of silently shipping
// a bundle that still expects the companion.
const NOTIFIER_FLAG = "const NOTIFIER_COMPANION_INSTALLED = true;";

function withoutNotifierCompanion(source) {
  if (!source.includes(NOTIFIER_FLAG)) {
    throw new Error(`Could not find "${NOTIFIER_FLAG}" in src/index.js for --no-notifier`);
  }
  return source.replace(NOTIFIER_FLAG, "const NOTIFIER_COMPANION_INSTALLED = false;");
}

function buildDesktop(source, { withNotifier }) {
  const variant = withNotifier ? "" : "// Built with --no-notifier: no notifier companion.\n";
  const banner = `// Reconstructed readable BetterSongify bundle.\n// Generated from src/index.js by tools/build.js.\n${variant}`;
  write(desktopOutputPath, `${banner}${withNotifier ? source : withoutNotifierCompanion(source)}`);
}

function buildChrome(source) {
  write(path.join(chromeOutDir, "content.js"), source);
  write(path.join(chromeOutDir, "background.js"), fs.readFileSync(path.join(chromeSrcDir, "background.js"), "utf8"));
  write(path.join(chromeOutDir, "manifest.json"), fs.readFileSync(path.join(chromeSrcDir, "manifest.json"), "utf8"));
  write(path.join(chromeOutDir, "styles.css"), extractBaseCss(source));

  for (const icon of fs.readdirSync(path.join(chromeSrcDir, "icons"))) {
    write(path.join(chromeOutDir, "icons", icon), fs.readFileSync(path.join(chromeSrcDir, "icons", icon)));
  }
}

const args = process.argv.slice(2);
const withNotifier = !args.includes("--no-notifier");
const targets = parseTargets(args.filter((arg) => arg !== "--no-notifier"));
const source = fs.readFileSync(sourcePath, "utf8");

// The Chrome build never has a companion, so the flag only shapes desktop.
if (targets.includes("desktop")) buildDesktop(source, { withNotifier });
if (targets.includes("chrome")) buildChrome(source);
