defmodule GroupStay.RoomMigrationTest do
  use ExUnit.Case, async: false
  alias GroupStay.{Repo, Reservations}

  setup do
    path = Path.expand("_build/room-migration-#{System.unique_integer([:positive])}.db")

    start_supervised!(
      {Repo,
       name: :room_migration_repo, database: path, pool: DBConnection.ConnectionPool, pool_size: 1}
    )

    previous = Repo.put_dynamic_repo(:room_migration_repo)

    Ecto.Migrator.run(Repo, Path.expand("priv/repo/migrations"), :up,
      to: 20_260_905_000_002,
      log: false
    )

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)
      Enum.each([path, path <> "-shm", path <> "-wal"], &File.rm/1)
    end)

    :ok
  end

  defp group(id, status, cash, credit, refunded \\ 0, retained \\ 0, converted \\ 0) do
    rooms = Enum.map(~w(a b c d), &%{"room_id" => &1, "nightly_rate_cents" => 500})

    Repo.query!(
      """
      INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
      rate_plan, policy_version, status, rooms, revision, lodging_total_cents, deposit_due_cents,
      deposit_paid_cents, cash_paid_cents, credit_paid_cents, refunded_cents, retained_cents, cash_converted_to_credit_cents)
      VALUES (?, 'guest', 'hotel', '2027-01-01', '2028-06-01', '2028-06-02', 'flexible', 'flex-30', ?, ?, 7, 2000, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        id,
        status,
        Jason.encode!(rooms),
        if(status == "active", do: 400, else: 0),
        cash + credit,
        cash,
        credit,
        refunded,
        retained,
        converted
      ]
    )
  end

  defp record(id, type, group, amount, date \\ "2027-02-01") do
    # Credit and cash results have the same shape. Only the retained type classifies funding.
    result = %{
      "operation_id" => id,
      "group_id" => group,
      "amount_cents" => amount,
      "status" => "applied",
      "revision" => 3,
      "outstanding_deposit_cents" => 0
    }

    submission = %{
      "operation_id" => id,
      "type" => type,
      "group_id" => group,
      "amount_cents" => amount,
      "occurred_on" => date
    }

    Repo.query!(
      "INSERT INTO operations (operation_id, type, submission, result) VALUES (?, ?, ?, ?)",
      [id, type, Jason.encode!(submission), Jason.encode!(result)]
    )

    result
  end

  defp lot(id, source, remaining) do
    Repo.query!(
      "INSERT INTO credit_lots (id, guest_id, source_operation_id, remaining_cents, expires_on) VALUES (?, 'guest', ?, ?, '2028-02-01')",
      [id, source, remaining]
    )
  end

  defp allocated(group, lot, amount) do
    Repo.query!(
      "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents) VALUES (?, ?, ?)",
      [group, lot, amount]
    )
  end

  defp migrate,
    do: Ecto.Migrator.run(Repo, Path.expand("priv/repo/migrations"), :up, all: true, log: false)

  defp action(type, attrs) do
    hd(
      Reservations.batch([
        Map.merge(
          %{
            "operation_id" => "new-#{System.unique_integer([:positive])}",
            "type" => type,
            "occurred_on" => "2027-03-01"
          },
          attrs
        )
      ])
    )
  end

  test "legacy cash then credit precede durable mixed funding in commit order, preserving balances" do
    group("g", "active", 160, 170)
    lot(1, "legacy-lot", 10)
    lot(2, "new-lot", 20)
    allocated("g", 1, 120)
    allocated("g", 2, 50)
    record("credit-first", "apply_hotel_credit", "g", 70, "2027-05-01")
    original = record("cash-second", "record_cash_payment", "g", 100, "2027-01-01")
    migrate()
    group = Reservations.get_group("g")
    assert group.revision == 7
    assert group.cash_paid_cents == 160
    assert group.credit_paid_cents == 170
    assert group.deposit_paid_cents == 330
    assert Enum.map(group.rooms, & &1["cash_paid_cents"]) == [60, 0, 70, 30]
    assert Enum.map(group.rooms, & &1["credit_paid_cents"]) == [40, 100, 30, 0]
    assert Reservations.ledger(~D[2027-03-01]).credit_liability_cents == 200
    assert Reservations.get_operation("cash-second") == original
    assert {:ok, statement} = Reservations.get_payment("cash-second")
    assert statement["held_cents"] == 100

    assert action("reduce_cash_payment", %{
             "payment_operation_id" => "legacy",
             "amount_cents" => 1
           })["code"] == "operation_not_found"

    assert action("reduce_cash_payment", %{
             "payment_operation_id" => "cash-second",
             "amount_cents" => 40
           })["revision"] == 8

    assert Enum.map(Reservations.get_group("g").rooms, & &1["cash_paid_cents"]) == [60, 0, 60, 0]
    action("cancel_rooms", %{"group_id" => "g", "room_ids" => ["b"]})
    assert Reservations.credit("guest", ~D[2027-03-01]).available_cents == 130
    assert Reservations.ledger(~D[2027-03-01]).credit_liability_cents == 200
  end

  test "legacy principal is senior when a migrated active group issues credit" do
    group("g", "active", 10, 0)
    record("pay", "record_cash_payment", "g", 5)
    migrate()
    result = action("cancel_group", %{"group_id" => "g", "refund_method" => "hotel_credit"})
    assert result["credit_issued_cents"] == 11
    action("charge_back_payment", %{"payment_operation_id" => "pay"})
    assert Reservations.credit("guest", ~D[2027-03-01]).available_cents == 6
    assert Reservations.ledger(~D[2027-03-01]).cash_converted_to_credit_cents == 5
  end

  test "previous settlements reconcile and converted entitlements survive upgrade" do
    group("refunded", "cancelled", 0, 0, 50)
    group("retained", "cancelled", 0, 0, 0, 50)
    group("converted", "cancelled", 0, 0, 0, 0, 10)
    record("refund-pay", "record_cash_payment", "refunded", 30)
    record("retain-pay", "record_cash_payment", "retained", 40)
    record("credit-pay", "record_cash_payment", "converted", 5)
    record("cancel", "cancel_group", "converted", 0)
    lot(1, "cancel", 11)
    migrate()

    for {id, field, amount} <- [
          {"refund-pay", "refunded_cents", 30},
          {"retain-pay", "retained_cents", 40},
          {"credit-pay", "converted_to_credit_cents", 5}
        ] do
      assert {:ok, statement} = Reservations.get_payment(id)
      assert statement[field] == amount
      assert statement["recorded_cents"] == amount

      assert action("charge_back_payment", %{"payment_operation_id" => id})["charged_back_cents"] ==
               amount
    end

    ledger = Reservations.ledger(~D[2027-03-01])
    assert ledger.cash_refunded_cents == 20
    assert ledger.cash_retained_cents == 10
    assert ledger.cash_converted_to_credit_cents == 5
    assert ledger.cash_charged_back_cents == 75
    assert ledger.credit_liability_cents == 6
  end
end
