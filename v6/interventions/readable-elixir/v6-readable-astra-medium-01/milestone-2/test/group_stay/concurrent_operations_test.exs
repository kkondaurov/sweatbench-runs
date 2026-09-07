defmodule GroupStay.ConcurrentOperationsTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias GroupStay.{Repo, Reservations}

  # Real connections are essential here: sandbox tasks share one transaction and
  # cannot exercise SQLite's writer locking between independent transactions.
  setup context do
    directory = Path.join(File.cwd!(), ".concurrency-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    options = [
      name: nil,
      database: Path.join(directory, "groups.db"),
      pool: DBConnection.ConnectionPool
    ]

    # Initialize the database before opening competing connections so their
    # connection pragmas do not race the initial journal setup.
    repo = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})

    Repo.put_dynamic_repo(repo)

    migration_options = if context[:legacy], do: [to: 20_260_907_000_000], else: [all: true]

    Ecto.Migrator.run(
      Repo,
      Application.app_dir(:group_stay, "priv/repo/migrations"),
      :up,
      Keyword.put(migration_options, :log, false)
    )

    stop_supervised!(Repo)
    repo = start_supervised!({Repo, Keyword.put(options, :pool_size, 4)})
    Repo.put_dynamic_repo(repo)

    on_exit(fn ->
      if Process.alive?(repo), do: Supervisor.stop(repo)
      remove_database_directory(directory, 10)
    end)

    %{repo: repo}
  end

  # SQLite native handles can finish releasing WAL files after the pool exits.
  # Some filesystems briefly report a nonempty directory during that cleanup.
  defp remove_database_directory(directory, retries) do
    case File.rm_rf(directory) do
      {:ok, _} ->
        :ok

      {:error, reason, _} when reason in [:eexist, :enotempty] and retries > 0 ->
        Process.sleep(20)
        remove_database_directory(directory, retries - 1)

      {:error, reason, path} ->
        raise File.Error, reason: reason, action: "remove test database", path: path
    end
  end

  test "competing writers cannot both apply the same revision", %{repo: repo} do
    assert [%{revision: 1}] =
             Reservations.submit([
               %{
                 "operation_id" => "open",
                 "type" => "open_group",
                 "group_id" => "concurrent",
                 "guest_id" => "guest",
                 "property_id" => "hotel",
                 "occurred_on" => "2026-10-03",
                 "arrival_on" => "2026-12-10",
                 "departure_on" => "2026-12-13",
                 "rate_plan" => "flexible",
                 "rooms" => [%{"room_id" => "one", "nightly_rate_cents" => 15000}]
               }
             ])

    results =
      1..8
      |> Task.async_stream(
        fn index ->
          Repo.put_dynamic_repo(repo)

          [result] =
            Reservations.submit([
              %{
                "operation_id" => "payment-#{index}",
                "type" => "record_cash_payment",
                "occurred_on" => "2026-10-04",
                "group_id" => "concurrent",
                "amount_cents" => 100,
                "expected_revision" => 1
              }
            ])

          result
        end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 7
    assert Reservations.get_group("concurrent").revision == 2
    assert Reservations.ledger().cash_held_cents == 100
  end

  @tag :legacy
  test "upgrades original accounts using their booking date without changing balances" do
    for {id, booked, plan} <- [
          {"old", "2026-12-31", "flexible"},
          {"new", "2027-01-01", "flexible"},
          {"advance", "2027-01-01", "advance_purchase"}
        ] do
      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, status, revision, rooms, lodging_total_cents, deposit_due_cents,
          deposit_paid_cents, refunded_cents, retained_cents)
        VALUES (?, 'guest', 'hotel', ?, '2027-06-01', '2027-06-02', ?, 'active', 2, '[]', 1000, 200, 100, 0, 0)
        """,
        [id, booked, plan]
      )
    end

    Ecto.Migrator.run(Repo, Application.app_dir(:group_stay, "priv/repo/migrations"), :up,
      all: true,
      log: false
    )

    for {id, policy} <- [
          {"old", "flex-14"},
          {"new", "flex-30"},
          {"advance", "advance-nonrefundable"}
        ] do
      group = Reservations.get_group(id)
      assert group.policy_version == policy
      assert group.revision == 2
      assert group.deposit_paid_cents == 100
      assert group.credit_paid_cents == 0
      assert GroupStay.Reservations.Group.to_map(group).cash_paid_cents == 100
    end

    assert Reservations.ledger().cash_held_cents == 300
    assert Reservations.ledger().credit_liability_cents == 0
  end

  test "competing groups cannot spend the same credit lot", %{repo: repo} do
    opens =
      for id <- ["source", "one", "two"] do
        %{
          "operation_id" => "open-#{id}",
          "type" => "open_group",
          "group_id" => id,
          "guest_id" => "guest",
          "property_id" => "hotel",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-02",
          "rate_plan" => "flexible",
          "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10000}]
        }
      end

    Reservations.submit(
      opens ++
        [
          %{
            "operation_id" => "pay",
            "type" => "record_cash_payment",
            "group_id" => "source",
            "occurred_on" => "2027-01-01",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "cancel",
            "type" => "cancel_group",
            "group_id" => "source",
            "occurred_on" => "2027-01-01",
            "refund_method" => "hotel_credit"
          }
        ]
    )

    results =
      ["one", "two"]
      |> Task.async_stream(fn id ->
        Repo.put_dynamic_repo(repo)

        [result] =
          Reservations.submit([
            %{
              "operation_id" => "apply-#{id}",
              "type" => "apply_hotel_credit",
              "group_id" => id,
              "occurred_on" => "2027-01-01",
              "amount_cents" => 110
            }
          ])

        result
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "insufficient_credit")) == 1
    assert GroupStay.Credits.available("guest", ~D[2027-01-01]).available_cents == 0
    assert Reservations.ledger(~D[2027-01-01]).credit_liability_cents == 110
  end
end
