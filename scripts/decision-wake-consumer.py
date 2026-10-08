#!/usr/bin/env python3
"""Consume canonical decision wakes; never interpret inbox text or replay uncertain effects.

The configured submitter reads one JSON frame on stdin and returns zero ONLY
after accepting it. It owns native session/composer/availability fencing.
Dry-run is the default and performs no reservation or native effect.
"""
import argparse
import json
import os
import subprocess
import sys
import uuid

class ReservationDenied(Exception):
    pass

def board(binary, *args):
    result = subprocess.run([binary, "--json", *args], capture_output=True, text=True, timeout=30)
    if result.returncode:
        try:
            code = json.loads(result.stderr).get("error", {}).get("code")
        except (ValueError, AttributeError):
            code = None
        if result.returncode == 4 and code == "conflict":
            raise ReservationDenied(result.stderr.strip())
        raise RuntimeError("Agentboard decision operation refused; inspect canonical state: " + (result.stderr.strip() or result.stdout.strip()))
    return json.loads(result.stdout)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--owner", required=True, help="Allowlisted requester; coordinator identity stays in AGENT_ID")
    parser.add_argument("--task", help="Optional single-task scope")
    parser.add_argument("--agentboard", default=os.environ.get("AGENTBOARD_BINARY", "agentboard"))
    parser.add_argument("--execute", action="store_true", help="Reserve and invoke the explicitly configured submitter")
    parser.add_argument("--submit-timeout", type=float, default=30)
    parser.add_argument("submitter", nargs=argparse.REMAINDER, help="Configured guarded native submitter; reads JSON stdin")
    args = parser.parse_args()
    submitter = args.submitter
    if submitter and submitter[0] == "--":
        submitter = submitter[1:]
    if args.execute and not submitter:
        parser.error("--execute requires a guarded submitter command")
    if args.submit_timeout <= 0:
        parser.error("--submit-timeout must be positive")
    cursor = None
    while True:
        query = ["decision", "wake", "list", "--owner", args.owner, "--status", "pending", "--route", "seat_watcher", "--limit", "100"]
        if args.task:
            query += ["--task", args.task]
        if cursor:
            query += ["--cursor", cursor]
        page = board(args.agentboard, *query)
        for wake in page["wakes"]:
            decision = board(args.agentboard, "decision", "show", wake["request_id"])["decision"]
            if decision["status"] != "answered" or decision["answered_at"] != wake["answered_at"]:
                continue
            frame = {"decision_id": decision["id"], "task_id": decision["task_id"],
                     "requester_id": decision["requester_id"], "answered_at": decision["answered_at"],
                     "wake_id": wake["id"], "source_key": wake["source_key"],
                     "prompt": "Captain answered decision " + decision["id"] + " for task " + decision["task_id"] +
                     ". Read agentboard decision show, apply only the returned answer, renew the task, then decision ack. Never answer your own gate."}
            if not args.execute:
                print(json.dumps({"dry_run": True, "frame": frame}), flush=True)
                continue
            key = "decision-watcher-" + str(uuid.uuid4())
            try:
                reserved = board(args.agentboard, "decision", "wake", "reserve", wake["id"], "--key", key)
            except ReservationDenied as denied:
                print(json.dumps({"wake_id": wake["id"], "disposition": "skipped", "reason": str(denied)}), flush=True)
                continue
            if not reserved.get("dispatch_allowed"):
                continue
            try:
                result = subprocess.run(submitter, input=json.dumps(frame), text=True,
                                        capture_output=True, timeout=args.submit_timeout)
                if result.returncode:
                    raise RuntimeError("Submitter did not prove acceptance")
            except (OSError, subprocess.TimeoutExpired, RuntimeError):
                board(args.agentboard, "decision", "wake", "uncertain", wake["id"], "--key", key,
                      "--reason", "Native submitter did not prove acceptance; automatic replay prohibited")
                print(json.dumps({"wake_id": wake["id"], "disposition": "uncertain"}), flush=True)
                continue
            board(args.agentboard, "decision", "wake", "accept", wake["id"], "--key", key)
            print(json.dumps({"wake_id": wake["id"], "disposition": "accepted"}), flush=True)
        cursor = page.get("next_cursor")
        if not cursor:
            return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ReservationDenied, subprocess.TimeoutExpired, json.JSONDecodeError):
        print("Decision consumer stopped; inspect canonical wake state before recovery", file=sys.stderr)
        sys.exit(1)

