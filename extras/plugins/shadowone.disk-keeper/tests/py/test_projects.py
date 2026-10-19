import os
import subprocess
import unittest

from helpers import FakeHome

from diskkeeper import paths, projects, registry


def git(cwd, *args):
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "-C", cwd] + list(args),
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class Projects(FakeHome):
    def setUp(self):
        super().setUp()
        repo = self.h("Projects/web")
        self.make("Projects/web/package.json", b"{}")
        self.make("Projects/web/.gitignore", b"node_modules/\n.next/\n")
        self.make("Projects/web/src/lib/build/stub.ts", b"export {}")   # committed source named build
        self.make("Projects/web/dist/app.js", b"x")                     # committed dist
        self.make("Projects/web/node_modules/pkg/index.js")
        self.make("Projects/web/.next/cache/x")
        git(repo, "init", "-q")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "init")
        self.make("Projects/loose/package.json", b"{}")
        self.make("Projects/loose/node_modules/a")
        self.make("Projects/loose/build/out")                            # no git proof
        self.make("Projects/nomarker/node_modules/a")

    def collect(self):
        return projects.collect(registry.Context(paths.load_config()))

    def items(self):
        return {i["key"]: i for p in self.collect()["projects"] for i in p["items"]}

    def test_git_rules(self):
        items = self.items()
        self.assertTrue(items["Projects/web/node_modules"]["eligible"])
        self.assertTrue(items["Projects/web/.next"]["eligible"])
        self.assertEqual(items["Projects/web/src/lib/build"]["reason"], "tracked-by-git")
        self.assertEqual(items["Projects/web/dist"]["reason"], "tracked-by-git")

    def test_rules_outside_git(self):
        items = self.items()
        self.assertTrue(items["Projects/loose/node_modules"]["eligible"])
        self.assertEqual(items["Projects/loose/build"]["reason"], "no-git-proof")
        self.assertEqual(items["Projects/nomarker/node_modules"]["reason"], "no-project-marker")

    def test_clean_refuses_ineligible_keys(self):
        cat = projects.ProjectsCategory()
        res = cat.clean(registry.Context(paths.load_config(), job="t"),
                        ["Projects/web/node_modules", "Projects/web/dist", "Projects/web/src/lib/build"], {})
        status = {r["target"]: r["status"] for r in res}
        self.assertEqual(status["projects:Projects/web/node_modules"], "done")
        self.assertEqual(status["projects:Projects/web/dist"], "skipped")
        self.assertTrue(os.path.exists(self.h("Projects/web/dist/app.js")))
        self.assertTrue(os.path.exists(self.h("Projects/web/src/lib/build/stub.ts")))
        self.assertFalse(os.path.exists(self.h("Projects/web/node_modules")))

    def test_fresh_project_not_preselected(self):
        items = self.items()
        self.assertFalse(items["Projects/web/node_modules"]["selected"])


if __name__ == "__main__":
    unittest.main()
