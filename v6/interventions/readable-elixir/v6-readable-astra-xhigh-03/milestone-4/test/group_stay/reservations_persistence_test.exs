defmodule GroupStay.ReservationsPersistenceTest do
  use GroupStay.PersistenceCase

  import GroupStay.OperationFixtures

  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Reservations.{CashEntry, CreditAllocation, CreditLot, Group, OperationRecord}

  test "competing expected revisions apply only once", %{repo: repo} do
    Reservations.submit_batch([open_group()])

    results =
      race(repo, fn index ->
        [result] =
          Reservations.submit_batch([
            payment(%{"operation_id" => "race-#{index}", "expected_revision" => 1})
          ])

        result
      end)

    assert Enum.count(results, &(&1["status"] == "applied")) == 1

    assert Enum.count(results, &(&1["code"] == "stale_revision" and &1["actual_revision"] == 2)) ==
             3

    assert Reservations.get_group("group-81").revision == 2
    assert Reservations.ledger().cash_held_cents == 5_000
    assert Repo.aggregate(CashEntry, :count) == 1
  end

  test "unconditional concurrent payments cannot overfund a deposit", %{repo: repo} do
    Reservations.submit_batch([open_group()])

    results =
      race(repo, fn index ->
        [result] =
          Reservations.submit_batch([
            payment(%{"operation_id" => "race-#{index}", "amount_cents" => 10_000})
          ])

        result
      end)

    assert Enum.count(results, &(&1["status"] == "applied")) == 1
    assert Enum.count(results, &(&1["code"] == "payment_exceeds_outstanding")) == 3
    assert Reservations.get_group("group-81").deposit_paid_cents == 10_000
    assert Reservations.get_group("group-81").revision == 2
    assert Reservations.ledger().cash_held_cents == 10_000
  end

  test "concurrent duplicate openings create exactly one complete booking", %{repo: repo} do
    results =
      race(repo, fn index ->
        [result] = Reservations.submit_batch([open_group(%{"operation_id" => "open-#{index}"})])
        result
      end)

    assert Enum.count(results, &(&1["status"] == "applied")) == 1
    assert Enum.count(results, &(&1["code"] == "group_already_exists")) == 3
    assert length(Reservations.get_group("group-81").rooms) == 2
    assert Reservations.get_group("group-81").revision == 1
  end

  test "different groups cannot concurrently spend the same guest credit", %{repo: repo} do
    Reservations.submit_batch([
      open_group(),
      payment(),
      cancellation(%{"refund_method" => "hotel_credit"})
    ])

    for index <- 1..4 do
      Reservations.submit_batch([open_group(%{"group_id" => "target-#{index}"})])
    end

    results =
      race(repo, fn index ->
        [result] =
          Reservations.submit_batch([
            credit_application(%{"group_id" => "target-#{index}", "amount_cents" => 5_500})
          ])

        result
      end)

    assert Enum.count(results, &(&1["status"] == "applied" and &1["revision"] == 2)) == 1
    assert Enum.count(results, &(&1["code"] == "insufficient_credit")) == 3
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 0
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 5_500
    assert Repo.aggregate(CreditAllocation, :count) == 1
  end

  test "competing credit applications check revisions before credit sufficiency", %{repo: repo} do
    Reservations.submit_batch([
      open_group(),
      payment(),
      cancellation(%{"refund_method" => "hotel_credit"}),
      open_group(%{"group_id" => "target"})
    ])

    results =
      race(repo, fn index ->
        [result] =
          Reservations.submit_batch([
            credit_application(%{
              "group_id" => "target",
              "operation_id" => "race-#{index}",
              "amount_cents" => 5_500,
              "expected_revision" => 1
            })
          ])

        result
      end)

    assert Enum.count(results, &(&1["status"] == "applied")) == 1

    assert Enum.count(results, &(&1["code"] == "stale_revision" and &1["actual_revision"] == 2)) ==
             3

    assert Repo.aggregate(CreditAllocation, :count) == 1
    assert Reservations.get_group("target").credit_paid_cents == 5_500
  end

  test "failed allocation storage rolls back lot consumption and the group revision" do
    Reservations.submit_batch([
      open_group(),
      payment(),
      cancellation(%{"refund_method" => "hotel_credit"}),
      open_group(%{"group_id" => "target"})
    ])

    before = credit_snapshot()
    operation = credit_application(%{"group_id" => "target"})

    Repo.query!("""
    CREATE TRIGGER reject_allocation BEFORE INSERT ON credit_allocations
    BEGIN
      SELECT RAISE(ABORT, 'simulated allocation failure');
    END
    """)

    assert_raise Exqlite.Error, ~r/simulated allocation failure/, fn ->
      Reservations.submit_batch([operation])
    end

    assert credit_snapshot() == before

    Repo.query!("DROP TRIGGER reject_allocation")

    assert [%{"revision" => 2}] = Reservations.submit_batch([operation])
  end

  test "failed credit issuance rolls back cash settlement, restored lots and cancellation" do
    Reservations.submit_batch([
      open_group(),
      payment(),
      cancellation(%{"refund_method" => "hotel_credit"}),
      open_group(%{"group_id" => "target"}),
      credit_application(%{"group_id" => "target"}),
      payment(%{"group_id" => "target"})
    ])

    before = credit_snapshot()

    Repo.query!("""
    CREATE TRIGGER reject_credit_lot BEFORE INSERT ON credit_lots
    BEGIN
      SELECT RAISE(ABORT, 'simulated credit issuance failure');
    END
    """)

    operation = cancellation(%{"group_id" => "target", "refund_method" => "hotel_credit"})

    assert_raise Exqlite.Error, ~r/simulated credit issuance failure/, fn ->
      Reservations.submit_batch([operation])
    end

    assert credit_snapshot() == before

    Repo.query!("DROP TRIGGER reject_credit_lot")

    assert [%{"revision" => 4, "credit_issued_cents" => 5_500}] =
             Reservations.submit_batch([operation])

    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 11_000
  end

  test "group changes roll back if recording the cash entry fails" do
    Reservations.submit_batch([open_group()])
    before = Reservations.get_group("group-81")
    operation = payment()

    Repo.query!("""
    CREATE TRIGGER reject_cash_entry BEFORE INSERT ON cash_entries
    BEGIN
      SELECT RAISE(ABORT, 'simulated cash storage failure');
    END
    """)

    assert_raise Exqlite.Error, ~r/simulated cash storage failure/, fn ->
      Reservations.submit_batch([operation])
    end

    assert Reservations.get_group("group-81") == before
    assert Reservations.ledger().cash_held_cents == 0
    assert Repo.all(CashEntry) == []

    Repo.query!("DROP TRIGGER reject_cash_entry")
    assert [%{"status" => "applied", "revision" => 2}] = Reservations.submit_batch([operation])
  end

  test "retries a busy BEGIN without running the callback more than once", %{repo: repo} do
    parent = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:group_stay, :repo, :query],
      &__MODULE__.report_busy_begin/4,
      parent
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    holder =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)

        Repo.transact(
          fn ->
            send(parent, :locked)

            receive do
              :release -> {:ok, :released}
            end
          end,
          mode: :immediate
        )
      end)

    assert_receive :locked, 5_000

    writer =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)

        Repo.transact_immediate(fn ->
          send(parent, :callback_ran)
          {:ok, :applied}
        end)
      end)

    assert_receive :busy_begin, 5_000
    refute_receive :callback_ran, 0
    send(holder.pid, :release)
    assert Task.await(holder) == {:ok, :released}
    assert Task.await(writer) == {:ok, :applied}
    assert_receive :callback_ran
    refute_receive :callback_ran, 0
  end

  @doc false
  def report_busy_begin(_event, _measurements, metadata, parent) do
    case metadata do
      %{query: "begin", result: {:error, %Exqlite.Error{message: "database is locked"}}} ->
        send(parent, :busy_begin)

      _ ->
        :ok
    end
  end

  test "bookings, revisions, room order and settlements survive restart and migration reruns", %{
    options: options
  } do
    Reservations.submit_batch([
      open_group(),
      payment(),
      reschedule(),
      cancellation(),
      open_group(%{"group_id" => "still-active"}),
      payment(%{"group_id" => "still-active"})
    ])

    before = Reservations.get_group("group-81")
    ledger = Reservations.ledger()
    assert before.revision == 4

    assert ledger == %{
             cash_held_cents: 5_000,
             cash_refunded_cents: 5_000,
             cash_retained_cents: 0,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }

    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)

    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
    assert Reservations.get_group("group-81") == before
    assert Reservations.ledger() == ledger
    assert Reservations.get_group("still-active").revision == 2

    assert [%{"code" => "stale_revision", "actual_revision" => 2}, %{"revision" => 3}] =
             Reservations.submit_batch([
               payment(%{"group_id" => "still-active", "expected_revision" => 1}),
               payment(%{"group_id" => "still-active", "expected_revision" => 2})
             ])
  end

  test "credit lots and funding provenance survive restart and restore after migration reruns", %{
    options: options
  } do
    Reservations.submit_batch([
      open_group(),
      payment(),
      cancellation(%{"operation_id" => "cancel_group-1", "refund_method" => "hotel_credit"}),
      open_group(%{"group_id" => "target"}),
      credit_application(%{"group_id" => "target"})
    ])

    before = credit_snapshot()

    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
    assert credit_snapshot() == before
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 500
    assert Reservations.ledger(~D[2027-11-02]).credit_liability_cents == 5_000

    assert [%{"revision" => 3, "credit_issued_cents" => 0}] =
             Reservations.submit_batch([
               cancellation(%{"group_id" => "target"})
             ])

    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).lots == [
             %{
               source_operation_id: "cancel_group-1",
               remaining_cents: 5_500,
               expires_on: ~D[2027-11-01]
             }
           ]
  end

  test "upgrades original-release groups using booking dates without rewriting earlier facts" do
    # Recreate the original schema, then apply the complete upgrade chain.
    assert Ecto.Migrator.run(Repo, :down, to: 20_260_907_000_001, log: false) ==
             [20_260_907_000_003, 20_260_907_000_002, 20_260_907_000_001]

    legacy_groups =
      for {id, booked, plan, status} <- [
            {"old-flex", "2026-12-31", "flexible", "active"},
            {"new-flex", "2027-01-01", "flexible", "active"},
            {"advance", "2027-01-01", "advance_purchase", "active"},
            {"cancelled", "2026-12-31", "flexible", "cancelled"}
          ] do
        deposit = if plan == "advance_purchase", do: 30_000, else: 6_000

        %{
          group_id: id,
          guest_id: "guest-22",
          property_id: "ams-canal",
          booked_on: booked,
          arrival_on: "2028-03-01",
          departure_on: "2028-03-04",
          rate_plan: plan,
          status: status,
          revision: 4,
          rooms: Jason.encode!([%{room_id: "original", nightly_rate_cents: 10_000}]),
          lodging_total_cents: 30_000,
          deposit_due_cents: if(status == "active", do: deposit, else: 0),
          deposit_paid_cents: if(status == "active", do: 5_000, else: 0),
          inserted_at: "2026-12-31 00:00:00.000000",
          updated_at: "2027-02-01 00:00:00.000000"
        }
      end

    Repo.insert_all("groups", legacy_groups)

    for group <- legacy_groups do
      Repo.insert!(%CashEntry{
        group_id: group.group_id,
        operation_id: "legacy-payment",
        occurred_on: ~D[2027-01-01],
        kind: :payment,
        amount_cents: 5_000
      })
    end

    Repo.insert!(%CashEntry{
      group_id: "cancelled",
      operation_id: "legacy-cancel",
      occurred_on: ~D[2027-02-01],
      kind: :refund,
      amount_cents: 5_000
    })

    cash_before = Repo.all(CashEntry)

    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) ==
             [20_260_907_000_001, 20_260_907_000_002, 20_260_907_000_003]

    for {id, policy, deadline} <- [
          {"old-flex", "flex-14", ~D[2028-02-16]},
          {"new-flex", "flex-30", ~D[2028-01-31]},
          {"advance", "advance-nonrefundable", nil},
          {"cancelled", "flex-14", ~D[2028-02-16]}
        ] do
      group = Reservations.get_group(id)
      assert group.policy_version == policy
      assert group.revision == 4
      assert group.credit_paid_cents == 0
      assert group.updated_at == ~U[2027-02-01 00:00:00.000000Z]
      assert [%{room_id: "original"}] = group.rooms
      rendered = GroupStayWeb.GroupJSON.show(%{group: group}).data
      assert rendered.refundable_until == deadline
      assert rendered.cash_paid_cents == if(id == "cancelled", do: 0, else: 5_000)
    end

    assert Repo.all(CashEntry) == cash_before

    assert Reservations.ledger(~D[2028-02-01]) == %{
             cash_held_cents: 15_000,
             cash_refunded_cents: 5_000,
             cash_retained_cents: 0,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }

    assert [
             %{"refunded_cents" => 5_000, "revision" => 5},
             %{"retained_cents" => 5_000, "revision" => 5}
           ] =
             Reservations.submit_batch([
               cancellation(%{"group_id" => "old-flex", "occurred_on" => "2028-02-01"}),
               cancellation(%{"group_id" => "new-flex", "occurred_on" => "2028-02-01"})
             ])

    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
  end

  defp credit_snapshot do
    Enum.map([Group, CashEntry, CreditLot, CreditAllocation, OperationRecord], &Repo.all/1)
  end
end
