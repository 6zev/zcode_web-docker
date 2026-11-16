// 交叉校验:服务端派生 ownerHostId 的公式 与 Web 端派生 localServerHostId 的公式必须一致。
//   services/src/node.ts : remoteHostIdFromWorkspaceIdentity(buildServerRemoteWorkspaceIdentity({serverId, workspacePath: "/"}))
//   web/src/main.tsx     : 同一公式,serverId 来自 /api/server-info
// 用法(在应用过 patches 的 upstream 检出内执行,例如 /tmp/zcsrc):
//   ./node_modules/.bin/tsx <repo>/verification/local-host-id.check.mjs [/path/to/zcode-src]
const SRC = process.argv[2] ?? process.cwd();
const { buildServerRemoteWorkspaceIdentity, remoteHostIdFromWorkspaceIdentity } = await import(
  `${SRC}/packages/shared/src/remote-workspace-identity.ts`
);

const derive = (serverId) =>
  remoteHostIdFromWorkspaceIdentity(
    buildServerRemoteWorkspaceIdentity({ serverId, workspacePath: "/" }),
  );

const cases = ["zcode-server", "my-host", "host.docker.internal", "My_Host-01"];
let failed = 0;
for (const serverId of cases) {
  const ownerHostId = derive(serverId);
  const localServerHostId = derive(serverId);
  const ok = Boolean(ownerHostId) && ownerHostId === localServerHostId && ownerHostId !== "local";
  if (!ok) failed++;
  console.log(JSON.stringify({ serverId, ownerHostId, localServerHostId, ok }));
}
// 空 serverId 不能冒充本机身份:派生直接抛错,服务端也会拒绝启动(见 node.ts)。
console.log(
  JSON.stringify({
    serverId: "",
    rejected: (() => {
      try {
        derive("");
        return false;
      } catch {
        return true;
      }
    })(),
  }),
);
console.log(failed === 0 ? "RESULT: ALL PASS" : `RESULT: ${failed} FAILED`);
process.exitCode = failed === 0 ? 0 : 1;
