"""Unit tests for ``jarvis.search`` and the ``get_tool_hints`` config helper."""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import AsyncMock

import pytest

from fastmcp.tools.base import Tool

from jarvis.config import get_tool_hints
from jarvis.search import JarvisSearchTransform, ToolHintsTransform


# ── helpers ───────────────────────────────────────────────────────────────────


def make_tool(name: str, description: str | None = None) -> Tool:
    """Build a minimal Tool with a given name and optional description."""

    def fn() -> None: ...

    fn.__doc__ = description
    return Tool.from_function(fn, name=name)


# ── get_tool_hints ────────────────────────────────────────────────────────────


class TestGetToolHints:
    def test_returns_flat_namespaced_dict(self, data_dir: Path) -> None:
        path = data_dir / "cfg.json"
        path.write_text(
            json.dumps(
                {
                    "mcpServers": {},
                    "toolHints": {
                        "exa": {
                            "web_fetch_exa": "browse visit scrape",
                            "web_search_advanced_exa": "company research people",
                        }
                    },
                }
            )
        )
        hints = get_tool_hints(path)
        assert hints == {
            "exa_web_fetch_exa": "browse visit scrape",
            "exa_web_search_advanced_exa": "company research people",
        }

    def test_returns_empty_when_key_absent(self, data_dir: Path) -> None:
        path = data_dir / "cfg.json"
        path.write_text(json.dumps({"mcpServers": {}}))
        assert get_tool_hints(path) == {}

    def test_skips_blank_hints(self, data_dir: Path) -> None:
        path = data_dir / "cfg.json"
        path.write_text(
            json.dumps(
                {
                    "mcpServers": {},
                    "toolHints": {"srv": {"tool_a": "  ", "tool_b": "useful"}},
                }
            )
        )
        hints = get_tool_hints(path)
        assert "srv_tool_a" not in hints
        assert hints["srv_tool_b"] == "useful"

    def test_skips_non_dict_server_entry(self, data_dir: Path) -> None:
        path = data_dir / "cfg.json"
        path.write_text(
            json.dumps(
                {"mcpServers": {}, "toolHints": {"srv": "not-a-dict"}}
            )
        )
        assert get_tool_hints(path) == {}

    def test_multiple_servers(self, data_dir: Path) -> None:
        path = data_dir / "cfg.json"
        path.write_text(
            json.dumps(
                {
                    "mcpServers": {},
                    "toolHints": {
                        "alpha": {"tool_x": "hint x"},
                        "beta": {"tool_y": "hint y"},
                    },
                }
            )
        )
        hints = get_tool_hints(path)
        assert hints == {"alpha_tool_x": "hint x", "beta_tool_y": "hint y"}


# ── ToolHintsTransform ────────────────────────────────────────────────────────


class TestToolHintsTransform:
    async def test_list_tools_appends_hint(self) -> None:
        hints = {"exa_web_fetch_exa": "browse visit scrape"}
        transform = ToolHintsTransform(hints)
        tool = make_tool("exa_web_fetch_exa", "Read a webpage.")
        result = await transform.list_tools([tool])
        assert len(result) == 1
        assert "browse visit scrape" in result[0].description
        assert "Read a webpage." in result[0].description

    async def test_list_tools_leaves_unmatched_tools_unchanged(self) -> None:
        transform = ToolHintsTransform({"exa_web_fetch_exa": "browse"})
        other = make_tool("exa_web_search_exa", "Search the web.")
        result = await transform.list_tools([other])
        assert result[0].description == "Search the web."

    async def test_list_tools_handles_no_description(self) -> None:
        transform = ToolHintsTransform({"srv_tool": "extra keywords"})
        tool = make_tool("srv_tool", None)
        result = await transform.list_tools([tool])
        assert result[0].description == "extra keywords"

    async def test_get_tool_applies_hint(self) -> None:
        hints = {"exa_web_fetch_exa": "scrape crawl"}
        transform = ToolHintsTransform(hints)
        tool = make_tool("exa_web_fetch_exa", "Read a page.")
        call_next = AsyncMock(return_value=tool)

        result = await transform.get_tool("exa_web_fetch_exa", call_next)
        assert result is not None
        assert "scrape crawl" in result.description

    async def test_get_tool_returns_none_when_not_found(self) -> None:
        transform = ToolHintsTransform({"srv_tool": "hint"})
        call_next = AsyncMock(return_value=None)
        result = await transform.get_tool("srv_tool", call_next)
        assert result is None

    async def test_get_tool_passes_version_to_call_next(self) -> None:
        from fastmcp.utilities.versions import VersionSpec

        transform = ToolHintsTransform({})
        tool = make_tool("any_tool")
        call_next = AsyncMock(return_value=tool)
        vs = VersionSpec(gte="1.0")
        await transform.get_tool("any_tool", call_next, version=vs)
        call_next.assert_called_once_with("any_tool", version=vs)

    async def test_original_tool_object_is_not_mutated(self) -> None:
        transform = ToolHintsTransform({"srv_tool": "extra"})
        tool = make_tool("srv_tool", "Original.")
        original_desc = tool.description
        await transform.list_tools([tool])
        assert tool.description == original_desc

    async def test_hint_format_includes_label(self) -> None:
        transform = ToolHintsTransform({"srv_tool": "foo bar"})
        tool = make_tool("srv_tool", "Base description.")
        result = await transform.list_tools([tool])
        assert "Also known as / related: foo bar" in result[0].description


# ── JarvisSearchTransform (smoke test) ────────────────────────────────────────


class TestJarvisSearchTransform:
    def test_is_subclass_of_bm25(self) -> None:
        from fastmcp.server.transforms.search import BM25SearchTransform

        assert issubclass(JarvisSearchTransform, BM25SearchTransform)

    def test_search_tool_has_step_label(self) -> None:
        t = JarvisSearchTransform()._make_search_tool()
        assert "STEP 1" in t.description

    def test_call_tool_has_step_label(self) -> None:
        t = JarvisSearchTransform()._make_call_tool()
        assert "STEP 2" in t.description

    def test_search_tool_warns_against_pasting_full_request(self) -> None:
        t = JarvisSearchTransform()._make_search_tool()
        assert "DO NOT" in t.description or "WRONG" in t.description
