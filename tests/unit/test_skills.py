"""Tests for skills wiring — SkillsDirectoryProvider mount + dedup behavior."""
from __future__ import annotations

from pathlib import Path

from fastmcp import FastMCP
from fastmcp.server.providers.skills import SkillsDirectoryProvider

from jarvis.config import SKILL_DIRS


def _make_skill(parent: Path, name: str, description: str, body: str) -> None:
    skill_dir = parent / name
    skill_dir.mkdir()
    (skill_dir / "SKILL.md").write_text(
        f"---\nname: {name}\ndescription: {description}\n---\n{body}"
    )


class TestSkillDirs:
    def test_default_paths(self) -> None:
        assert SKILL_DIRS == [
            Path.home() / ".agents" / "skills",
            Path.home() / ".claude" / "skills",
        ]


class TestSkillsDirectoryProviderMount:
    """Sanity checks on the provider Jarvis mounts in build_mcp()."""

    async def test_skills_listed_as_resources(self, tmp_path: Path) -> None:
        _make_skill(tmp_path, "alpha-skill", "Does alpha", "# Alpha")
        _make_skill(tmp_path, "beta-skill", "Does beta", "# Beta")

        mcp = FastMCP("test")
        mcp.add_provider(SkillsDirectoryProvider(roots=tmp_path))

        uris = {str(r.uri) for r in await mcp._list_resources()}
        assert "skill://alpha-skill/SKILL.md" in uris
        assert "skill://beta-skill/SKILL.md" in uris

    async def test_first_root_wins_for_duplicate_names(self, tmp_path: Path) -> None:
        d1 = tmp_path / "d1"
        d1.mkdir()
        d2 = tmp_path / "d2"
        d2.mkdir()
        _make_skill(d1, "shared", "From d1", "# From d1")
        _make_skill(d2, "shared", "From d2", "# From d2")
        _make_skill(d1, "only-in-d1", "Only d1", "# d1")
        _make_skill(d2, "only-in-d2", "Only d2", "# d2")

        mcp = FastMCP("test")
        mcp.add_provider(SkillsDirectoryProvider(roots=[d1, d2]))

        skill_uris = [
            str(r.uri)
            for r in await mcp._list_resources()
            if str(r.uri).endswith("/SKILL.md")
        ]
        # Shared skill must appear exactly once across both roots, alongside
        # the unique skills from each root.
        assert sorted(skill_uris) == [
            "skill://only-in-d1/SKILL.md",
            "skill://only-in-d2/SKILL.md",
            "skill://shared/SKILL.md",
        ]

        result = await mcp.read_resource("skill://shared/SKILL.md")
        assert "From d1" in result.contents[0].content
