import * as fs from "fs";
import * as path from "path";
import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(context: vscode.ExtensionContext) {
  // Commands are declared in package.json; register them unconditionally so
  // the palette entries work even when the language server is disabled.
  context.subscriptions.push(
    vscode.commands.registerCommand("skein.restartServer", async () => {
      if (client) {
        await client.restart();
        vscode.window.showInformationMessage(
          "Skein Language Server restarted."
        );
      } else {
        vscode.window.showWarningMessage(
          "Skein Language Server is not running (check the skein.lsp.enabled setting)."
        );
      }
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("skein.showServerOutput", () => {
      if (client) {
        client.outputChannel.show();
      } else {
        vscode.window.showWarningMessage(
          "Skein Language Server is not running (check the skein.lsp.enabled setting)."
        );
      }
    })
  );

  const config = vscode.workspace.getConfiguration("skein");
  const lspEnabled = config.get<boolean>("lsp.enabled", true);

  if (!lspEnabled) {
    return;
  }

  const projectPath = getProjectPath(config);
  const serverOptions = resolveServerOptions(config, projectPath);
  const traceLevel = config.get<string>("trace.server", "off");

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "skein" }],
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher("**/*.skein"),
    },
    outputChannelName: "Skein Language Server",
    traceOutputChannel:
      traceLevel !== "off"
        ? vscode.window.createOutputChannel("Skein LSP Trace")
        : undefined,
  };

  client = new LanguageClient(
    "skeinLanguageServer",
    "Skein Language Server",
    serverOptions,
    clientOptions
  );

  client.start();
}

export function deactivate(): Thenable<void> | undefined {
  if (!client) {
    return undefined;
  }
  return client.stop();
}

/**
 * Decides how to launch the language server.
 *
 * - "skein": the standalone `skein` binary (`skein lsp`) — no Elixir needed.
 * - "mix": `mix skein.lsp` inside an Elixir checkout of the Skein repo.
 * - "auto" (default): use mix when the project path looks like the Skein
 *   compiler repo (mix.exs + apps/skein_lsp), otherwise the binary.
 */
function resolveServerOptions(
  config: vscode.WorkspaceConfiguration,
  projectPath: string | undefined
): ServerOptions {
  const mode = config.get<string>("lsp.serverCommand", "auto");

  const useMix =
    mode === "mix" ||
    (mode === "auto" && projectPath !== undefined && isSkeinRepo(projectPath));

  if (useMix) {
    return {
      command: config.get<string>("lsp.mixCommand", "mix"),
      args: ["skein.lsp"],
      options: {
        cwd: projectPath,
        env: {
          ...process.env,
          MIX_ENV: "dev",
        },
      },
      transport: TransportKind.stdio,
    };
  }

  return {
    command: config.get<string>("lsp.skeinPath", "skein") || "skein",
    args: ["lsp"],
    options: {
      cwd: projectPath,
      env: { ...process.env },
    },
    transport: TransportKind.stdio,
  };
}

function isSkeinRepo(projectPath: string): boolean {
  return (
    fs.existsSync(path.join(projectPath, "mix.exs")) &&
    fs.existsSync(path.join(projectPath, "apps", "skein_lsp"))
  );
}

function getProjectPath(
  config: vscode.WorkspaceConfiguration
): string | undefined {
  const configPath = config.get<string>("lsp.path", "");

  if (configPath) {
    return configPath;
  }

  const workspaceFolders = vscode.workspace.workspaceFolders;

  if (workspaceFolders && workspaceFolders.length > 0) {
    return workspaceFolders[0].uri.fsPath;
  }

  return undefined;
}
