"""Guard the public workflow boundary using only checked-in synthetic metadata."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PublicDeliveryTests(unittest.TestCase):
    def test_ci_never_receives_signing_secrets(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertNotIn('secrets.', workflow)
        self.assertNotIn('pull_request_target', workflow)

    def test_every_action_is_pinned_to_a_commit(self):
        for path in (ROOT / '.github/workflows').glob('*.yml'):
            for action in re.findall(r'uses:\s*([^\s#]+)', path.read_text()):
                self.assertRegex(action, r'^[\w/-]+@[a-f0-9]{40}$')

    def test_testflight_credentials_are_step_scoped(self):
        workflow = (ROOT / '.github/workflows/testflight.yml').read_text()
        boundary = workflow.index('- name: Upload internal TestFlight build')
        self.assertNotIn('secrets.', workflow[:boundary])
        self.assertNotIn('upload-artifact', workflow)
        self.assertIn("github.ref == 'refs/heads/main'", workflow)
        self.assertIn('environment: testflight', workflow)
        self.assertIn('workflow_dispatch:', workflow)

    def test_four_stages_keep_setup_explicit_and_secrets_scoped(self):
        for file in ('validate_secrets.yml', 'add_identifiers.yml', 'create_profiles.yml'):
            text = (ROOT / '.github/workflows' / file).read_text()
            boundary = text.index('- name: Run protected setup operation')
            self.assertNotIn('secrets.', text[:boundary])
            self.assertIn('environment: testflight', text)
            self.assertIn("github.ref == 'refs/heads/main'", text)
            self.assertNotIn('upload-artifact', text)
        setup = (ROOT / '.github/workflows/create_profiles.yml').read_text()
        self.assertIn('default: check', setup)
        self.assertIn('prepare_profiles', setup)
        upload = (ROOT / '.github/workflows/testflight.yml').read_text()
        self.assertIn('Scripts/verify_delivery_ci.py', upload)
        self.assertIn('release_gates_confirmed:', upload)
        self.assertIn('default: false', upload)

    def test_both_targets_share_expanded_runtime_configuration(self):
        import plistlib
        app = plistlib.loads((ROOT / 'Config/InsulinOCR-Info.plist').read_bytes())
        share = plistlib.loads((ROOT / 'Config/InsulinOCRShareExtension-Info.plist').read_bytes())
        self.assertEqual(app['InsulinOCRAppGroup'], '$(INSULINOCR_APP_GROUP)')
        self.assertEqual(app['InsulinOCRAppGroup'], share['InsulinOCRAppGroup'])
        self.assertEqual(app['InsulinOCRCloudKitContainer'], '$(INSULINOCR_CLOUDKIT_CONTAINER)')
        for path in ('InsulinOCR/InsulinOCR.entitlements', 'ShareExtension/InsulinOCRShareExtension.entitlements'):
            entitlement = plistlib.loads((ROOT / path).read_bytes())
            self.assertEqual(entitlement['com.apple.security.application-groups'], ['$(INSULINOCR_APP_GROUP)'])

    def test_no_private_runtime_override_is_tracked(self):
        import subprocess
        files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
        self.assertNotIn('Config/Local.generated.xcconfig', files)
        self.assertFalse(any(path.endswith('.build-config.json') for path in files))


if __name__ == '__main__':
    unittest.main()
