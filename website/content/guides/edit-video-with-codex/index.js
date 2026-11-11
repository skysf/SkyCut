// Guide: how to edit video with Codex on a Mac.
// Connection facts follow docs/architecture/ai-control-mcp.md section 6 (Connect AI);
// the measured run is docs/reports/2026-10-26-codex-client-smoke.md.
import en from './en.js';
import zh from './zh.js';
import ja from './ja.js';
export default {
  slug:'edit-video-with-codex',
  type:'guide',
  published:'2026-11-11',updated:'2026-11-11',
  asOf:'2026-11',
  sources:[
    {name:'Codex documentation, Model Context Protocol',claim:'Codex keeps MCP servers in ~/.codex/config.toml under [mcp_servers.<name>]; the ChatGPT desktop app, Codex CLI and IDE extension share this configuration; /mcp and `codex mcp list` show servers',url:'https://learn.chatgpt.com/docs/extend/mcp?surface=cli',checked:'2026-11-11'},
  ],
  languages:{en,zh,ja},
};
