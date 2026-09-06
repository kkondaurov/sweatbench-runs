defmodule GroupStay.DepositTransferDurabilityTest do
  use ExUnit.Case, async: false
  alias GroupStay.{Repo, Reservations}

  setup do
    path = Path.expand("_build/transfer-#{System.unique_integer([:positive])}.db")

    options = [
      name: :transfer_durability_repo,
      database: path,
      pool: DBConnection.ConnectionPool,
      pool_size: 2,
      busy_timeout: 2_000
    ]

    start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    previous = Repo.put_dynamic_repo(:transfer_durability_repo)
    Ecto.Migrator.run(Repo, Path.expand("priv/repo/migrations"), :up, all: true, log: false)
    stop_supervised!(Repo)
    start_supervised!({Repo, options})

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)
      Enum.each([path, path <> "-shm", path <> "-wal"], &File.rm/1)
    end)

    %{options: options}
  end

  defp op(type, attrs) do
    Map.merge(
      %{
        "type" => type,
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "group_id" => "g",
        "occurred_on" => "2027-02-01"
      },
      attrs
    )
  end

  defp open(id \\ "g", attrs \\ %{}) do
    op(
      "open_group",
      Map.merge(
        %{
          "group_id" => id,
          "guest_id" => "guest",
          "property_id" => "hotel",
          "arrival_on" => "2028-06-01",
          "departure_on" => "2028-06-02",
          "rate_plan" => "flexible",
          "rooms" => Enum.map(~w(a b c), &%{"room_id" => &1, "nightly_rate_cents" => 500})
        },
        attrs
      )
    )
  end

  defp run(operation), do: hd(Reservations.batch([operation]))

  defp cash(id, group, amount),
    do:
      op("record_cash_payment", %{
        "operation_id" => id,
        "group_id" => group,
        "amount_cents" => amount
      })

  defp transfer,
    do:
      op("transfer_deposit", %{
        "source_group_id" => "g",
        "destination_group_id" => "d",
        "amount_cents" => 100
      })

  test "migration preserves funding order after settled credit and later room refills" do
    run(open("seed"))
    run(cash("seed-pay", "seed", 300))
    run(op("cancel_group", %{"group_id" => "seed", "refund_method" => "hotel_credit"}))
    run(open())
    run(open("d"))
    run(op("apply_hotel_credit", %{"amount_cents" => 100}))
    run(op("cancel_rooms", %{"room_ids" => ["a"]}))
    run(cash("pay", "g", 50))
    run(op("apply_hotel_credit", %{"amount_cents" => 100}))

    before =
      {Reservations.get_group("g"), Reservations.ledger(~D[2027-02-01]),
       Reservations.get_payment("pay")}

    path = Path.expand("priv/repo/migrations")
    Ecto.Migrator.run(Repo, path, :down, to: 20_260_905_000_004, log: false)
    Ecto.Migrator.run(Repo, path, :up, all: true, log: false)

    assert {Reservations.get_group("g"), Reservations.ledger(~D[2027-02-01]),
            Reservations.get_payment("pay")} == before

    assert run(transfer())["status"] == "applied"
    assert Reservations.get_group("d").credit_paid_cents == 100
    assert Reservations.get_group("d").cash_paid_cents == 0
    assert Reservations.get_group("g").cash_paid_cents == 50
  end

  test "concurrent transfer retries survive database restart and keep payment participation", %{
    options: options
  } do
    run(open())
    run(open("d"))
    run(cash("pay", "g", 200))
    operation = transfer()

    results =
      1..4
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Repo.put_dynamic_repo(:transfer_durability_repo)
          run(operation)
        end)
      end)
      |> Enum.map(&Task.await(&1, 20_000))

    assert [result] = Enum.uniq(results)
    assert result["source_revision"] == 3
    assert result["destination_revision"] == 2

    before =
      {Reservations.get_group("g"), Reservations.get_group("d"), Reservations.get_payment("pay"),
       Reservations.ledger()}

    stop_supervised!(Repo)
    start_supervised!({Repo, options})
    assert run(operation) == result

    assert {Reservations.get_group("g"), Reservations.get_group("d"),
            Reservations.get_payment("pay"), Reservations.ledger()} == before
  end
end
