defmodule GroupStay.CancellationMigrationTest do
  use ExUnit.Case, async: false
  alias GroupStay.{Repo, Reservations}

  @tag capture_log: true
  test "a previous release database backfills policies without changing deposits" do
    directory =
      Path.expand(
        "../../tmp/migration-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}",
        __DIR__
      )

    File.mkdir_p!(directory)

    repo =
      start_supervised!(
        {Repo,
         name: nil,
         database: Path.join(directory, "groups.db"),
         pool: DBConnection.ConnectionPool,
         pool_size: 1}
      )

    previous_repo = Repo.put_dynamic_repo(repo)

    on_exit(fn ->
      Repo.put_dynamic_repo(previous_repo)

      File.rm_rf!(directory)
    end)

    Ecto.Migrator.run(Repo, :up, to: 20_260_907_000_000, log: false)

    for {id, booked, plan} <- [
          {"old", "2026-12-31", "flexible"},
          {"new", "2027-01-01", "flexible"},
          {"advance", "2026-12-31", "advance_purchase"}
        ] do
      Repo.query!(
        """
        INSERT INTO groups
          (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
           rate_plan, status, rooms, lodging_total_cents, deposit_due_cents, deposit_paid_cents)
        VALUES (?, 'guest', 'hotel', ?, '2027-06-01', '2027-06-02', ?, 'active', '[]', 1000, 200, 100)
        """,
        [id, booked, plan]
      )
    end

    Ecto.Migrator.run(Repo, :up, all: true, log: false)

    for {id, policy, deadline} <- [
          {"old", "flex-14", ~D[2027-05-18]},
          {"new", "flex-30", ~D[2027-05-02]},
          {"advance", "advance-nonrefundable", nil}
        ] do
      assert %{
               policy_version: ^policy,
               refundable_until: ^deadline,
               deposit_paid_cents: 100,
               cash_paid_cents: 100,
               credit_paid_cents: 0,
               outstanding_deposit_cents: 100,
               revision: 1
             } = Reservations.get_group(id)
    end

    assert Reservations.ledger().cash_held_cents == 300
    Repo.put_dynamic_repo(previous_repo)
    stop_supervised!(Repo)
  end
end
