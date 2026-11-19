const vscode = require('vscode');
const fs = require('fs');

exports.run = async function () {
  const extension = vscode.extensions.getExtension('openai.chatgpt');
  if (!extension) throw new Error('Codex extension is missing');
  await extension.activate();
  const commands = await vscode.commands.getCommands(true);
  if (!commands.includes('chatgpt.openSidebar')) throw new Error('Codex sidebar command is missing');
  const marker = process.env.EMTROLY_CODEX_ACTIVATION_MARKER;
  if (!marker) throw new Error('Activation marker path is missing');
  fs.writeFileSync(marker, 'ok');
};
