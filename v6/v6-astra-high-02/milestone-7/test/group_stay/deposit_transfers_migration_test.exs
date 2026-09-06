defmodule GroupStay.DepositTransfersMigrationTest do
  use ExUnit.Case, async: false

  alias GroupStay.{
    CreditAllocation,
    CreditClawback,
    CreditEntitlement,
    CreditLot,
    Group,
    Operation,
    PaymentTransfer,
    Repo,
    Reservations,
    RoomAccounting,
    RoomAllocation
  }

  test "upgrading preserves existing accounting and allows transfers of unattributed senior funding" do
    directory =
      Path.expand("../../tmp/transfers-upgrade-#{System.unique_integer([:positive])}", __DIR__)

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
    Ecto.Migrator.run(Repo, migrations, :up, to: 20_260_905_000_003, log: false)

    opening = %{
      "operation_id" => "open-source",
      "type" => "open_group",
      "group_id" => "source",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "occurred_on" => "2027-01-01",
      "arrival_on" => "2029-06-01",
      "departure_on" => "2029-06-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 1000}]
    }

    Reservations.submit([
      opening,
      Map.merge(opening, %{"operation_id" => "open-dest", "group_id" => "dest"})
    ])

    # Prior releases can hold a senior block whose payment/application ids never existed.
    lot =
      Repo.insert!(%CreditLot{
        guest_id: "guest",
        source_operation_id: "legacy-cancel",
        remaining_cents: 10,
        expires_on: ~D[2028-01-01]
      })

    source = Repo.get!(Group, "source")

    funded =
      source
      |> RoomAccounting.fund(30, "cash", nil)
      |> RoomAccounting.fund(20, "credit", nil, lot.id)

    source |> Ecto.Changeset.change(RoomAccounting.totals(funded.rooms)) |> Repo.update!()
    RoomAccounting.sync_credit("source")

    payment = %{
      "operation_id" => "pay",
      "type" => "record_cash_payment",
      "group_id" => "source",
      "amount_cents" => 50,
      "occurred_on" => "2027-01-01"
    }

    [payment_result] = Reservations.submit([payment])

    tables = [
      Group,
      CreditLot,
      CreditAllocation,
      RoomAllocation,
      CreditEntitlement,
      CreditClawback,
      Operation
    ]

    before = Enum.map(tables, &Repo.all/1)
    ledger = Reservations.ledger(~D[2027-01-01])

    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == [
             20_260_905_000_004,
             20_260_905_000_005,
             20_260_905_000_006
           ]

    assert Enum.map(tables, &Repo.all/1) == before
    assert Repo.all(PaymentTransfer) == []
    assert Reservations.ledger(~D[2027-01-01]) == ledger
    assert {:ok, statement} = Reservations.get_payment("pay")
    refute Map.has_key?(statement, :held_by_group)

    transfer = %{
      "operation_id" => "transfer",
      "type" => "transfer_deposit",
      "source_group_id" => "source",
      "destination_group_id" => "dest",
      "amount_cents" => 100,
      "occurred_on" => "2027-01-01",
      "expected_revision" => 2,
      "destination_expected_revision" => 1
    }

    assert [%{source_revision: 3, destination_revision: 2}] =
             result = Reservations.submit([transfer])

    assert Enum.map(
             RoomAccounting.held("dest"),
             &{&1.kind, &1.funding_operation_id, &1.amount_cents}
           ) ==
             [{"cash", "pay", 50}, {"credit", nil, 20}, {"cash", nil, 30}]

    assert Reservations.ledger(~D[2027-01-01]) == ledger
    assert Reservations.get_group("source").deposit_paid_cents == 0

    assert {:ok, %{held_by_group: [%{group_id: "dest", amount_cents: 50}]}} =
             Reservations.get_payment("pay")

    assert Reservations.submit([payment]) == [payment_result]
    assert {:error, "operation_not_found"} = Reservations.get_payment("legacy-payment")
    before = Enum.map(tables ++ [PaymentTransfer], &Repo.all/1)
    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == []
    assert Reservations.submit([transfer]) == result
    assert Enum.map(tables ++ [PaymentTransfer], &Repo.all/1) == before

    assert [%{refunded_cents: 80}] =
             Reservations.submit([
               %{
                 "operation_id" => "cancel-dest",
                 "type" => "cancel_group",
                 "group_id" => "dest",
                 "occurred_on" => "2027-01-01"
               }
             ])

    assert Repo.get!(CreditLot, lot.id).remaining_cents == 30
    assert {:ok, %{held_by_group: [], refunded_cents: 50}} = Reservations.get_payment("pay")
    assert Reservations.ledger(~D[2027-01-01]).cash_refunded_cents == 80
  end
end
