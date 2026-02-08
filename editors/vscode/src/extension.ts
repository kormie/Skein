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
  const config = vscode.workspace.getConfiguration("skein");
  const lspEnabled = config.get<boolean>("lsp.enabled", true);

  if (!lspEnabled) {
    return;
  }

  const mixCommand = config.get<string>("lsp.mixCommand", "mix");
  const projectPath = getProjectPath(config);

  const serverOptions: ServerOptions = {
    command: mixCommand,
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

  context.subscriptions.push(
    vscode.commands.registerCommand("skein.restartServer", async () => {
      if (client) {
        await client.restart();
        vscode.window.showInformationMessage(
          "Skein Language Server restarted."
        );
      }
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("skein.showServerOutput", () => {
      client?.outputChannel.show();
    })
  );
}

export function deactivate(): Thenable<void> | undefined {
  if (!client) {
    return undefined;
  }
  return client.stop();
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
