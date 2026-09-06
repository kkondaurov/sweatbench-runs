defmodule GroupStay.CancellationEconomicsMigrationTest do
  use ExUnit.Case, async: false

  alias GroupStay.{Repo, Reservations}

  test "upgrades populated operational-core databases and preserves money, revisions and fixed policies" do
    directory = Path.expand("../../tmp/upgrade-#{System.unique_integer([:positive])}", __DIR__)
    File.mkdir_p!(directory)
    on_exit(fn -> GroupStay.TestFiles.remove_directory!(directory) end)

    repo =
      start_supervised!(
        {Repo,
         name: nil,
         database: Path.join(directory, "groups.db"),
         pool: DBConnection.ConnectionPool,
         pool_size: 1}
      )

    Repo.put_dynamic_repo(repo)
    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations, :up, to: 20_260_905_000_000, log: false)

    for {id, booked, plan, status, paid, refunded, retained} <- [
          {"old", "2026-12-31", "flexible", "active", 100, 0, 0},
          {"new", "2027-01-01", "flexible", "active", 200, 0, 0},
          {"advance", "2026-12-31", "advance_purchase", "active", 300, 0, 0},
          {"cancelled", "2026-12-31", "flexible", "cancelled", 0, 75, 0},
          {"retained", "2027-01-01", "advance_purchase", "cancelled", 0, 0, 80}
        ] do
      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, revision, booked_on, arrival_on,
          departure_on, rate_plan, status, rooms, lodging_total_cents, deposit_due_cents,
          deposit_paid_cents, cash_refunded_cents, cash_retained_cents)
        VALUES (?, 'guest', 'hotel', 7, ?, '2027-06-01', '2027-06-02', ?, ?, ?, 10000, ?, ?, ?, ?)
        """,
        [
          id,
          booked,
          plan,
          status,
          Jason.encode!([%{room_id: "room", nightly_rate_cents: 10000}]),
          if(status == "active", do: 2000, else: 0),
          paid,
          refunded,
          retained
        ]
      )
    end

    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == [
             20_260_905_000_001,
             20_260_905_000_002,
             20_260_905_000_003,
             20_260_905_000_004,
             20_260_905_000_005
           ]

    for {id, policy, cutoff, cash} <- [
          {"old", "flex-14", ~D[2027-05-18], 100},
          {"new", "flex-30", ~D[2027-05-02], 200},
          {"advance", "advance-nonrefundable", nil, 300},
          {"cancelled", "flex-14", ~D[2027-05-18], 0},
          {"retained", "advance-nonrefundable", nil, 0}
        ] do
      assert %{
               policy_version: ^policy,
               refundable_until: ^cutoff,
               cash_paid_cents: ^cash,
               credit_paid_cents: 0,
               revision: 7
             } = Reservations.get_group(id)
    end

    assert Reservations.ledger() == %{
             cash_held_cents: 600,
             cash_refunded_cents: 75,
             cash_retained_cents: 80,
             cash_converted_to_credit_cents: 0,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             credit_liability_cents: 0
           }

    assert [
             %{revision: 8, policy_version: "flex-14", refundable_until: ~D[2028-05-18]},
             %{revision: 9, credit_issued_cents: 110}
           ] =
             Reservations.submit([
               %{
                 "operation_id" => "move",
                 "type" => "reschedule_group",
                 "group_id" => "old",
                 "occurred_on" => "2027-01-01",
                 "new_arrival_on" => "2028-06-01",
                 "expected_revision" => 7
               },
               %{
                 "operation_id" => "cancel",
                 "type" => "cancel_group",
                 "group_id" => "old",
                 "occurred_on" => "2028-05-18",
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 8
               }
             ])

    assert Reservations.guest_credit("guest", ~D[2028-05-18]).available_cents == 110
    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == []
    assert Reservations.get_group("old").revision == 9
    stop_supervised!(Repo)
  end
end
