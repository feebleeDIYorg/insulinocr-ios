"""Require successful CI for the exact main commit; never launch or waive tests."""
import json
import os
import re
import urllib.request


def verified_ci_run(payload, sha, repository):
    if not re.fullmatch(r"[a-f0-9]{40}", sha):
        raise ValueError("Invalid source revision")
    runs = [r for r in payload.get("workflow_runs", [])
            if r.get("head_sha") == sha and r.get("head_branch") == "main"
            and r.get("event") == "push" and r.get("head_repository", {}).get("full_name") == repository]
    if not runs:
        raise ValueError("No matching main CI")
    latest = max(runs, key=lambda r: (r.get("run_number", 0), r.get("run_attempt", 0)))
    if latest.get("status") != "completed" or latest.get("conclusion") != "success":
        raise ValueError("Current main CI has not passed")
    return latest["id"]


def main():
    repository = os.environ["GITHUB_REPOSITORY"]
    sha = os.environ["GITHUB_SHA"]
    if os.environ["GITHUB_REF"] != "refs/heads/main" or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Main source required")
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}/actions/workflows/ci.yml/runs?head_sha={sha}&per_page=100",
        headers={"Authorization": "Bearer " + os.environ["GITHUB_TOKEN"],
                 "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        run_id = verified_ci_run(json.load(response), sha, repository)
    with open(os.environ["GITHUB_ENV"], "a") as file:
        file.write(f"INSULINOCR_VERIFIED_CI_HEAD={sha}\n")
    print(f"Exact main commit passed CI (run {run_id}); no tests skipped or restarted.")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        raise SystemExit("Delivery blocked: successful CI for this exact main commit is required.")
