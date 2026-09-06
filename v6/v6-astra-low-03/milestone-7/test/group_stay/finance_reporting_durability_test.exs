defmodule GroupStay.FinanceReportingDurabilityTest do
  use ExUnit.Case, async: false
  alias GroupStay.{Repo, Reservations}

  setup do
    path = Path.expand("_build/finance-#{System.unique_integer([:positive])}.db")

    options = [
      name: :finance_durability_repo,
      database: path,
      pool: DBConnection.ConnectionPool,
      pool_size: 2,
      busy_timeout: 2_000
    ]

    start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    previous = Repo.put_dynamic_repo(:finance_durability_repo)
    Ecto.Migrator.run(Repo, Path.expand("priv/repo/migrations"), :up, all: true, log: false)
    stop_supervised!(Repo)
    start_supervised!({Repo, options})

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)
      Enum.each([path, path <> "-shm", path <> "-wal"], &File.rm/1)
    end)

    %{options: options}
  end

  defp run(op), do: hd(Reservations.batch([op]))

  test "report inception and movements survive concurrent retries and restart", %{
    options: options
  } do
    start = %{
      "operation_id" => "start",
      "type" => "start_finance_reporting",
      "occurred_on" => "2027-01-01",
      "starts_on" => "2027-01-01"
    }

    results =
      1..4
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Repo.put_dynamic_repo(:finance_durability_repo)
          run(start)
        end)
      end)
      |> Enum.map(&Task.await(&1, 20_000))

    assert [result] = Enum.uniq(results)
    assert result["status"] == "applied"

    run(%{
      "operation_id" => "open",
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => "g",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2028-01-01",
      "departure_on" => "2028-01-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 10000}]
    })

    payment = %{
      "operation_id" => "pay",
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-01",
      "group_id" => "g",
      "amount_cents" => 100
    }

    original = run(payment)
    before = GroupStay.FinanceReporting.report(~D[2027-01-01])
    stop_supervised!(Repo)
    start_supervised!({Repo, options})
    assert run(start) == result
    assert run(payment) == original
    assert GroupStay.FinanceReporting.report(~D[2027-01-01]) == before

    Repo.query!(
      "CREATE TRIGGER fail_finance BEFORE INSERT ON finance_movements BEGIN SELECT RAISE(ABORT, 'finance fault'); END"
    )

    assert_raise Exqlite.Error, fn -> run(Map.put(payment, "operation_id", "fault")) end
    assert Reservations.get_operation("fault") == nil
    assert Reservations.get_group("g").cash_paid_cents == 100
    assert GroupStay.FinanceReporting.report(~D[2027-01-01]) == before
    Repo.query!("DROP TRIGGER fail_finance")
    assert run(Map.put(payment, "operation_id", "fault"))["status"] == "applied"
  end

  test "close is atomic, concurrent retries persist, and migration preserves earlier reports", %{
    options: options
  } do
    migrations = Path.expand("priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations, :down, to: 20_260_905_000_006, log: false)

    Repo.query!(
      "INSERT INTO finance_reporting (id, starts_on, opening) VALUES (1, '2027-01-01', ?)",
      [Jason.encode!(%{cash: %{"hotel" => 100}, credit: 0})]
    )

    Repo.query!(
      "INSERT INTO finance_movements (posting_on, property_id, classification, amount_cents) VALUES ('2027-01-01', 'hotel', 'received', 50)"
    )

    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
    {:ok, before} = GroupStay.FinanceReporting.report(~D[2027-01-01])
    assert hd(before.cash).closing_held_cents == 150

    close = %{
      "operation_id" => "close",
      "type" => "close_finance_period",
      "occurred_on" => "2027-01-01",
      "period_end_on" => "2027-01-01"
    }

    Repo.query!(
      "CREATE TRIGGER fail_close BEFORE INSERT ON operations WHEN NEW.operation_id = 'close' BEGIN SELECT RAISE(ABORT, 'close fault'); END"
    )

    assert_raise Exqlite.Error, fn -> run(close) end
    assert Reservations.get_operation("close") == nil
    assert GroupStay.FinanceReporting.report(~D[2027-01-01]) == {:ok, before}
    Repo.query!("DROP TRIGGER fail_close")

    results =
      1..4
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Repo.put_dynamic_repo(:finance_durability_repo)
          run(close)
        end)
      end)
      |> Enum.map(&Task.await(&1, 20_000))

    assert [result] = Enum.uniq(results)
    assert result["status"] == "applied"
    {:ok, closed} = GroupStay.FinanceReporting.report(~D[2027-01-01])
    assert closed == Map.put(before, :status, "closed")
    encoded = Jason.encode!(closed)
    stop_supervised!(Repo)
    start_supervised!({Repo, options})
    assert run(close) == result
    {:ok, restarted} = GroupStay.FinanceReporting.report(~D[2027-01-01])
    assert Jason.encode!(restarted) == encoded

    assert run(%{close | "operation_id" => "later", "period_end_on" => "2027-02-01"})["status"] ==
             "applied"

    {:ok, later} = GroupStay.FinanceReporting.report(~D[2027-01-01])
    assert Jason.encode!(later) == encoded
  end
end
