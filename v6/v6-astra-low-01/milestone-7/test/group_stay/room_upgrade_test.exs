defmodule GroupStay.RoomUpgradeTest do
  use ExUnit.Case, async: false
  alias GroupStay.{Repo, Reservations}

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  test "legacy senior funding and durable type/commit order survive upgrade and restart" do
    path = Path.expand("_build/room-upgrade-#{System.unique_integer([:positive])}.db")
    opts = [database: path, pool_size: 1]
    start_supervised!({UpgradeRepo, opts})
    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)
    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_905_000_002, log: false)
    rooms = Enum.map(0..2, &%{"room_id" => "r#{&1}", "nightly_rate_cents" => 500})
    lots = [%{"lot_id" => 1, "amount_cents" => 40}, %{"lot_id" => 2, "amount_cents" => 30}]

    UpgradeRepo.query!(
      """
      INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, status, revision, rooms, lodging_total_cents, deposit_due_cents, deposit_paid_cents,
        cash_paid_cents, credit_paid_cents, credit_allocations, policy_version)
      VALUES ('g', 'guest', 'hotel', '2026-01-01', '2026-12-01', '2026-12-02', 'flexible', 'active', 6, ?, 1500, 300, 250, 180, 70, ?, 'flex-14')
      """,
      [Jason.encode!(rooms), Jason.encode!(lots)]
    )

    for id <- [1, 2] do
      UpgradeRepo.query!(
        "INSERT INTO credit_lots (id, guest_id, source_operation_id, remaining_cents, expires_on) VALUES (?, 'guest', ?, 0, '2027-01-01')",
        [id, "legacy-credit-#{id}"]
      )
    end

    for {id, type, amount, date} <- [
          {"credit", "apply_hotel_credit", 30, "2026-10-01"},
          {"p", "record_cash_payment", 100, "2026-09-01"},
          {"q", "record_cash_payment", 20, "2026-08-01"}
        ] do
      submission = %{
        "operation_id" => id,
        "type" => type,
        "group_id" => "g",
        "amount_cents" => amount,
        "occurred_on" => date
      }

      result = %{
        "operation_id" => id,
        "status" => "applied",
        "group_id" => "g",
        "amount_cents" => amount,
        "revision" => 4
      }

      UpgradeRepo.query!(
        "INSERT INTO operations (operation_id, type, submission, result) VALUES (?, ?, ?, ?)",
        [id, type, Jason.encode!(submission), Jason.encode!(result)]
      )
    end

    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_905_000_003, log: false)
    before_ordering = UpgradeRepo.all(GroupStay.Group)
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false)
    ordered = UpgradeRepo.all(GroupStay.Group)

    assert Enum.map(ordered, fn group ->
             %{group | funding: Enum.map(group.funding, &Map.delete(&1, "allocation_order"))}
           end) == before_ordering

    orders =
      Enum.flat_map(ordered, fn group -> Enum.map(group.funding, & &1["allocation_order"]) end)

    assert Enum.all?(orders, &(is_integer(&1) and &1 > 0))
    assert length(Enum.uniq(orders)) == length(orders)
    previous = Repo.put_dynamic_repo(UpgradeRepo)

    try do
      group = Reservations.get("g")

      assert Enum.map(group.rooms, &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
               {60, 40},
               {70, 30},
               {50, 0}
             ]

      assert group.revision == 6

      assert %{cash_held_cents: 180, credit_liability_cents: 70} =
               Reservations.ledger(~D[2026-10-01])

      assert {:ok, %{held_cents: 100}} = Reservations.payment("p")

      assert [%{credit_issued_cents: 143}] =
               Reservations.batch([
                 %{
                   "operation_id" => "cancel",
                   "type" => "cancel_rooms",
                   "group_id" => "g",
                   "room_ids" => ["r1", "r0"],
                   "occurred_on" => "2026-10-01",
                   "refund_method" => "hotel_credit"
                 }
               ])

      charge = %{
        "operation_id" => "charge",
        "type" => "charge_back_payment",
        "payment_operation_id" => "p",
        "occurred_on" => "2026-10-01"
      }

      assert [%{charged_back_cents: 100, revision: 8}] = result = Reservations.batch([charge])

      assert %{
               cash_held_cents: 20,
               cash_converted_to_credit_cents: 60,
               cash_charged_back_cents: 100,
               credit_liability_cents: 136
             } = Reservations.ledger(~D[2026-10-01])

      stop_supervised!(UpgradeRepo)
      start_supervised!({UpgradeRepo, opts})
      assert Reservations.batch([charge]) == result
      assert {:ok, %{charged_back_cents: 100, held_cents: 0}} = Reservations.payment("p")
      assert Reservations.operation("p")["revision"] == 4
    after
      Repo.put_dynamic_repo(previous)
    end
  end
end
