defmodule GroupStay.ReservationsConcurrencyTest do
  use ExUnit.Case, async: false

  import GroupStay.PartnerFixtures

  alias GroupStay.{Finance, Repo, Reservations}

  # Independent connections to a real database exercise locking and commits that
  # the shared connection in ConnCase's sandbox deliberately hides.
  setup_all do
    directory = Path.expand("tmp/concurrency-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    template = Path.join(directory, "template.db")

    repo =
      start_supervised!(
        {Repo, name: nil, database: template, pool: DBConnection.ConnectionPool, pool_size: 1}
      )

    previous_repo = Repo.put_dynamic_repo(repo)

    try do
      Ecto.Migrator.run(Repo, :up, all: true, log: false)
      Repo.query!("PRAGMA wal_checkpoint(TRUNCATE)")
    after
      Repo.put_dynamic_repo(previous_repo)
      stop_supervised!(Repo)
    end

    %{directory: directory, template: template}
  end

  setup %{directory: directory, template: template} do
    database = Path.join(directory, "#{System.unique_integer([:positive])}.db")
    File.cp!(template, database)

    repo =
      start_supervised!(
        {Repo, name: nil, database: database, pool: DBConnection.ConnectionPool, pool_size: 4}
      )

    Repo.put_dynamic_repo(repo)

    %{repo: repo}
  end

  test "only one concurrent writer can apply the same expected revision", %{repo: repo} do
    Reservations.apply_batch([open_group()])

    results =
      concurrently(repo, [
        operation("record_cash_payment", %{
          "operation_id" => "first",
          "amount_cents" => 500,
          "expected_revision" => 1
        }),
        operation("record_cash_payment", %{
          "operation_id" => "second",
          "amount_cents" => 700,
          "expected_revision" => 1
        })
      ])

    assert [applied] = Enum.filter(results, &(&1.status == "applied"))

    assert [%{code: "stale_revision", expected_revision: 1, actual_revision: 2}] =
             Enum.filter(results, &(&1.status == "rejected"))

    group = Reservations.get_group("group-81")
    assert group.revision == 2
    assert group.deposit_paid_cents == applied.amount_cents
    assert Finance.totals().cash_held_cents == applied.amount_cents
  end

  test "unconditional concurrent payments cannot overwrite one another", %{repo: repo} do
    Reservations.apply_batch([open_group()])

    assert [%{status: "applied"}, %{status: "applied"}] =
             concurrently(repo, [
               operation("record_cash_payment", %{
                 "operation_id" => "first",
                 "amount_cents" => 500
               }),
               operation("record_cash_payment", %{
                 "operation_id" => "second",
                 "amount_cents" => 700
               })
             ])

    assert %{revision: 3, deposit_paid_cents: 1200} = Reservations.get_group("group-81")
    assert Finance.totals().cash_held_cents == 1200
  end

  test "concurrent opening preserves group uniqueness", %{repo: repo} do
    results = concurrently(repo, [open_group(), open_group(%{"operation_id" => "second"})])

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert [%{code: "group_already_exists"}] = Enum.filter(results, &(&1.status == "rejected"))
    assert length(Reservations.get_group("group-81").rooms) == 2
  end

  test "concurrent payments cannot collectively exceed the outstanding deposit", %{repo: repo} do
    Reservations.apply_batch([open_group()])

    results =
      concurrently(repo, [
        operation("record_cash_payment", %{"operation_id" => "first", "amount_cents" => 19_500}),
        operation("record_cash_payment", %{"operation_id" => "second", "amount_cents" => 19_500})
      ])

    assert Enum.count(results, &(&1.status == "applied")) == 1

    assert [%{code: "payment_exceeds_outstanding"}] =
             Enum.filter(results, &(&1.status == "rejected"))

    assert %{revision: 2, deposit_paid_cents: 19_500} = Reservations.get_group("group-81")
    assert Finance.totals().cash_held_cents == 19_500
  end

  test "migrations can be rerun on a populated database without changing bookings or cash" do
    Reservations.apply_batch([
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 1234})
    ])

    group = Reservations.get_group("group-81")
    totals = Finance.totals()

    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
    assert Reservations.get_group("group-81") == group
    assert Finance.totals() == totals
  end

  defp concurrently(repo, operations) do
    parent = self()

    tasks =
      Enum.map(operations, fn operation ->
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(parent, {:ready, self()})

          receive do
            :go -> hd(Reservations.apply_batch([operation]))
          end
        end)
      end)

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}, 1000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks)
  end
end
