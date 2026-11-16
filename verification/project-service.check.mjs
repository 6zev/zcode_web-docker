// Quick behavioral check for the standalone-web patches:
//   server-host owner identity (remote:server:...) + browser hostId="local"
// Expected AFTER patching:  saveProject(local) -> hostId=owner ; prepareSession() -> no throw
// Expected BEFORE patching:  project.host-immutable ; project.remote-project-required
import { mkdtempSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { randomUUID } from "node:crypto";

// 用法(在应用过 patches 的 upstream 检出内执行,例如 /tmp/zcsrc):
//   ./node_modules/.bin/tsx <repo>/verification/project-service.check.mjs [/path/to/zcode-src]
const SRC = process.argv[2] ?? process.cwd();
const servicesRoot = `${SRC}/packages/services`;
const {
  createProjectService,
} = await import(`${servicesRoot}/dist/project/index.js`);
const { ProjectRepository } = await import(
  `${servicesRoot}/dist/project-storage/project-repository.js`
);
const { addProjectSchema } = await import(`${servicesRoot}/dist/project-storage/schema.js`);

const OWNER = "remote:server:zcode-server:/";
const dir = mkdtempSync(join(tmpdir(), "zcode-proj-"));
const workspaceDir = join(dir, "workspace");
mkdirSync(workspaceDir, { recursive: true });
const root = join(dir, "my-project");
mkdirSync(root, { recursive: true });

const db = new DatabaseSync(":memory:");
addProjectSchema(db);
db.prepare(
  "INSERT INTO hosts(host_id, kind, position, last_connection_status) VALUES(?, 'server', 0, 'online')",
).run(OWNER);
const repository = new ProjectRepository(db, OWNER);

const service = createProjectService({
  repository: async () => repository,
  workspaceDirectory: workspaceDir,
  ownerHostId: OWNER,
  directories: {
    home: async () => dir,
    read: async () => [],
  },
});

const results = [];
const check = async (name, fn) => {
  try {
    const value = await fn();
    results.push({ name, ok: true, value });
  } catch (error) {
    results.push({ name, ok: false, error: error?.message ?? String(error) });
  }
};

let saved;
await check("saveProject(hostId=local)", async () => {
  saved = await service.saveProject({
    hostId: "local",
    defaultName: "my-project",
    roots: [root],
    primaryRoot: root,
  });
  return { id: saved.id, hostId: saved.hostId };
});

await check("readProjects(hostId=local)", async () => {
  const projects = await service.readProjects({ hostId: "local" });
  return projects.map((project) => project.hostId);
});

await check("readDirectory(hostId=local)", async () => {
  const result = await service.readDirectory({ hostId: "local", path: dir });
  return result.path;
});

await check("prepareSession() draft (no projectId, no hostId)", async () => {
  const directories = await service.prepareSession({ draftId: randomUUID() });
  return directories.workspacePath;
});

await check("prepareSession(hostId=local, projectId)", async () => {
  const directories = await service.prepareSession({ hostId: "local", projectId: saved?.id });
  return { workspacePath: directories.workspacePath, projectId: directories.projectId };
});

const reuseRoot = join(dir, "reuse-project");
mkdirSync(reuseRoot, { recursive: true });
await check("saveProject(reuse existing root, hostId=local)", async () => {
  // 与 UI 一致:reuseExistingRoot 只能带 roots/hostId/reuseExistingRoot 三个键。
  const first = await service.saveProject({
    hostId: "local",
    reuseExistingRoot: true,
    roots: [reuseRoot],
  });
  const again = await service.saveProject({
    hostId: "local",
    reuseExistingRoot: true,
    roots: [reuseRoot],
  });
  return { first: first.id, reused: again.id === first.id, roots: first.roots.map((r) => r.rootPath) };
});

await check("prepareSession() draft without hostId must stay rejected", async () => {
  try {
    await service.prepareSession({ draftId: randomUUID() });
    return "UNEXPECTEDLY ALLOWED";
  } catch (error) {
    if (error?.message === "project.remote-project-required") return "rejected-as-expected";
    throw error;
  }
});

await check("prepareSession() draft with hostId=local", async () => {
  const directories = await service.prepareSession({ hostId: "local", draftId: randomUUID() });
  return directories.workspacePath;
});

const failed = results.filter((entry) => !entry.ok);
for (const entry of results) console.log(JSON.stringify(entry));
console.log(failed.length === 0 ? "RESULT: ALL PASS" : `RESULT: ${failed.length} FAILED`);
process.exitCode = failed.length === 0 ? 0 : 1;
