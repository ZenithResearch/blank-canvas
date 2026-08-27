import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const mode = process.argv[2];
if (mode !== "adhoc" && mode !== "notarized") {
  throw new Error("usage: node scripts/write-release-metadata.mjs adhoc|notarized");
}

const version = "2.0.0";
const commit = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
const releases = [
  { channel: "production", artifact: `blank-canvas-${version}-macOS.zip` },
  { channel: "staging", artifact: `blank-canvas-staging-${version}-macOS.zip` },
];
const checksumLines = [];

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

for (const release of releases) {
  const artifactPath = join(root, "dist", release.artifact);
  const metadataName = release.artifact.replace(/-macOS\.zip$/, "-release.json");
  const metadataPath = join(root, "dist", metadataName);
  const metadata = {
    schemaVersion: 1,
    name: "blank-canvas",
    version,
    channel: release.channel,
    artifact: {
      name: release.artifact,
      bytes: statSync(artifactPath).size,
      sha256: sha256(artifactPath),
    },
    signing: {
      mode: mode === "notarized" ? "developer-id" : "adhoc",
      notarized: mode === "notarized",
      distributable: mode === "notarized",
    },
    source: {
      repository: "https://github.com/ZenithResearch/blank-canvas",
      commit,
    },
    requirements: { architecture: "arm64", minimumMacOS: "13.0" },
    notice: "ADHOC_RELEASE_NOTICE.md",
  };
  writeFileSync(metadataPath, `${JSON.stringify(metadata, null, 2)}\n`);
  checksumLines.push(`${metadata.artifact.sha256}  ${release.artifact}`);
  checksumLines.push(`${sha256(metadataPath)}  ${metadataName}`);
}

writeFileSync(join(root, "dist", "SHA256SUMS"), `${checksumLines.join("\n")}\n`);

