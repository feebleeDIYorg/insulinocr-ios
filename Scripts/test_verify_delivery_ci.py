import unittest
from verify_delivery_ci import verified_ci_run

class DeliveryCITests(unittest.TestCase):
    def setUp(self):
        self.sha = "a" * 40
        self.repo = "synthetic/app"
        self.run = dict(id=12, run_number=7, run_attempt=1, head_sha=self.sha,
                        head_branch="main", event="push", head_repository={"full_name": self.repo},
                        status="completed", conclusion="success")

    def test_accepts_exact_main_success(self):
        self.assertEqual(verified_ci_run({"workflow_runs": [self.run]}, self.sha, self.repo), 12)

    def test_rejects_wrong_head_fork_or_pull_request(self):
        for changes in [dict(head_sha="b" * 40), dict(head_branch="other"), dict(event="pull_request"),
                        dict(head_repository={"full_name": "fork/app"}), dict(conclusion="skipped"),
                        dict(conclusion="failure"), dict(status="in_progress")]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                verified_ci_run({"workflow_runs": [self.run | changes]}, self.sha, self.repo)

    def test_old_green_cannot_hide_new_failed_or_running_attempt(self):
        for changes in [dict(run_attempt=2, conclusion="failure"),
                        dict(run_number=8, status="in_progress", conclusion=None)]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                verified_ci_run({"workflow_runs": [self.run, self.run | changes]}, self.sha, self.repo)

    def test_no_run_and_malformed_sha_fail(self):
        for payload, sha in [({}, self.sha), ({"workflow_runs": [self.run]}, "not-a-sha")]:
            with self.assertRaises(ValueError):
                verified_ci_run(payload, sha, self.repo)
