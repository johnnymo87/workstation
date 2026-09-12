#!/usr/bin/env python3
"""Tests for monitor-rollout.py.

Run: python3 assets/opencode/skills/monitoring-deployments/test_monitor_rollout.py

Wired into CI as the `monitor-rollout` flake check (see flake.nix), which
invokes this file directly.

THE LOAD-BEARING CLAIM under test is how a pod's REVISION is judged.

`status.containerStatuses[].image` is not a fact about the pod -- it is a fact
about the kubelet's image cache. The kubelet reports whichever TAG it first
saw for a given DIGEST, so on reproducible builds (bazel) an image that did
not change between two commits keeps the older commit's tag in pod status
forever, while the pod is a member of the newest ReplicaSet and its spec names
the newest tag.

Measured on food-truck/mono, 2026-09-12 (merge adf1a60, superseded by
c092993): all three ba-fulfillment-service pods in ReplicaSet 846f965849 have
spec image `:c092993...` and imageID `sha256:d68597cae56b...`; ONE of them
reports status image `:adf1a60...`. An itemforecastconsumer pod in the
c092993 ReplicaSet reports status image `:adb33b1...`. Judging by the status
tag, the watcher reported "pods updating" for 30 hours against a rollout that
had completed, then declared the merge "still on the old tag".

So these tests pin: the pod's OWN SPEC image decides, in both directions. A
stale status tag must not hold a finished rollout open, and a matching status
tag must not pass a pod whose spec is still on the old revision.
"""

from __future__ import annotations

import importlib.util
import io
import json
import subprocess
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

# The script is `monitor-rollout.py` -- a hyphen, so it is not importable by
# name. Load it by path rather than renaming a file the SKILL.md, the lgtm
# watcher (LGTM_ROLLOUT_SCRIPT) and home-manager all address by that name.
_SPEC = importlib.util.spec_from_file_location(
    "monitor_rollout", Path(__file__).resolve().parent / "monitor-rollout.py"
)
mr = importlib.util.module_from_spec(_SPEC)
assert _SPEC.loader is not None
_SPEC.loader.exec_module(mr)


REPO = "food-truck/mono"
# The real SHAs from the incident, so a fixture cannot drift into a shape the
# cluster never produces.
OURS = "adf1a604e0ff86f1bd40cef9a117e0ba57c22455"
LATER = "c09299320924d327476a35066c886b179f83af27"
OLDER = "adb33b1feeba1cc4748dbfafeb3c7dcf975ee6f4"
IMG = "ftiuatacr.azurecr.io/wonder/blueapron/fulfillment/service"
DIGEST = "sha256:d68597cae56bc0f346b9066bf8f9db182f54791cdcb1dec39f46701583389453"

TARGET = "UAT:ctx:ns:ba-fulfillment-service"


def container(name, tag):
    return {"name": name, "image": f"{IMG}:{tag}"}


def status(name, tag, *, ready=True, restarts=0, waiting=None, digest=DIGEST):
    st = {
        "name": name,
        "image": f"{IMG}:{tag}",
        "imageID": f"{IMG}@{digest}",
        "ready": ready,
        "restartCount": restarts,
        "state": {"running": {}},
    }
    if waiting:
        st["state"] = {"waiting": {"reason": waiting}}
    return st


def pod(name, *, containers, statuses, phase="Running", conditions=None):
    """A pod as the API returns it.

    `conditions` defaults to the Ready condition a real kubelet would publish
    -- true only when EVERY container is ready. A fixture that omitted it
    would not be a pod kubernetes can produce, and the readiness assertions
    below would be testing a shape that never occurs.
    """
    if conditions is None:
        every = bool(statuses) and all(s.get("ready") for s in statuses)
        conditions = [{"type": "Ready", "status": "True" if every else "False"}]
    return {
        "metadata": {"name": name},
        "spec": {"containers": containers},
        "status": {
            "phase": phase,
            "containerStatuses": statuses,
            "conditions": conditions,
        },
    }


def pod_simple(name, spec_tag, status_tag, **kw):
    """The common single-container shape: spec says one tag, the kubelet
    reports another."""
    return pod(
        name,
        containers=[container("app", spec_tag)],
        statuses=[status("app", status_tag, **kw)],
    )


class FakeCluster:
    """A `run_cmd` stand-in covering the three commands the script issues:
    `kubectl get deploy`, `kubectl get pods`, and the `gh api` containment
    lookups."""

    def __init__(self, spec_tag, pods, *, later=LATER, ours=OURS):
        self.spec_tag = spec_tag
        self.pods = pods
        self.later = later
        self.ours = ours
        self.calls = []

    def __call__(self, cmd):
        self.calls.append(cmd)
        if cmd[0] == "kubectl" and "deploy" in cmd:
            return f"{IMG}:{self.spec_tag}"
        if cmd[0] == "kubectl" and "pods" in cmd:
            return json.dumps({"items": self.pods})
        if cmd[0] == "gh" and cmd[1] == "api":
            path = cmd[2]
            if "/commits/" in path:
                rev = path.rsplit("/", 1)[-1]
                for full in (self.later, self.ours, OLDER):
                    if full.startswith(rev):
                        return full
                raise subprocess.CalledProcessError(1, cmd, stderr="no such commit")
            if "/compare/" in path:
                base, head = path.rsplit("/", 1)[-1].split("...")
                if head == base:
                    return "identical"
                if head == self.later:
                    return "ahead"
                return "behind"
        raise AssertionError(f"unexpected command: {cmd}")


def evaluate(spec_tag, pods, *, short=None, merge_sha=OURS, targets=(TARGET,)):
    """Run one evaluate_rollout pass against a fake cluster, swallowing the
    script's progress output. Returns (exit_code, message, printed)."""
    fake = FakeCluster(spec_tag, list(pods))
    parsed = [mr.parse_target(t) for t in targets]
    buf = io.StringIO()
    original = mr.run_cmd
    mr.run_cmd = fake
    try:
        with redirect_stdout(buf):
            code, msg = mr.evaluate_rollout(
                parsed,
                short or merge_sha[: mr.SHORT_SHA_LEN],
                mr.DEFAULT_SELECTOR,
                merge_sha=merge_sha,
                repo=REPO,
            )
    finally:
        mr.run_cmd = original
    return code, msg, buf.getvalue()


def get_pods(pods):
    fake = FakeCluster(LATER, list(pods))
    original = mr.run_cmd
    mr.run_cmd = fake
    try:
        return mr.get_pods(mr.parse_target(TARGET), "app=x")
    finally:
        mr.run_cmd = original


class PodRevisionJudgement(unittest.TestCase):
    """The bug: which field decides that a pod is on the new revision."""

    def test_stale_status_tag_does_not_hide_a_finished_rollout(self):
        # The live ba-fulfillment-service-846f965849-psd9l shape: the pod is a
        # member of the current ReplicaSet and its spec names the new tag, but
        # the kubelet reports the tag it first cached for that digest.
        p = get_pods([pod_simple("psd9l", LATER, OURS)])[0]
        self.assertTrue(mr.on_target(p, LATER[: mr.SHORT_SHA_LEN]))

    def test_matching_status_tag_does_not_pass_an_old_revision_pod(self):
        # The inverse, and the reason this cannot be fixed by accepting EITHER
        # tag: an old-revision pod that happens to carry the new tag in status
        # is still an old-revision pod, and the rollout is still running.
        p = get_pods([pod_simple("old", OLDER, LATER)])[0]
        self.assertFalse(mr.on_target(p, LATER[: mr.SHORT_SHA_LEN]))

    def test_status_tag_and_digest_are_still_reported(self):
        # Judging by spec must not throw away what the kubelet said: the
        # digest is the evidence a human needs to see that the two tags name
        # the same image rather than a genuine mismatch.
        p = get_pods([pod_simple("psd9l", LATER, OURS)])[0]
        self.assertTrue(p["tag"].startswith(LATER))
        self.assertTrue(p["status_tag"].startswith(OURS))
        self.assertIn(DIGEST, p["image_id"])

    def test_container_status_is_matched_by_name_not_position(self):
        # containerStatuses is not ordered like spec.containers (the kubelet
        # sorts by name), so taking [0] from each can pair the app's spec tag
        # with a sidecar's readiness. Spec container [0] is "web"; the status
        # list puts "istio-proxy" first.
        p = get_pods([
            pod(
                "sidecar",
                containers=[container("web", LATER), container("istio-proxy", "1.20")],
                statuses=[
                    status("istio-proxy", "1.20", ready=True, restarts=0),
                    status("web", OURS, ready=False, restarts=7),
                ],
            )
        ])[0]
        self.assertTrue(p["tag"].startswith(LATER))   # from spec container "web"
        self.assertFalse(p["ready"])                  # from status "web", not the proxy
        self.assertEqual(7, p["restarts"])

    def test_readiness_comes_from_the_pods_ready_condition(self):
        # The app container being ready is NOT the pod being ready: a failing
        # sidecar keeps the pod out of the Service's endpoints. Readiness must
        # come from the pod-level condition, which is the same fact kube-proxy
        # routes on -- otherwise the script reports "rolled out & healthy"
        # over a pod receiving no traffic.
        p = get_pods([
            pod(
                "sidecar-down",
                containers=[container("app", LATER), container("istio-proxy", "1.20")],
                statuses=[
                    status("app", LATER, ready=True),
                    status("istio-proxy", "1.20", ready=False,
                           waiting="CrashLoopBackOff"),
                ],
            )
        ])[0]
        self.assertFalse(p["ready"])

    def test_a_wedged_sidecar_is_a_wedge(self):
        # ... and it must be actionable rather than an eternal "still
        # rolling": an unready pod nobody explains is exactly how this script
        # burned 30 hours the first time.
        p = get_pods([
            pod(
                "sidecar-down",
                containers=[container("app", LATER), container("istio-proxy", "1.20")],
                statuses=[
                    status("app", LATER, ready=True),
                    status("istio-proxy", "1.20", ready=False,
                           waiting="ImagePullBackOff"),
                ],
            )
        ])[0]
        self.assertIsNotNone(p["wedge_reason"])
        self.assertIn("ImagePullBackOff", p["wedge_reason"])
        self.assertIn("istio-proxy", p["wedge_reason"])

    def test_readiness_falls_back_to_the_container_when_conditions_are_absent(self):
        # A pod object truncated by a projection or an old API version still
        # has to yield an answer; fall back to the container we judged.
        p = get_pods([
            pod("bare", containers=[container("app", LATER)],
                statuses=[status("app", LATER, ready=True)], conditions=[])
        ])[0]
        self.assertTrue(p["ready"])

    def test_pod_with_no_container_status_yet_is_not_ready(self):
        # A just-created pod has a spec but no containerStatuses. It is on the
        # new revision (spec says so) and NOT ready, which is "still rolling".
        p = get_pods([pod("new", containers=[container("app", LATER)], statuses=[])])[0]
        self.assertTrue(mr.on_target(p, LATER[: mr.SHORT_SHA_LEN]))
        self.assertFalse(p["ready"])
        self.assertIsNone(p["status_tag"])

    def test_pod_with_no_spec_container_is_not_on_target(self):
        # Malformed/unreadable pod: fail to the safe side (still rolling),
        # never to "done".
        p = get_pods([{"metadata": {"name": "weird"}, "status": {"phase": "Running"}}])[0]
        self.assertFalse(mr.on_target(p, LATER[: mr.SHORT_SHA_LEN]))


class EvaluateRollout(unittest.TestCase):
    """End to end over one target, with the containment (exit 4) path live."""

    def test_exit_4_with_stale_status_tags_on_every_pod(self):
        # The incident, reduced: deployment bumped to a commit that contains
        # ours, all pods in the current ReplicaSet, two of three reporting a
        # stale tag. Before the fix this returned None ("pods updating") on
        # every poll until the 30h horizon expired.
        code, msg, _ = evaluate(LATER, [
            pod_simple("psd9l", LATER, OURS),
            pod_simple("q7vnq", LATER, LATER),
            pod_simple("4842f", LATER, OLDER),
        ])
        self.assertEqual(mr.EXIT_DEPLOYED_AS_ANCESTOR, code)
        self.assertIn("contains", msg)

    def test_exit_0_when_deployed_under_our_own_tag(self):
        code, msg, _ = evaluate(OURS, [pod_simple("a", OURS, OLDER)])
        self.assertEqual(mr.EXIT_ALL_MET, code)

    def test_still_rolling_while_an_old_revision_pod_survives(self):
        # The terminating old-revision pod keeps the rollout open, which is
        # the behaviour the fix must NOT loosen.
        code, msg, _ = evaluate(LATER, [
            pod_simple("new", LATER, LATER),
            pod_simple("old", OURS, OURS),
        ])
        self.assertIsNone(code)
        self.assertIn("pods updating", msg)

    def test_wedged_is_judged_on_the_new_revision_by_spec_tag(self):
        code, msg, _ = evaluate(LATER, [
            pod_simple("bad", LATER, LATER, ready=False, waiting="CrashLoopBackOff"),
        ])
        self.assertEqual(mr.EXIT_ACTION_NEEDED, code)
        self.assertIn("CrashLoopBackOff", msg)

    def test_old_revision_crashloop_is_not_this_rollouts_wedge(self):
        code, msg, _ = evaluate(LATER, [
            pod_simple("new", LATER, LATER),
            pod_simple("pre-existing", OLDER, OLDER, ready=False, waiting="CrashLoopBackOff"),
        ])
        self.assertIsNone(code)

    def test_a_new_revision_pod_stuck_on_imagepull_is_wedged(self):
        # A pod whose image never pulled reports NO usable status image -- the
        # kubelet has nothing cached to name. The spec tag is the only thing
        # that identifies it as THIS rollout's pod, so under the old code this
        # wedge was invisible and the rollout idled to the horizon instead of
        # exiting 1.
        p = pod(
            "pulling",
            containers=[container("app", LATER)],
            statuses=[{
                "name": "app", "image": "", "imageID": "",
                "ready": False, "restartCount": 0,
                "state": {"waiting": {"reason": "ImagePullBackOff"}},
            }],
        )
        code, msg, _ = evaluate(LATER, [p])
        self.assertEqual(mr.EXIT_ACTION_NEEDED, code)
        self.assertIn("ImagePullBackOff", msg)

    def test_output_flags_the_tag_the_kubelet_reported(self):
        # Diagnosability: a reader seeing "on target" against a pod whose
        # status says otherwise must be told why.
        _, _, printed = evaluate(LATER, [pod_simple("psd9l", LATER, OURS)])
        self.assertIn(OURS[: mr.SHORT_SHA_LEN], printed)
        self.assertIn("kubelet", printed.lower())


class SpecImageTag(unittest.TestCase):
    def test_deployment_spec_tag_is_read_from_the_first_container(self):
        fake = FakeCluster(LATER, [])
        original = mr.run_cmd
        mr.run_cmd = fake
        try:
            self.assertEqual(LATER, mr.get_spec_image_tag(mr.parse_target(TARGET)))
        finally:
            mr.run_cmd = original

    def test_image_tag_handles_registry_port_and_digest_pins(self):
        self.assertEqual("abc1234_0", mr.image_tag("r.example.com/team/svc:abc1234_0"))
        self.assertEqual("abc1234", mr.image_tag("localhost:5000/svc:abc1234"))
        self.assertIsNone(mr.image_tag("registry/svc@sha256:deadbeef"))
        self.assertIsNone(mr.image_tag(""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
