import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";

const MEM0_API = process.env.MEM0_API_URL || "http://localhost:8888";

async function mem0Fetch(path, opts = {}) {
  const url = `${MEM0_API}${path}`;
  const res = await fetch(url, {
    headers: { "Content-Type": "application/json", ...(opts.headers || {}) },
    ...opts,
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`Mem0 API ${res.status}: ${text}`);
  }
  return res.json();
}

const server = new McpServer({
  name: "mem0",
  version: "1.0.0",
});

server.tool(
  "add_memory",
  "Store a new memory. Pass messages as conversation turns and optional user_id/agent_id/run_id.",
  {
    messages: z
      .array(
        z.object({
          role: z.enum(["user", "assistant"]),
          content: z.string(),
        })
      )
      .describe("Conversation messages to extract memory from"),
    user_id: z.string().optional().describe("User identifier"),
    agent_id: z.string().optional().describe("Agent identifier"),
    run_id: z.string().optional().describe("Run identifier"),
    metadata: z.record(z.unknown()).optional().describe("Optional metadata"),
  },
  async ({ messages, user_id, agent_id, run_id, metadata }) => {
    const body = { messages };
    if (user_id) body.user_id = user_id;
    if (agent_id) body.agent_id = agent_id;
    if (run_id) body.run_id = run_id;
    if (metadata) body.metadata = metadata;
    const data = await mem0Fetch("/memories", {
      method: "POST",
      body: JSON.stringify(body),
    });
    return {
      content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
    };
  }
);

server.tool(
  "search_memories",
  "Semantic search across stored memories.",
  {
    query: z.string().describe("Search query"),
    user_id: z.string().optional().describe("Filter by user"),
    agent_id: z.string().optional().describe("Filter by agent"),
    run_id: z.string().optional().describe("Filter by run"),
    limit: z.number().optional().describe("Max results (default: 100)"),
  },
  async ({ query, user_id, agent_id, run_id, limit }) => {
    const body = { query };
    const filters = {};
    if (user_id) filters.user_id = user_id;
    if (agent_id) filters.agent_id = agent_id;
    if (run_id) filters.run_id = run_id;
    if (Object.keys(filters).length > 0) body.filters = filters;
    if (limit) body.limit = limit;
    const data = await mem0Fetch("/search", {
      method: "POST",
      body: JSON.stringify(body),
    });
    return {
      content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
    };
  }
);

server.tool(
  "get_memories",
  "List all stored memories with optional filters.",
  {
    user_id: z.string().optional().describe("Filter by user"),
    agent_id: z.string().optional().describe("Filter by agent"),
    run_id: z.string().optional().describe("Filter by run"),
  },
  async ({ user_id, agent_id, run_id }) => {
    const params = new URLSearchParams();
    if (user_id) params.set("user_id", user_id);
    if (agent_id) params.set("agent_id", agent_id);
    if (run_id) params.set("run_id", run_id);
    const qs = params.toString();
    const data = await mem0Fetch(`/memories${qs ? `?${qs}` : ""}`);
    return {
      content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
    };
  }
);

server.tool(
  "get_memory",
  "Retrieve a specific memory by ID.",
  {
    memory_id: z.string().describe("Memory ID"),
  },
  async ({ memory_id }) => {
    const data = await mem0Fetch(`/memories/${memory_id}`);
    return {
      content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
    };
  }
);

server.tool(
  "update_memory",
  "Update a memory's text by ID.",
  {
    memory_id: z.string().describe("Memory ID"),
    text: z.string().describe("New memory text"),
  },
  async ({ memory_id, text }) => {
    const data = await mem0Fetch(`/memories/${memory_id}`, {
      method: "PUT",
      body: JSON.stringify({ text }),
    });
    return {
      content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
    };
  }
);

server.tool(
  "delete_memory",
  "Delete a single memory by ID.",
  {
    memory_id: z.string().describe("Memory ID"),
  },
  async ({ memory_id }) => {
    const data = await mem0Fetch(`/memories/${memory_id}`, { method: "DELETE" });
    return {
      content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
    };
  }
);

server.tool(
  "delete_all_memories",
  "Delete all memories, optionally filtered by user/agent/run.",
  {
    user_id: z.string().optional().describe("Filter by user"),
    agent_id: z.string().optional().describe("Filter by agent"),
    run_id: z.string().optional().describe("Filter by run"),
  },
  async ({ user_id, agent_id, run_id }) => {
    const params = new URLSearchParams();
    if (user_id) params.set("user_id", user_id);
    if (agent_id) params.set("agent_id", agent_id);
    if (run_id) params.set("run_id", run_id);
    const qs = params.toString();
    const data = await mem0Fetch(`/memories${qs ? `?${qs}` : ""}`, {
      method: "DELETE",
    });
    return {
      content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
    };
  }
);

server.tool(
  "memory_history",
  "Get the change history for a specific memory.",
  {
    memory_id: z.string().describe("Memory ID"),
  },
  async ({ memory_id }) => {
    const data = await mem0Fetch(`/memories/${memory_id}/history`);
    return {
      content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
    };
  }
);

const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: () => crypto.randomUUID() });

await server.connect(transport);

const PORT = parseInt(process.env.PORT || "8890", 10);

const { createServer } = await import("http");
createServer((req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok", mem0_api: MEM0_API }));
    return;
  }
  transport.handleRequest(req, res);
}).listen(PORT, () => {
  console.log(`mem0-mcp-adapter listening on http://localhost:${PORT}/mcp`);
});
