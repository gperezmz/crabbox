import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmod, mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const script = path.join(scriptDir, "mint-gcp-devtools-image.sh");

async function setupFakeCrabbox() {
  const dir = await mkdtemp(path.join(os.tmpdir(), "crabbox-gcp-image-mint-test-"));
  const log = path.join(dir, "fake.log");
  const fake = path.join(dir, "crabbox");
  const linuxPrep = path.join(dir, "linux.sh");
  await writeFile(linuxPrep, "#!/usr/bin/env bash\nexit 0\n");
  await chmod(linuxPrep, 0o755);
  await writeFile(
    fake,
    `#!/usr/bin/env bash
set -euo pipefail
printf 'args %s\\n' "$*" >>"\${CRABBOX_FAKE_LOG:?}"
case "$1" in
  warmup)
    count_file="\${CRABBOX_FAKE_LOG}.count"
    count=0
    [[ -f "$count_file" ]] && count="$(cat "$count_file")"
    count="$((count + 1))"
    printf '%s\\n' "$count" >"$count_file"
    printf 'image selected id=%s source=snapshot kind=gcp-disk-snapshot region=europe-west1-b promoted_at=-\\n' \\
      "\${CRABBOX_FAKE_SNAPSHOT_ID:-crabbox-devtools}"
    printf '{"leaseId":"cbx_lease%s"}\\n' "$count"
    ;;
  run)
    printf 'devtools-smoke-ok\\n'
    ;;
  checkpoint)
    if [[ "$2" == "create" ]]; then
      printf 'checkpoint created id=chk_devtools kind=gcp-disk-snapshot resource=crabbox-devtools state=ready region=europe-west1-b workdir=-\\n'
    else
      printf 'checkpoint forked id=chk_devtools lease=cbx_candidate slug=jade-prawn image=crabbox-devtools workdir=-\\n'
    fi
    ;;
  stop)
    printf 'released\\n'
    ;;
esac
`,
  );
  await chmod(fake, 0o755);
  return { dir, log, fake, linuxPrep };
}

function runScript(args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn("bash", [script, ...args], {
      cwd: repoRoot,
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

test("GCP devtools mint wrapper defaults to dry plan", async () => {
  const fake = await setupFakeCrabbox();
  const result = await runScript(["--prep-script", fake.linuxPrep], {
    CRABBOX_BIN: fake.fake,
    CRABBOX_FAKE_LOG: fake.log,
    CRABBOX_IMAGE_LOG_DIR: path.join(fake.dir, "logs"),
  });
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /dry plan only/);
  await assert.rejects(readFile(fake.log, "utf8"));
});

test("GCP developer image smoke executes package managers and requires TruffleHog", async () => {
  const text = await readFile(script, "utf8");
  assert.match(
    text,
    /command -v pnpm\ncommand -v trufflehog\ntrufflehog --no-update --version\ncommand -v docker\nnode --version\nnode -e .*\ncorepack --version\npnpm --version\n/,
  );
  assert.match(text, /test -f \/var\/lib\/crabbox-readiness\/linux\.json/);
  assert.match(text, /test -f \/var\/lib\/crabbox\/image-ready/);
});

test("GCP Linux image production stages and invokes only the generated readiness producer", async () => {
  const source = await readFile(script, "utf8");
  assert.match(source, /--script "\$ROOT\/scripts\/linux-readiness\.generated\.sh" -- --install/);
  assert.equal(
    (source.match(/--script "\$ROOT\/scripts\/linux-readiness\.generated\.sh"/g) ?? []).length,
    1,
  );
  assert.match(source, /--shell -- \/usr\/local\/libexec\/crabbox\/linux-readiness\.generated\.sh/);
});

test("GCP devtools mint wrapper captures a disk snapshot and forks the candidate", async () => {
  const fake = await setupFakeCrabbox();
  const result = await runScript(["--run", "--prep-script", fake.linuxPrep], {
    CRABBOX_BIN: fake.fake,
    CRABBOX_FAKE_LOG: fake.log,
    CRABBOX_IMAGE_LOG_DIR: path.join(fake.dir, "logs"),
  });
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /^snapshot=crabbox-devtools$/m);

  const calls = (await readFile(fake.log, "utf8")).trim().split(/\n/);
  const joined = calls.join("\n");
  assert.match(joined, /warmup --provider gcp --target linux --class standard --market on-demand/);
  assert.match(joined, /checkpoint create .*--mode native --strategy disk-snapshot --wait/);
  assert.match(joined, /checkpoint fork chk_devtools --provider gcp --target linux/);
  assert.match(joined, /stop --provider gcp --target linux cbx_lease1/);
  const readiness = calls.findIndex(
    (line) => line.includes("linux-readiness") && line.includes("-- --install"),
  );
  const prep = calls.findIndex((line) => line.includes(fake.linuxPrep));
  assert.ok(readiness >= 0 && prep > readiness, joined);
});

test("GCP devtools mint wrapper proves a promoted snapshot without minting", async () => {
  const fake = await setupFakeCrabbox();
  const result = await runScript(
    ["--run", "--prep-script", fake.linuxPrep, "--promoted-proof", "crabbox-devtools"],
    {
      CRABBOX_BIN: fake.fake,
      CRABBOX_FAKE_LOG: fake.log,
      CRABBOX_IMAGE_LOG_DIR: path.join(fake.dir, "logs"),
    },
  );
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /promoted linux developer image passed: crabbox-devtools/);
  assert.doesNotMatch(await readFile(fake.log, "utf8"), /checkpoint create/);
});

test("GCP devtools mint wrapper fails when promoted selection is not proved", async () => {
  const fake = await setupFakeCrabbox();
  const result = await runScript(
    ["--run", "--prep-script", fake.linuxPrep, "--promoted-proof", "crabbox-devtools"],
    {
      CRABBOX_BIN: fake.fake,
      CRABBOX_FAKE_LOG: fake.log,
      CRABBOX_IMAGE_LOG_DIR: path.join(fake.dir, "logs"),
      CRABBOX_FAKE_SNAPSHOT_ID: "some-older-snapshot",
    },
  );
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /did not prove image selection/);
});
