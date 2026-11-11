// Guide: how to edit video with Claude Code on a Mac.
// Product facts follow docs/architecture/ai-control-mcp.md (Connect AI, rounds, undo)
// and the app's own interface labels; prices come from content/pricing.js.
import en from './en.js';
import zh from './zh.js';
import zhHant from './zh-hant.js';
import ja from './ja.js';
import de from './de.js';
import es from './es.js';
export default {
  slug:'edit-video-with-claude-code',
  type:'guide',
  published:'2026-11-11',updated:'2026-11-11',
  asOf:'2026-11',
  // Where each statement about another product comes from. The page lists the names, not the links.
  sources:[
    {name:'claude-video, a Claude Code skill suite (project page)',claim:'Claude Code skills that edit video files drive FFmpeg and Whisper from the terminal and have no timeline',url:'https://github.com/agricidaniel/claude-video',checked:'2026-11-11'},
    {name:'davinci-resolve-mcp by Samuel Gursky (project page)',claim:'A community MCP server controls DaVinci Resolve Studio through its scripting API on macOS, Windows and Linux; external scripting requires Resolve Studio',url:'https://github.com/samuelgursky/davinci-resolve-mcp',checked:'2026-11-11'},
    {name:'Claude Code documentation, Connect Claude Code to tools via MCP',claim:'MCP servers are added with `claude mcp add`, user scope is stored in ~/.claude.json, and /mcp lists connected servers',url:'https://code.claude.com/docs/en/mcp',checked:'2026-11-11'},
  ],
  languages:{en,zh,'zh-hant':zhHant,ja,de,es},
};
