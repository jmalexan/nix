"""Local operator enrollment; no remotely accessible administrator credential."""

import argparse
import re

from .store import Store


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    enroll = sub.add_parser("enroll")
    enroll.add_argument("--recipient", required=True)
    revoke = sub.add_parser("revoke")
    revoke.add_argument("--device", required=True)
    reset = sub.add_parser("reset-devices")
    reset.add_argument("--confirm-reset", action="store_true", required=True)
    args = parser.parse_args()
    store = Store(args.database)
    if args.command == "enroll":
        if not re.fullmatch(r"[a-zA-Z0-9_-]{1,64}", args.recipient):
            parser.error("Invalid recipient")
        # Intentionally printed only to the trusted operator's terminal.
        print(store.grant(args.recipient))
    elif args.command == "revoke":
        with store.transaction() as db:
            db.execute("UPDATE devices SET active=0 WHERE id=?", (args.device,))
            db.execute("DELETE FROM sessions WHERE device=?", (args.device,))
    else:
        with store.transaction() as db:
            db.execute("UPDATE devices SET active=0")
            db.execute("DELETE FROM grants")
            db.execute("DELETE FROM tickets")
            db.execute("DELETE FROM sessions")
            db.execute("UPDATE deliveries SET state='failed'")
            db.execute("UPDATE responses SET acknowledged=1")


if __name__ == "__main__":
    main()
