from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
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
        source = (ROOT / "lib" / "offer_service" / "release.ex").read_text(encoding="utf-8")
        self.assertNotIn("def rollback", source)
        self.assertNotIn("Ecto.Migrator.run(&1, :down", source)


if __name__ == "__main__":
    unittest.main()
