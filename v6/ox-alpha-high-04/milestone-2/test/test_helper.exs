# Every test shares one SQLite file database and SQLite allows a single
# writer at a time: sandboxed transactions running concurrently fail fast
# with "database is locked" when they promote from reading to writing.
# Run test cases sequentially so the suite stays deterministic.
ExUnit.start(max_cases: 1)
Ecto.Adapters.SQL.Sandbox.mode(GroupStay.Repo, :manual)
