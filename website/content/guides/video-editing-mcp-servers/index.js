// Guide: video editing MCP servers for Claude and Codex, and how to choose one.
// We make SkyCut and have not benchmarked the other tools: every statement about
// them is taken from their own pages (sources below) and nothing is ranked by quality.
import en from './en.js';
import ja from './ja.js';
export default {
  slug:'video-editing-mcp-servers',
  type:'list',
  published:'2026-11-11',updated:'2026-11-11',
  asOf:'2026-11',
  sources:[
    {name:'Palmier Pro (project README)',claim:'A macOS video editor where agents create and edit directly on the timeline; requires macOS 26 on Apple silicon; runs a local MCP server while the app is open; names Claude Code, Codex, Cursor and Claude Desktop; has built-in generative models',url:'https://github.com/palmier-io/palmier-pro',checked:'2026-11-11'},
    {name:'ChatCut, Claude Code plugin page',claim:'ChatCut Desktop is a local app connected through a local MCP server; supports macOS 13 or newer on Apple silicon and Intel and Windows 10 or newer on x64; you can adjust the timeline, captions and motion graphics yourself; some features need a membership',url:'https://chatcut.io/claude-code-plugin',checked:'2026-11-11'},
    {name:'Tella blog, The Best MCP Servers for Video Editing',claim:'Tella is a screen recorder and editor for Mac, Windows and the web; its hosted MCP server has more than 100 tools, uses OAuth sign-in and is included on every plan; names Claude, ChatGPT, Claude Code, Codex and Cursor',url:'https://www.tella.com/blog/best-mcp-servers-for-video-editing',checked:'2026-11-11'},
    {name:'davinci-resolve-mcp by Samuel Gursky (project page)',claim:'A community MCP server controls DaVinci Resolve Studio through its scripting API on macOS, Windows and Linux; external scripting requires Resolve Studio; its installer can configure Claude Desktop, Claude Code, Codex CLI and other clients',url:'https://github.com/samuelgursky/davinci-resolve-mcp',checked:'2026-11-11'},
    {name:'claude-video, a Claude Code skill suite (project page)',claim:'Skills that edit video files drive FFmpeg and Whisper from the terminal and have no timeline',url:'https://github.com/agricidaniel/claude-video',checked:'2026-11-11'},
  ],
  languages:{en,ja},
};
