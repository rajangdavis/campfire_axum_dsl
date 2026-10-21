# The part of the sqlite3 command-line tool bench/contracts.rb uses, for hosts without it (raj-dev):
#   sqlite3 [-cmd ".timeout MS"] [-readonly] [-json] DB SQL
# prints the rows as a JSON array, as `sqlite3 -json` does, and nothing for a statement without rows.
import json, sqlite3, sys

args, timeout, readonly = sys.argv[1:], 5.0, False
while args and args[0].startswith("-"):
    flag = args.pop(0)
    if flag == "-cmd":
        cmd = args.pop(0).split()
        if cmd[:1] == [".timeout"]:
            timeout = int(cmd[1]) / 1000
    elif flag == "-readonly":
        readonly = True
    elif flag != "-json":
        sys.exit(f"sqlite3 shim: unsupported flag {flag}")
db, sql = args
conn = sqlite3.connect(f"file:{db}?mode=ro" if readonly else db, uri=readonly, timeout=timeout)
conn.row_factory = sqlite3.Row
rows = [dict(row) for row in conn.execute(sql)] if sql.strip() else []
conn.commit()
if rows:
    print(json.dumps(rows))
