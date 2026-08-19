from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]

GENERATED_OR_VENDOR_DIRS = {
    ".dart_tool",
    ".pytest_cache",
    "_build",
    "bin",
    "build",
    "coverage",
    "deps",
    "dist",
    "htmlcov",
    "node_modules",
    "obj",
    "vendor",
}
LOCK_FILE_NAMES = {
    "Cargo.lock",
    "Gemfile.lock",
    "bun.lockb",
    "composer.lock",
    "package-lock.json",
    "pnpm-lock.yaml",
    "poetry.lock",
    "yarn.lock",
}
SELF = Path(__file__).resolve()
FORBIDDEN_REVERSION_PATTERNS = (
    (
        "Docker Swarm rollback",
        re.compile(r"\bdocker\s+service\s+rollback\b", re.IGNORECASE),
    ),
    (
        "Docker Swarm automatic rollback",
        re.compile(r"--update-failure-action\s+rollback\b", re.IGNORECASE),
    ),
    (
        "Docker Swarm rollback tuning",
        re.compile(r"--rollback-(?:order|parallelism|monitor)\b", re.IGNORECASE),
    ),
    ("Docker container rename swap", re.compile(r"\bdocker\s+rename\b", re.IGNORECASE)),
    (
        "Kubernetes rollout undo",
        re.compile(r"\bkubectl\s+rollout\s+undo\b", re.IGNORECASE),
    ),
    ("Helm rollback", re.compile(r"\bhelm\s+rollback\b", re.IGNORECASE)),
    (
        "Git history reversion",
        re.compile(r"\bgit\s+(?:revert|reset\s+--hard)\b", re.IGNORECASE),
    ),
    (
        "Ecto migrator downgrade",
        re.compile(r"\bEcto\.Migrator\.run\([^\n]*,?\s*:down\b"),
    ),
    (
        "Ecto schema-down callback",
        re.compile(r"(?m)^\s*def\s+down(?:\s+do|\s*,\s*do:)"),
    ),
    ("Oban schema downgrade", re.compile(r"\bOban\.Migration\.down\s*\(")),
    (
        "Entity Framework schema-down callback",
        re.compile(r"\boverride\s+void\s+Down\s*\(", re.IGNORECASE),
    ),
    ("Goose schema-down section", re.compile(r"(?im)^\s*--\s*\+goose\s+Down\b")),
    (
        "database schema downgrade command",
        re.compile(
            r"\b(?:alembic\s+downgrade|flask\s+db\s+downgrade|"
            r"rails\s+db:rollback|mix\s+ecto\.rollback|"
            r"liquibase\s+rollback|flyway\s+undo)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "database restore operation",
        re.compile(r"\bpg_restore\s+(?!--list\b)", re.IGNORECASE),
    ),
)


def tracked_utf8_sources():
    tracked = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        check=True,
        stdout=subprocess.PIPE,
    ).stdout
    for raw_relative in tracked.split(b"\0"):
        if not raw_relative:
            continue
        relative = Path(raw_relative.decode("utf-8"))
        path = ROOT / relative
        if path.resolve() == SELF:
            continue
        if any(part in GENERATED_OR_VENDOR_DIRS for part in relative.parts):
            continue
        if path.name in LOCK_FILE_NAMES or path.suffix == ".lock":
            continue
        data = path.read_bytes()
        if b"\0" in data:
            continue
        try:
            source = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        yield relative, source


SOURCE_ROOTS = (
    ROOT / ".github" / "workflows",
    ROOT / ".github" / "scripts",
    ROOT / "scripts",
)


def deployment_sources():
    for source_root in SOURCE_ROOTS:
        if not source_root.exists():
            continue
        for path in source_root.rglob("*"):
            if path.is_file() and path.suffix in {".yml", ".yaml", ".sh"}:
                yield path, path.read_text(encoding="utf-8")


class FailClosedDeployPolicyTests(unittest.TestCase):
    def test_every_tracked_utf8_surface_is_free_of_reversion_primitives(self):
        for path, source in tracked_utf8_sources():
            for label, pattern in FORBIDDEN_REVERSION_PATTERNS:
                self.assertIsNone(
                    pattern.search(source),
                    f"{label} remains in {path}",
                )

    def test_no_executable_rollback_primitives_remain(self):
        forbidden = (
            "docker service " + "rollback",
            "--update-failure-action " + "rollback",
            "--rollback-" + "order",
            "--rollback-" + "parallelism",
            "--rollback-" + "monitor",
        )
        for path, source in deployment_sources():
            for primitive in forbidden:
                self.assertNotIn(primitive, source, f"{primitive} remains in {path}")

    def test_every_service_update_explicitly_pauses_on_failure(self):
        for path, source in deployment_sources():
            lines = source.splitlines()
            for index, line in enumerate(lines):
                stripped = line.lstrip()
                if stripped.startswith("#") or "docker service update" not in line:
                    continue
                command_block = "\n".join(lines[index : index + 30])
                self.assertIn(
                    "--update-failure-action pause",
                    command_block,
                    f"service update can inherit a non-pause policy in {path}:{index + 1}",
                )

    def test_deployments_assert_exact_service_and_task_images(self):
        sources = "\n".join(source for _, source in deployment_sources())
        self.assertIn(".Spec.TaskTemplate.ContainerSpec.Image", sources)
        self.assertIn("{{.Image}}", sources)

    def test_tag_based_deployments_reject_bare_service_spec_tags(self):
        sources = "\n".join(source for _, source in deployment_sources())
        if "expected_digest=" not in sources and "EXPECTED_DIGEST=" not in sources:
            return
        strict_full_reference_checks = (
            '"${TAG}@${expected_digest}"',
            "'$TAG@'\\$expected_digest",
            '"${IMAGE_PATH}@${EXPECTED_DIGEST}"',
        )
        self.assertTrue(
            any(check in sources for check in strict_full_reference_checks),
            "tag-based service spec is not required to include its resolved digest",
        )
        self.assertNotIn('[ "$spec_image" = "$TAG" ]', sources)
        self.assertNotIn('[ "$SPEC_IMAGE" = "${IMAGE_PATH}" ]', sources)

    def test_each_reviewed_deploy_maps_tasks_to_actual_container_image_ids(self):
        workflows = (
            ROOT / ".github" / "workflows" / "deploy-to-jeeb.yml",
            ROOT / ".github" / "workflows" / "jeeb-staging-deploy.yml",
        )
        required = (
            "docker image inspect",
            "{{.Id}}",
            "{{.Status.ContainerStatus.ContainerID}}",
            "{{.Image}}",
        )
        for path in workflows:
            source = path.read_text(encoding="utf-8")
            for marker in required:
                self.assertIn(marker, source, f"{marker} missing from {path}")

    def test_release_exposes_no_schema_downgrade(self):
        source = (ROOT / "lib" / "offer_service" / "release.ex").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("def rollback", source)
        self.assertNotIn("Ecto.Migrator.run(&1, :down", source)


if __name__ == "__main__":
    unittest.main()
