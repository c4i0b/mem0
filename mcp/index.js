import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import pg from "pg";

const OLLAMA_BASE = process.env.OLLAMA_BASE_URL || "http://localhost:11434";
const EMBED_MODEL = process.env.EMBED_MODEL || "nomic-embed-text";
const EMBED_DIMS = parseInt(process.env.EMBED_DIMS || "768", 10);
const PG_HOST = process.env.POSTGRES_HOST || "localhost";
const PG_PORT = parseInt(process.env.POSTGRES_PORT || "5432", 10);
const PG_USER = process.env.POSTGRES_USER || "postgres";
const PG_PASSWORD = process.env.POSTGRES_PASSWORD || "postgres";
const PG_DB = process.env.POSTGRES_DB || "postgres";
const PG_TABLE = process.env.POSTGRES_TABLE || "memories";

const pool = new pg.Pool({
  host: PG_HOST,
  port: PG_PORT,
  user: PG_USER,
  password: PG_PASSWORD,
  database: PG_DB,
});

async function ensureTable() {
  await pool.query(`
    CREATE EXTENSION IF NOT EXISTS vector;
    CREATE TABLE IF NOT EXISTS "${PG_TABLE}" (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      vector vector(${EMBED_DIMS}),
      payload JSONB NOT NULL DEFAULT '{}'
    );
  `);
}

async function embed(text) {
  const res = await fetch(`${OLLAMA_BASE}/api/embed`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ model: EMBED_MODEL, input: text }),
  });
  if (!res.ok) throw new Error(`Ollama embed error: ${res.status}`);
  const data = await res.json();
  return data.embeddings[0];
}

function vecLiteral(arr) {
  return `[${arr.join(",")}]`;
}

const server = new McpServer({
  name: "mem0",
  version: "2.0.0",
});

server.tool(
  "add_memory",
  "Store a memory. Embeds text via Ollama and stores in pgvector.",
  {
    text: z.string().describe("Memory text to store"),
    user_id: z.string().optional().describe("User identifier"),
    agent_id: z.string().optional().describe("Agent identifier"),
    metadata: z.record(z.unknown()).optional().describe("Optional metadata"),
  },
  async ({ text, user_id, agent_id, metadata }) => {
    const vector = await embed(text);
    const payload = { text, ...(user_id && { user_id }), ...(agent_id && { agent_id }), ...(metadata && { metadata }) };
    const { rows } = await pool.query(
      `INSERT INTO "${PG_TABLE}" (vector, payload) VALUES ($1::vector, $2) RETURNING id`,
      [vecLiteral(vector), JSON.stringify(payload)]
    );
    return {
      content: [{ type: "text", text: JSON.stringify({ id: rows[0].id, stored: true }) }],
    };
  }
);

server.tool(
  "search_memories",
  "Semantic search across memories using Ollama embeddings + pgvector cosine similarity.",
  {
    query: z.string().describe("Search query"),
    user_id: z.string().optional().describe("Filter by user_id in payload"),
    limit: z.number().optional().describe("Max results (default 10)"),
  },
  async ({ query, user_id, limit }) => {
    const vector = await embed(query);
    const lim = limit || 10;
    let sql = `SELECT id, payload, vector <=> $1::vector AS distance FROM "${PG_TABLE}"`;
    const params = [vecLiteral(vector)];
    if (user_id) {
      params.push(user_id);
      sql += ` WHERE payload->>'user_id' = $${params.length}`;
    }
    sql += ` ORDER BY distance LIMIT $${params.length + 1}`;
    params.push(lim);
    const { rows } = await pool.query(sql, params);
    const results = rows.map((r) => ({
      id: r.id,
      memory: r.payload.text,
      score: 1 - r.distance,
      metadata: r.payload.metadata || {},
      user_id: r.payload.user_id || null,
    }));
    return {
      content: [{ type: "text", text: JSON.stringify({ results }, null, 2) }],
    };
  }
);

server.tool(
  "get_memories",
  "List stored memories.",
  {
    user_id: z.string().optional().describe("Filter by user_id"),
    limit: z.number().optional().describe("Max results (default 50)"),
  },
  async ({ user_id, limit }) => {
    const lim = limit || 50;
    let sql = `SELECT id, payload FROM "${PG_TABLE}"`;
    const params = [];
    if (user_id) {
      params.push(user_id);
      sql += ` WHERE payload->>'user_id' = $${params.length}`;
    }
    params.push(lim);
    sql += ` ORDER BY id DESC LIMIT $${params.length}`;
    const { rows } = await pool.query(sql, params);
    const results = rows.map((r) => ({
      id: r.id,
      memory: r.payload.text,
      metadata: r.payload.metadata || {},
      user_id: r.payload.user_id || null,
    }));
    return {
      content: [{ type: "text", text: JSON.stringify({ results }, null, 2) }],
    };
  }
);

server.tool(
  "get_memory",
  "Get a specific memory by ID.",
  { memory_id: z.string().describe("Memory UUID") },
  async ({ memory_id }) => {
    const { rows } = await pool.query(
      `SELECT id, payload FROM "${PG_TABLE}" WHERE id = $1`,
      [memory_id]
    );
    if (rows.length === 0) {
      return { content: [{ type: "text", text: JSON.stringify({ error: "not found" }) }] };
    }
    const r = rows[0];
    return {
      content: [{
        type: "text",
        text: JSON.stringify({ id: r.id, memory: r.payload.text, metadata: r.payload.metadata || {}, user_id: r.payload.user_id || null }),
      }],
    };
  }
);

server.tool(
  "update_memory",
  "Update a memory's text (re-embeds with Ollama).",
  {
    memory_id: z.string().describe("Memory UUID"),
    text: z.string().describe("New memory text"),
  },
  async ({ memory_id, text }) => {
    const vector = await embed(text);
    const { rowCount } = await pool.query(
      `UPDATE "${PG_TABLE}" SET vector = $1::vector, payload = jsonb_set(payload, '{text}', $2) WHERE id = $3`,
      [vecLiteral(vector), JSON.stringify(text), memory_id]
    );
    return {
      content: [{ type: "text", text: JSON.stringify({ updated: rowCount > 0, id: memory_id }) }],
    };
  }
);

server.tool(
  "delete_memory",
  "Delete a single memory by ID.",
  { memory_id: z.string().describe("Memory UUID") },
  async ({ memory_id }) => {
    const { rowCount } = await pool.query(
      `DELETE FROM "${PG_TABLE}" WHERE id = $1`,
      [memory_id]
    );
    return {
      content: [{ type: "text", text: JSON.stringify({ deleted: rowCount > 0, id: memory_id }) }],
    };
  }
);

server.tool(
  "delete_all_memories",
  "Delete all memories, optionally filtered by user_id.",
  { user_id: z.string().optional().describe("Filter by user_id") },
  async ({ user_id }) => {
    let sql = `DELETE FROM "${PG_TABLE}"`;
    const params = [];
    if (user_id) {
      params.push(user_id);
      sql += ` WHERE payload->>'user_id' = $${params.length}`;
    }
    const { rowCount } = await pool.query(sql, params);
    return {
      content: [{ type: "text", text: JSON.stringify({ deleted_count: rowCount }) }],
    };
  }
);

server.tool(
  "stats",
  "Show memory count and embedding model info.",
  {},
  async () => {
    const { rows } = await pool.query(`SELECT COUNT(*) as count FROM "${PG_TABLE}"`);
    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          total_memories: parseInt(rows[0].count, 10),
          embed_model: EMBED_MODEL,
          embed_dims: EMBED_DIMS,
          table: PG_TABLE,
        }),
      }],
    };
  }
);

await ensureTable();

const transport = new StreamableHTTPServerTransport({
  sessionIdGenerator: () => crypto.randomUUID(),
});
await server.connect(transport);

const { createServer } = await import("http");
const PORT = parseInt(process.env.PORT || "8890", 10);
createServer((req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok", embed_model: EMBED_MODEL, embed_dims: EMBED_DIMS }));
    return;
  }
  transport.handleRequest(req, res);
}).listen(PORT, () => {
  console.log(`mem0-mcp listening on :${PORT}/mcp (ollama: ${OLLAMA_BASE}, embed: ${EMBED_MODEL}, dims: ${EMBED_DIMS})`);
});
