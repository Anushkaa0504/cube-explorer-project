"""Tiny smoke-test MCP client that spawns cube_mcp.py over stdio and
calls a couple of tools end-to-end. Used by `make mcp-test`."""

import asyncio
import json
import os
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    params = StdioServerParameters(
        command=os.path.join(here, ".venv", "bin", "python"),
        args=[os.path.join(here, "cube_mcp.py")],
        env=os.environ.copy(),
    )

    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            tools = await session.list_tools()
            print("TOOLS:", [t.name for t in tools.tools])

            print("\n--- list_cubes (cube names) ---")
            result = await session.call_tool("list_cubes", {})
            payload = json.loads(result.content[0].text)
            print([c["name"] for c in payload["cubes"]])

            print("\n--- query: spending by category (top 3) ---")
            result = await session.call_tool(
                "query",
                {
                    "measures": ["transactions.total_expense"],
                    "dimensions": ["categories.name"],
                    "order": {"transactions.total_expense": "desc"},
                    "limit": 3,
                },
            )
            print(result.content[0].text)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as e:
        print(f"FAILED: {e}", file=sys.stderr)
        sys.exit(1)
