"""Unit tests for ``jarvis.search`` and the ``get_server_descriptions`` helper."""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import AsyncMock

import pytest

from jarvis.config import get_server_descriptions
from jarvis.search import JarvisSearchTransform


# ── get_server_descriptions ───────────────────────────────────────────────────


class TestGetServerDescriptions:
    def test_reads_descriptions_and_defaults_blank(self, data_dir: Path) -> None:
        path = data_dir / "cfg.json"
        path.write_text(
            json.dumps(
                {
                    "mcpServers": {
                        "github": {
                            "url": "http://g",
                            "description": "Issues, PRs, commits",
                        },
                        "gmail": {"url": "http://m"},
                    }
                }
            )
        )
        assert get_server_descriptions(path) == {
            "github": "Issues, PRs, commits",
            "gmail": "",
        }

    def test_strips_whitespace(self, data_dir: Path) -> None:
        path = data_dir / "cfg.json"
        path.write_text(
            json.dumps(
                {"mcpServers": {"a": {"url": "http://a", "description": "  hi  "}}}
            )
        )
        assert get_server_descriptions(path) == {"a": "hi"}

    def test_skips_disabled_servers(self, data_dir: Path) -> None:
        path = data_dir / "cfg.json"
        path.write_text(
            json.dumps(
                {
                    "mcpServers": {
                        "a": {"url": "http://a", "description": "A", "enabled": False},
                        "b": {"url": "http://b", "description": "B"},
                    }
                }
            )
        )
        assert get_server_descriptions(path) == {"b": "B"}

    def test_empty_when_no_servers(self, data_dir: Path) -> None:
        path = data_dir / "cfg.json"
        path.write_text(json.dumps({"mcpServers": {}}))
        assert get_server_descriptions(path) == {}

    def test_skips_non_dict_server_entry(self, data_dir: Path) -> None:
        path = data_dir / "cfg.json"
        path.write_text(
            json.dumps(
                {"mcpServers": {"bad": "not-a-dict", "ok": {"url": "http://o", "description": "D"}}}
            )
        )
        assert get_server_descriptions(path) == {"ok": "D"}


# ── JarvisSearchTransform: synthetic tool descriptions ────────────────────────


class TestJarvisSearchTransform:
    def test_is_subclass_of_bm25(self) -> None:
        from fastmcp.server.transforms.search import BM25SearchTransform

        assert issubclass(JarvisSearchTransform, BM25SearchTransform)

    def test_search_tool_has_step_label(self) -> None:
        t = JarvisSearchTransform()._make_search_tool()
        assert "STEP 2" in t.description

    def test_call_tool_has_step_label(self) -> None:
        t = JarvisSearchTransform()._make_call_tool()
        assert "STEP 3" in t.description

    def test_search_tool_warns_against_pasting_full_request(self) -> None:
        t = JarvisSearchTransform()._make_search_tool()
        assert "DO NOT" in t.description or "WRONG" in t.description


# ── load_tools ────────────────────────────────────────────────────────────────


class TestLoadTools:
    def test_make_load_tool_named_and_first_step(self) -> None:
        t = JarvisSearchTransform()._make_load_tool()
        assert t.name == "load_tools"
        assert "STEP 1" in t.description
        assert "FIRST" in t.description

    async def test_transform_tools_exposes_all_three(self) -> None:
        transform = JarvisSearchTransform(
            server_descriptions={"github": "Issues and PRs"}
        )
        result = await transform.transform_tools([])
        names = [t.name for t in result]
        assert {"load_tools", "search_tools", "call_tool"} <= set(names)
        # load_tools is offered first.
        assert names[0] == "load_tools"

    async def test_get_tool_intercepts_load_tools(self) -> None:
        transform = JarvisSearchTransform(server_descriptions={"x": "y"})
        call_next = AsyncMock(return_value=None)
        result = await transform.get_tool("load_tools", call_next)
        assert result is not None and result.name == "load_tools"
        call_next.assert_not_called()

    async def test_get_tool_delegates_unknown_names(self) -> None:
        transform = JarvisSearchTransform(server_descriptions={"x": "y"})
        call_next = AsyncMock(return_value=None)
        await transform.get_tool("some_backend_tool", call_next)
        call_next.assert_called_once()

    def test_render_overview_lists_servers_and_descriptions(self) -> None:
        transform = JarvisSearchTransform(
            server_descriptions={"github": "Issues and PRs", "gmail": ""}
        )
        text = transform._render_server_overview()
        assert "- github: Issues and PRs" in text
        assert "- gmail" in text
        # gmail has no description, so no trailing colon-description.
        assert "- gmail:" not in text

    def test_render_overview_empty_points_to_search(self) -> None:
        text = JarvisSearchTransform(server_descriptions={})._render_server_overview()
        assert "search_tools" in text

    async def test_load_tool_coroutine_returns_overview(self) -> None:
        transform = JarvisSearchTransform(
            server_descriptions={"github": "Issues and PRs"}
        )
        result = await transform._make_load_tool().fn()
        assert "github: Issues and PRs" in result

    async def test_call_tool_blocks_load_tools(self) -> None:
        transform = JarvisSearchTransform(server_descriptions={"x": "y"})
        with pytest.raises(ValueError, match="synthetic search tool"):
            await transform._make_call_tool().fn(name="load_tools", ctx=None)
