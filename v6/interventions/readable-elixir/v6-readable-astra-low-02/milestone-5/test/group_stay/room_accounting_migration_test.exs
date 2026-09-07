defmodule GroupStay.RoomAccountingMigrationTest do
  use ExUnit.Case, async: false
  alias GroupStay.{Operations, Repo, Reservations}
  alias GroupStay.Reservations.Payments

  @tag capture_log: true
  test "upgrade allocates senior funding before durable commit order and preserves settled provenance" do
    directory =
      Path.expand("../../tmp/room-migration-#{System.unique_integer([:positive])}", __DIR__)

    File.mkdir_p!(directory)

    repo =
      start_supervised!(
        {Repo,
         name: nil,
         database: Path.join(directory, "groups.db"),
         pool: DBConnection.ConnectionPool,
         pool_size: 1}
      )

    previous = Repo.put_dynamic_repo(repo)

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)
      GroupStay.DatabaseFiles.remove!(directory)
    end)

    Ecto.Migrator.run(Repo, :up, to: 20_260_907_000_002, log: false)
    rooms = Enum.map(0..4, &%{room_id: "r#{&1}", nightly_rate_cents: 500})
    insert_group("active", "active", rooms, 350, 170, 0)
    insert_group("settled", "cancelled", rooms, 50, 0, 50)

    for {id, remaining} <- [{1, 10}, {2, 20}, {3, 30}] do
      Repo.query!(
        "INSERT INTO credit_lots (id, guest_id, source_operation_id, remaining_cents, expires_on) VALUES (?, 'guest', ?, ?, '2028-01-01')",
        [id, "legacy-lot-#{id}", remaining]
      )
    end

    for {lot, amount} <- [{1, 40}, {2, 90}, {3, 40}] do
      Repo.query!(
        "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents) VALUES ('active', ?, ?)",
        [lot, amount]
      )
    end

    record("credit", "apply_hotel_credit", "active", 90, "2027-03-01")
    record("pay-z", "record_cash_payment", "active", 50, "2027-02-01")
    record("pay-a", "record_cash_payment", "active", 70, "2027-01-01")
    record("settled-payment", "record_cash_payment", "settled", 45, "2027-01-01")
    record("settled-cancel", "cancel_group", "settled", 0, "2027-01-01")

    Repo.query!(
      "INSERT INTO credit_lots (guest_id, source_operation_id, remaining_cents, expires_on) VALUES ('guest', 'settled-cancel', 55, '2028-01-01')"
    )

    audit = Repo.all(Operations)

    Ecto.Migrator.run(Repo, :up, all: true, log: false)
    assert Repo.all(Operations) == audit

    assert %{deposit_paid_cents: 350, credit_paid_cents: 170, revision: 5} =
             group = Reservations.get_group("active")

    assert Enum.map(group.rooms, &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {60, 40},
             {0, 100},
             {70, 30},
             {50, 0},
             {0, 0}
           ]

    assert %{
             cash_held_cents: 180,
             cash_converted_to_credit_cents: 50,
             credit_liability_cents: 285
           } = Reservations.ledger(~D[2027-01-01])

    assert {:ok, %{recorded_cents: 50, held_cents: 50}} = Payments.statement("pay-z")

    assert {:ok, %{recorded_cents: 45, converted_to_credit_cents: 45}} =
             Payments.statement("settled-payment")

    assert {:error, "operation_not_found"} = Payments.statement("legacy-payment")

    assert [%{charged_back_cents: 45, revision: 6}] =
             Reservations.submit([
               %{
                 "type" => "charge_back_payment",
                 "operation_id" => "charge-old",
                 "payment_operation_id" => "settled-payment",
                 "occurred_on" => "2027-01-01"
               }
             ])

    assert Reservations.guest_credit("guest", ~D[2027-01-01]).available_cents == 66
    assert Reservations.get_group("active") == group

    assert [%{credit_issued_cents: 77}] =
             Reservations.submit([
               %{
                 "type" => "cancel_rooms",
                 "operation_id" => "convert",
                 "group_id" => "active",
                 "room_ids" => ["r2"],
                 "refund_method" => "hotel_credit",
                 "occurred_on" => "2027-01-01"
               }
             ])

    assert [%{charged_back_cents: 50}] =
             Reservations.submit([
               %{
                 "type" => "charge_back_payment",
                 "operation_id" => "charge",
                 "payment_operation_id" => "pay-z",
                 "occurred_on" => "2027-01-01"
               }
             ])

    assert {:ok, %{held_cents: 50, converted_to_credit_cents: 20}} = Payments.statement("pay-a")
    assert Reservations.get_group("active").deposit_paid_cents == 250
    insert_group("destination", "active", rooms, 0, 0, 0)
    ledger = Reservations.ledger(~D[2027-01-01])

    assert [%{status: "applied"}] =
             Reservations.submit([
               %{
                 "type" => "transfer_deposit",
                 "operation_id" => "transfer-upgraded",
                 "source_group_id" => "active",
                 "destination_group_id" => "destination",
                 "amount_cents" => 100,
                 "occurred_on" => "2027-01-01"
               }
             ])

    # The latest durable cash is drawn before earlier credit, despite the
    # cash and credit tables having independently generated IDs before upgrade.
    assert %{cash_paid_cents: 50, credit_paid_cents: 50} =
             Reservations.get_group("destination")

    assert Reservations.ledger(~D[2027-01-01]) == ledger

    assert {:ok, %{held_by_group: [%{group_id: "destination", amount_cents: 50}]}} =
             Payments.statement("pay-a")

    Repo.put_dynamic_repo(previous)
    stop_supervised!(Repo)
  end

  defp insert_group(id, status, rooms, paid, credit, converted) do
    Repo.query!(
      """
      INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, policy_version, status, rooms, lodging_total_cents, deposit_due_cents,
        deposit_paid_cents, credit_paid_cents, converted_cents, revision)
      VALUES (?, 'guest', 'hotel', '2027-01-01', '2027-06-01', '2027-06-02',
        'flexible', 'flex-30', ?, ?, 2500, ?, ?, ?, ?, 5)
      """,
      [
        id,
        status,
        Jason.encode!(rooms),
        if(status == "active", do: 500, else: 0),
        paid,
        credit,
        converted
      ]
    )
  end

  defp record(id, type, group, amount, on) do
    Repo.insert!(%Operations{
      operation_id: id,
      type: type,
      submission: %{
        "operation_id" => id,
        "type" => type,
        "group_id" => group,
        "amount_cents" => amount,
        "occurred_on" => on
      },
      result: %{
        "operation_id" => id,
        "status" => "applied",
        "group_id" => group,
        "amount_cents" => amount,
        "revision" => 5
      }
    })
  end
end
