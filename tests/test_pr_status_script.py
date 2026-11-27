"""scripts/pr-status.sh and scripts/merge-ticket.sh: what the ticket loop does next
with a ticket PR; and scripts/start-ticket.sh's check for the mattpocock-skills plugin.

`gh` is a fake on PATH: `gh pr view` prints the PR JSON a test writes, `gh api graphql`
prints the ticket's labels (already in the shape the script's --jq makes), and every call
is logged, so these tests run offline."""

import json
import os
import stat
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
PR_STATUS = ROOT / "scripts" / "pr-status.sh"
MERGE_TICKET = ROOT / "scripts" / "merge-ticket.sh"

HEAD = "def5678" + "0" * 33
OLD = "abc1234" + "0" * 33

FAKE_GH = """#!/usr/bin/env bash
echo "gh $*" >> "$FAKE_LOG"
case "$1 $2" in
  "--version "*) echo "gh version 2.105.0 (2026-11-17)" ;;
  "api user") echo "karn-bot" ;;
  "repo view") echo "${FAKE_REPO:-engi-ai/knowledge-pool}" ;;
  "pr view")
    if [ -f "$FAKE_PR.$3" ]; then cat "$FAKE_PR.$3"; else cat "$FAKE_PR"; fi ;;
  "pr list") cat "$FAKE_LIST" ;;
  "extension list") cat "$FAKE_EXT" ;;
  "api graphql")
    case "$*" in
      *mergeQueue*) [ "$(cat "$FAKE_QUEUE")" = FAIL ] && exit 1; cat "$FAKE_QUEUE" ;;
      *subIssues*) cat "$FAKE_STACK" ;;
      *"parent{ title }"*) cat "$FAKE_SPEC" ;;
      *) cat "$FAKE_TICKET" ;;
    esac ;;
  "issue view")
    case "$*" in *title*) echo "A ticket" ;; *) echo "OPEN" ;; esac ;;
  "issue edit"|"issue close"|"issue develop"|"pr merge"|"pr edit"|"pr comment"|"stack merge") ;;
  "project field-list") printf 'Backlog\nIn progress\nDone\n' ;;
  "project item-add"|"project item-edit") ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
"""


def body(describes=HEAD[:7], drop=()):
    parts = {
        "ticket": "Ticket: #42",
        "summary": "## Summary\n\nA change.",
        "evidence": f"## Evidence\n\n- **Before:** x\n  **After:** y\n\nDescribes: `{describes}`"
        if describes
        else "## Evidence\n\n- **Before:** x\n  **After:** y",
        "danger": "## Merge Danger\n\n**Door:** two-way\n\n**Blast Radius:** orchestrator",
    }
    return "\n\n".join(v for k, v in parts.items() if k not in drop)


NO_STACK = {"data": {"repository": {"issue": {"parent": None}}}}


def review(sha, k=1):
    return {"body": f"## Code review, round {k}\n\nReviewed head `{sha[:7]}`.\n\n## Standards\n\nNone."}


def pr(**over):
    base = {
        "number": 7,
        "url": "https://github.com/DaveParr/knowledge-pool/pull/7",
        "state": "OPEN",
        "isDraft": False,
        "baseRefName": "main",
        "headRefOid": HEAD,
        "mergeable": "MERGEABLE",
        "labels": [],
        "body": body(),
        "closingIssuesReferences": [{"number": 42}],
        "comments": [review(HEAD)],
        "statusCheckRollup": [
            {"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS",
             "detailsUrl": "https://example.invalid/run"}
        ],
    }
    base.update(over)
    return base


@pytest.fixture
def env(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    gh = bin_dir / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
    (tmp_path / "ticket.json").write_text(json.dumps({"ticket": [], "parent": None, "parentLabels": []}))
    (tmp_path / "list.json").write_text("[]")
    (tmp_path / "ext.txt").write_text("gh stack\tgithub/gh-stack\tv0.1\n")
    (tmp_path / "queue.txt").write_text("")
    (tmp_path / "stack.json").write_text(json.dumps(NO_STACK))
    (tmp_path / "spec.txt").write_text("")
    return {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "FAKE_LOG": str(tmp_path / "gh.log"),
        "FAKE_PR": str(tmp_path / "pr.json"),
        "FAKE_TICKET": str(tmp_path / "ticket.json"),
        "FAKE_LIST": str(tmp_path / "list.json"),
        "FAKE_EXT": str(tmp_path / "ext.txt"),
        "FAKE_QUEUE": str(tmp_path / "queue.txt"),
        "FAKE_STACK": str(tmp_path / "stack.json"),
        "FAKE_SPEC": str(tmp_path / "spec.txt"),
    }


def status(env, **over):
    Path(env["FAKE_PR"]).write_text(json.dumps(pr(**over)))
    out = subprocess.run([str(PR_STATUS), "7"], env=env, capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def test_a_reviewed_described_green_pr_merges(env):
    s = status(env)
    assert (s["next"], s["bodyMissing"], s["bodyDescribes"]) == ("merge", [], HEAD[:7])


@pytest.mark.parametrize(
    "drop, missing",
    [
        (("summary",), "## Summary"),
        (("evidence",), "## Evidence"),
        (("danger",), "## Merge Danger, **Door:**, **Blast Radius:**"),
    ],
)
def test_a_body_without_the_pr_template_goes_back_to_the_worker(env, drop, missing):
    s = status(env, body=body(drop=drop))
    assert s["next"] == "pr-body"
    assert missing in s["reason"]


def test_a_body_describing_an_older_commit_goes_back_to_the_worker(env):
    s = status(env, body=body(describes=OLD[:7]))
    assert s["next"] == "pr-body"
    assert s["reason"] == f"PR body describes {OLD[:7]}, head is {HEAD[:7]}"


def test_a_body_with_no_describes_line_goes_back_to_the_worker(env):
    s = status(env, body=body(describes=None))
    assert (s["next"], s["reason"]) == ("pr-body", "PR body has no Describes: <sha> line")


def test_a_full_describes_sha_counts(env):
    assert status(env, body=body(describes=HEAD))["next"] == "merge"


def test_the_body_check_comes_before_conflicts_and_ci(env):
    failing = [{"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "FAILURE",
                "detailsUrl": "x"}]
    s = status(env, body=body(describes=OLD[:7]), mergeable="CONFLICTING", statusCheckRollup=failing)
    assert s["next"] == "pr-body"


def test_a_stale_review_is_reported_before_a_stale_body(env):
    s = status(env, body=body(describes=OLD[:7]), comments=[review(OLD)])
    assert s["next"] == "review"


def test_the_body_check_never_overrides_merged_or_the_round_limit(env):
    bad = body(drop=("summary",))
    assert status(env, body=bad, state="MERGED")["next"] == "merged"
    rounds = [review(OLD), review(OLD), review(HEAD)]
    assert status(env, body=bad, comments=rounds)["next"] == "round-limit"


def test_merge_ticket_refuses_a_pr_whose_body_is_stale(env):
    Path(env["FAKE_PR"]).write_text(json.dumps(pr(body=body(describes=OLD[:7]))))
    out = subprocess.run([str(MERGE_TICKET), "7"], env=env, capture_output=True, text=True)
    assert out.returncode == 1
    assert "next is 'pr-body'" in out.stderr
    assert "pr merge" not in Path(env["FAKE_LOG"]).read_text()


START_TICKET = ROOT / "scripts" / "start-ticket.sh"


@pytest.mark.parametrize(
    "plugins, installed",
    [("[]", False), ('[{"id": "superpowers@claude-plugins-official"}]', False),
     ('[{"id": "mattpocock-skills@mattpocock", "enabled": false}]', True)],
)
def test_start_ticket_stops_before_claiming_when_the_plugin_is_missing(env, tmp_path, plugins, installed):
    claude = Path(env["PATH"].split(":")[0]) / "claude"
    claude.write_text(f"#!/usr/bin/env bash\necho '{plugins}'\n")
    claude.chmod(claude.stat().st_mode | stat.S_IEXEC)
    Path(env["FAKE_PR"]).write_text("{}")
    out = subprocess.run([str(START_TICKET), "42"], env=env, capture_output=True, text=True)
    assert out.returncode != 0  # the fake gh cannot claim, so it stops either way
    log = Path(env["FAKE_LOG"]).read_text()
    if installed:
        assert "issue view" in log  # got past the check, even though disabled at user scope
    else:
        assert "claude plugin install mattpocock-skills@mattpocock" in out.stderr
        assert "issue" not in log


GH_LIB = ROOT / "scripts" / "lib" / "gh.sh"


def sh(env, snippet, **extra):
    return subprocess.run(["bash", "-c", f'source "{GH_LIB}"; {snippet}'], env={**env, **extra},
                          capture_output=True, text=True)


def test_the_repo_is_read_from_gh_not_hard_coded(env):
    out = sh(env, 'echo "$GH_REPO $REPO_OWNER $REPO_NAME"', FAKE_REPO="acme/widgets")
    assert out.stdout.strip() == "acme/widgets acme widgets"


def test_the_board_is_the_org_project_by_default_and_both_settings_can_be_overridden(env):
    assert sh(env, 'echo "$BOARD_OWNER $BOARD_NUMBER"').stdout.strip() == "engi-ai 1"
    out = sh(env, 'echo "$BOARD_OWNER $BOARD_NUMBER"', KP_BOARD_OWNER="someone", KP_BOARD_NUMBER="9")
    assert out.stdout.strip() == "someone 9"


def test_board_calls_go_to_the_org_project(env):
    out = sh(env, 'board_move 5 "In progress"', FAKE_REPO="acme/widgets")
    assert out.returncode == 0, out.stderr
    projects = [l for l in Path(env["FAKE_LOG"]).read_text().splitlines() if l.startswith("gh project")]
    assert projects and all("--owner engi-ai" in l and " 1 " in l for l in projects)
    assert "https://github.com/acme/widgets/issues/5" in "".join(projects)


def test_pr_status_asks_graphql_about_the_repo_gh_reports(env):
    Path(env["FAKE_PR"]).write_text(json.dumps(pr()))
    subprocess.run([str(PR_STATUS), "7"], env={**env, "FAKE_REPO": "acme/widgets"}, capture_output=True, check=True)
    assert "owner=acme" in Path(env["FAKE_LOG"]).read_text()


# --- stacks, no checks, responses -------------------------------------------------------

LOW, LOW_BRANCH = 5, "karn/41-below"


def stacked(env, *, low_state="OPEN", low_next_ok=True, **over):
    """PR 7 sits on the branch of PR 5; PR 5 targets main. Returns pr-status for PR 7."""
    stacked_setup(env, low_state=low_state, low_next_ok=low_next_ok)
    return status(env, baseRefName=LOW_BRANCH, **over)


def test_a_pr_on_the_branch_of_a_ready_lower_pr_is_not_held(env):
    s = stacked(env)
    assert s["next"] == "merge"
    assert s["stack"]["position"] == 2
    assert s["stack"]["lower"] == [{"pr": LOW, "ticket": 41, "state": "OPEN", "next": "merge"}]
    assert s["stack"]["lowerReady"] is True


def test_a_pr_waits_for_a_lower_pr_that_is_not_ready(env):
    s = stacked(env, low_next_ok=False)
    assert s["next"] == "blocked-by-lower"
    assert s["stack"]["lowerReady"] is False
    assert f"#{LOW}" in s["reason"]


def test_a_pr_above_a_merged_lower_pr_counts_it_as_ready(env):
    s = stacked(env, low_state="MERGED")
    assert (s["next"], s["stack"]["lowerReady"]) == ("merge", True)


def test_a_pr_whose_base_is_no_prs_branch_is_still_held(env):
    s = status(env, baseRefName="somewhere-else")
    assert s["next"] == "hold"
    assert "somewhere-else" in s["reason"]


def test_a_pr_into_main_is_position_one_of_its_own_stack(env):
    s = status(env)
    assert s["stack"] == {"position": 1, "lower": [], "lowerReady": True, "trunk": "main"}


def test_conflicts_and_failures_are_still_reported_before_waiting_for_the_pr_below(env):
    s = stacked(env, low_next_ok=False, mergeable="CONFLICTING")
    assert s["next"] == "conflict"


def test_no_checks_at_all_is_its_own_state_not_pending_for_ever(env):
    s = status(env, statusCheckRollup=[])
    assert s["ci"] == "none"
    assert s["next"] == "no-checks"
    assert "no CI checks" in s["reason"]


def comment(text):
    return {"body": text}


def test_responses_are_complete_when_every_round_has_its_response(env):
    rounds = [review(OLD), comment("## Round 1 response\n\n- Standards 1: fixed in abc."),
              review(HEAD, 2), comment("## Round 2 response\n\nNothing to fix.")]
    s = status(env, comments=rounds)
    assert s["responsesComplete"] is True


def test_a_round_without_its_response_is_incomplete(env):
    rounds = [{"body": "## Code review, round 1\n\nhead `abc1234`"}, comment("## Round 1 response\n\nok"),
              {"body": f"## Code review, round 2\n\nhead `{HEAD[:7]}`"}]
    assert status(env, comments=rounds)["responsesComplete"] is False


def test_a_response_for_another_round_does_not_count(env):
    rounds = [review(HEAD), comment("## Round 2 response\n\nok")]
    assert status(env, comments=rounds)["responsesComplete"] is False


# --- start-ticket.sh: stacks, the extension check, the branch check before the claim ------


def sibling(number, branch=None, pr=None, state="OPEN"):
    """A sub-issue of the ticket's spec: a linked branch, an open PR (head, base), or both."""
    return {
        "number": number,
        "state": state,
        "linkedBranches": {"nodes": [{"ref": {"name": branch}}] if branch else []},
        "closedByPullRequestsReferences": {
            "nodes": [{"headRefName": pr[0], "baseRefName": pr[1], "state": "OPEN"}] if pr else []},
    }


def spec_with(env, *siblings):
    nodes = {"subIssues": {"nodes": list(siblings)}}
    Path(env["FAKE_STACK"]).write_text(json.dumps({"data": {"repository": {"issue": {"parent": nodes}}}}))


def top(env):
    out = sh(env, "stack_top_branch 42")
    assert out.returncode == 0, out.stderr
    return out.stdout.strip()


def test_a_ticket_without_a_spec_has_no_stack(env):
    assert top(env) == ""


def test_the_top_of_the_specs_stack_is_the_branch_nothing_is_based_on(env):
    spec_with(env, sibling(41, pr=("k/41-a", "main")), sibling(43, pr=("k/43-c", "k/41-a")),
              sibling(44, pr=("k/44-d", "k/43-c")))
    assert top(env) == "k/44-d"


def test_tickets_that_are_closed_or_this_one_are_not_in_the_stack(env):
    spec_with(env, sibling(41, pr=("k/41-a", "main"), state="CLOSED"), sibling(42, branch="k/42-me"))
    assert top(env) == ""


def test_two_open_branches_with_nothing_to_order_them_stop_the_script(env):
    spec_with(env, sibling(41, branch="k/41-a"), sibling(43, branch="k/43-b"))
    out = sh(env, "stack_top_branch 42")
    assert out.returncode != 0 and "k/41-a" in out.stderr and "k/43-b" in out.stderr


def test_a_started_ticket_with_only_a_branch_is_the_top_when_it_is_alone(env):
    spec_with(env, sibling(41, branch="k/41-a"))
    assert top(env) == "k/41-a"


@pytest.fixture
def started(env, tmp_path):
    """A checkout with a local `origin`, and fake claude and orca on PATH."""
    origin = tmp_path / "origin.git"
    work = tmp_path / "work"
    git = lambda *a, cwd=work: subprocess.run(["git", *a], cwd=cwd, check=True, capture_output=True)
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origin)], check=True)
    subprocess.run(["git", "clone", "-q", str(origin), str(work)], check=True, capture_output=True)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init")
    git("push", "-q", "origin", "HEAD:main")
    git("push", "-q", "origin", "HEAD:refs/heads/k/41-a")
    bin_dir = Path(env["PATH"].split(":")[0])
    for name, body_ in {
        "claude": "echo '[{\"id\": \"mattpocock-skills@mattpocock\"}]'",
        "orca": 'echo "orca $*" >> "$FAKE_LOG"; [ "$2" = list ] && echo \'{"result":{"worktrees":[]}}\'; exit 0',
    }.items():
        f = bin_dir / name
        f.write_text(f"#!/usr/bin/env bash\n{body_}\n")
        f.chmod(0o755)
    return {**env, "ORCA_CLI_COMMAND": str(bin_dir / "orca")}, work, origin


def start(started):
    env, work, _ = started
    return subprocess.run([str(START_TICKET), "42"], env=env, cwd=work, capture_output=True, text=True)


def log(started):
    return Path(started[0]["FAKE_LOG"]).read_text()


def test_start_ticket_needs_the_gh_stack_extension_before_it_claims(started):
    Path(started[0]["FAKE_EXT"]).write_text("gh copilot\tgithub/gh-copilot\n")
    out = start(started)
    assert out.returncode != 0
    assert "gh extension install github/gh-stack" in out.stderr
    assert "issue edit" not in log(started)


def test_start_ticket_stops_before_claiming_when_the_branch_is_on_origin(started):
    env, work, origin = started
    subprocess.run(["git", "push", "-q", "origin", "HEAD:refs/heads/karn-bot/42-a-ticket"], cwd=work, check=True)
    out = start(started)
    assert out.returncode != 0
    assert "karn-bot/42-a-ticket" in out.stderr and "already on origin" in out.stderr
    assert "delete" not in out.stderr.lower() and "remove" not in out.stderr.lower()
    assert "issue edit" not in log(started) and "project item" not in log(started)


def test_a_ticket_of_a_spec_with_a_stack_is_based_on_its_top_branch(started):
    spec_with(started[0], sibling(41, pr=("k/41-a", "main")))
    start(started)
    assert "--base-branch origin/k/41-a" in log(started)


def test_a_ticket_with_no_stack_is_based_on_main(started):
    start(started)
    assert "--base-branch origin/main" in log(started)


# --- merge-ticket.sh: direct, stack and queue modes --------------------------------------


def merge(env, stack=False, low_state="OPEN", **over):
    if stack:
        stacked_setup(env, low_state=low_state)
        over["baseRefName"] = LOW_BRANCH
    Path(env["FAKE_PR"]).write_text(json.dumps(pr(**over)))
    return subprocess.run([str(MERGE_TICKET), "7"], env=env, capture_output=True, text=True)


def stacked_setup(env, low_state="OPEN", low_next_ok=True, low_base="main"):
    Path(env["FAKE_LIST"]).write_text(json.dumps([{"number": LOW, "state": low_state}]))
    low = pr(number=LOW, baseRefName=low_base, state=low_state,
             comments=[review(HEAD)] if low_next_ok else [], body=body().replace("#42", "#41"))
    Path(env["FAKE_PR"] + f".{LOW}").write_text(json.dumps(low))


def calls(env):
    return Path(env["FAKE_LOG"]).read_text().splitlines()


def test_without_a_queue_a_pr_into_main_merges_directly_and_closes_its_ticket(env):
    out = merge(env)
    assert out.returncode == 0, out.stderr
    log = calls(env)
    assert f"gh pr merge 7 --merge --match-head-commit {HEAD}" in log
    assert any(l.startswith("gh issue close 42") for l in log)
    assert any(l.startswith("gh pr comment 7") and "Merged automatically" in l for l in log)


def test_a_stacked_pr_merges_through_gh_stack_and_lands_the_ones_below(env):
    out = merge(env, stack=True)
    assert out.returncode == 0, out.stderr
    log = calls(env)
    assert "gh stack merge 7 --yes --merge" in log
    assert not any(l.startswith("gh pr merge") for l in log)
    closed = [l.split()[3] for l in log if l.startswith("gh issue close")]
    assert sorted(closed) == ["41", "42"]


def test_with_a_merge_queue_the_pr_is_enqueued_and_nothing_is_closed_yet(env):
    Path(env["FAKE_QUEUE"]).write_text("MQ_123\n")
    out = merge(env)
    assert out.returncode == 0, out.stderr
    log = calls(env)
    assert any(l.startswith("gh pr merge 7") for l in log)
    assert not any(l.startswith("gh issue close") for l in log)
    assert not any("Merged" in l for l in log if l.startswith("gh pr comment"))
    assert any(l.startswith("gh pr comment 7") and "merge queue" in l for l in log)
    assert "queued #7" in out.stdout


def test_a_queued_stack_goes_through_gh_stack_and_the_queue_picks_the_method(env):
    Path(env["FAKE_QUEUE"]).write_text("MQ_123\n")
    out = merge(env, stack=True)
    assert out.returncode == 0, out.stderr
    log = calls(env)
    assert "gh stack merge 7 --yes" in log
    assert not any(l.startswith("gh issue close") for l in log)


def test_merging_never_deletes_a_branch(env):
    for queue in ("", "MQ_123\n"):
        Path(env["FAKE_QUEUE"]).write_text(queue)
        merge(env)
        merge(env, stack=True)
    assert "delete" not in Path(env["FAKE_LOG"]).read_text()



def test_a_pr_still_based_on_a_merged_lower_branch_goes_through_gh_stack(env):
    out = merge(env, stack=True, low_state="MERGED")
    assert out.returncode == 0, out.stderr
    log = calls(env)
    assert "gh stack merge 7 --yes --merge" in log
    assert not any(l.startswith("gh pr merge") for l in log)


def test_a_failing_merge_queue_lookup_stops_the_merge(env):
    Path(env["FAKE_QUEUE"]).write_text("FAIL")
    out = merge(env)
    assert out.returncode != 0
    assert not any(l.startswith(("gh pr merge", "gh stack merge")) for l in calls(env))


def test_the_extension_check_survives_a_gh_that_stops_writing_early(started):
    Path(started[0]["FAKE_EXT"]).write_text("gh stack\tgithub/gh-stack\n" * 20000)
    start(started)
    assert "issue edit" in log(started)


def test_a_siblings_branch_whose_pr_is_merged_is_not_in_the_stack(env):
    merged = sibling(41, branch="k/41-a", pr=("k/41-a", "main"))
    merged["closedByPullRequestsReferences"]["nodes"][0]["state"] = "MERGED"
    spec_with(env, merged, sibling(43, pr=("k/43-b", "main")))
    assert top(env) == "k/43-b"


def test_a_draft_or_human_held_pr_with_no_checks_is_held_not_rerun(env):
    assert status(env, statusCheckRollup=[], isDraft=True)["next"] == "hold"
    held = status(env, statusCheckRollup=[], labels=[{"name": "review-by-human"}])
    assert held["next"] == "hold"


# --- spec branches: a spec's stack sits on spec/<name>, which reaches main in one PR ------

SPEC = "spec/installable-phone-app"


def test_a_pr_into_a_spec_branch_is_the_bottom_of_its_stack_and_may_merge(env):
    s = status(env, baseRefName=SPEC)
    assert s["next"] == "merge"
    assert s["stack"] == {"position": 1, "lower": [], "lowerReady": True, "trunk": SPEC}


def test_a_pr_above_one_into_a_spec_branch_has_that_spec_branch_as_its_trunk(env):
    stacked_setup(env, low_base=SPEC)
    s = status(env, baseRefName=LOW_BRANCH)
    assert (s["next"], s["stack"]["position"], s["stack"]["trunk"]) == ("merge", 2, SPEC)


def test_a_pr_whose_base_is_neither_a_trunk_nor_a_prs_branch_has_no_trunk(env):
    s = status(env, baseRefName="somewhere-else")
    assert (s["next"], s["stack"]["trunk"]) == ("hold", None)


def test_a_pr_into_a_spec_branch_merges_directly_into_it_and_asks_about_its_queue(env):
    out = merge(env, baseRefName=SPEC)
    assert out.returncode == 0, out.stderr
    log = calls(env)
    assert f"gh pr merge 7 --merge --match-head-commit {HEAD}" in log
    assert not any(l.startswith("gh stack merge") for l in log)
    assert f"-F branch={SPEC}" in Path(env["FAKE_LOG"]).read_text()  # the queue asked about is the spec branch's


def test_a_pr_stacked_above_one_into_a_spec_branch_merges_through_gh_stack(env):
    stacked_setup(env, low_base=SPEC)
    Path(env["FAKE_PR"]).write_text(json.dumps(pr(baseRefName=LOW_BRANCH)))
    out = subprocess.run([str(MERGE_TICKET), "7"], env=env, capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    log = calls(env)
    assert "gh stack merge 7 --yes --merge" in log
    assert f"-F branch={SPEC}" in Path(env["FAKE_LOG"]).read_text()  # the queue asked about is the spec branch's


def test_the_first_ticket_of_a_spec_is_based_on_its_spec_branch(started):
    env, work, _ = started
    Path(env["FAKE_SPEC"]).write_text("Spec: Installable phone app\n")
    subprocess.run(["git", "push", "-q", "origin", f"HEAD:refs/heads/{SPEC}"], cwd=work, check=True)
    out = start(started)
    assert f"--base-branch origin/{SPEC}" in log(started), out.stderr


def test_a_spec_whose_branch_is_not_on_origin_stacks_onto_main(started):
    Path(started[0]["FAKE_SPEC"]).write_text("Spec: Installable phone app\n")
    start(started)
    assert "--base-branch origin/main" in log(started)


def test_the_top_of_the_specs_stack_wins_over_its_spec_branch(started):
    env, work, _ = started
    Path(env["FAKE_SPEC"]).write_text("Spec: Installable phone app\n")
    subprocess.run(["git", "push", "-q", "origin", f"HEAD:refs/heads/{SPEC}"], cwd=work, check=True)
    spec_with(env, sibling(41, pr=("k/41-a", SPEC)))
    start(started)
    assert "--base-branch origin/k/41-a" in log(started)
