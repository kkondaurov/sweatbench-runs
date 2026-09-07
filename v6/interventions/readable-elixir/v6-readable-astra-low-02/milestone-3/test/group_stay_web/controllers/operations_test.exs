defmodule GroupStayWeb.OperationsTest do
  use GroupStayWeb.ConnCase
  import Ecto.Query
  alias GroupStay.{Operations, Repo, Reservations}

  defp opening do
    %{
      "operation_id" => "open",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "a", "nightly_rate_cents" => 10000},
        %{"room_id" => "b", "nightly_rate_cents" => 10000}
      ],
      "metadata" => %{"nested" => [1, true, nil, %{"b" => 2, "a" => 1}]}
    }
  end

  defp payment(id, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group",
        "amount_cents" => 100
      },
      attrs
    )
  end

  defp batch(ops) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => ops})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp read(id), do: build_conn() |> get("/api/v1/operations/#{id}")

  test "exact retries replay revisions and preserve submission and first commit order" do
    op = opening()
    [opened, paid, retried] = batch([op, payment("pay"), op])
    assert opened == retried
    assert paid["revision"] == 2
    assert batch([payment("pay")]) == [paid]
    assert Reservations.get_group("group").deposit_paid_cents == 100
    assert read("open") |> json_response(200) == %{"data" => opened}

    assert read("missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    records = Repo.all(from o in Operations, order_by: o.id)
    assert Enum.map(records, & &1.operation_id) == ["open", "pay"]
    assert hd(records).submission === op
    assert hd(records).type == "open_group"
    assert hd(records).result == opened

    # Send a separately encoded object in reversed key order.
    encoded =
      "{" <>
        Enum.map_join(Enum.reverse(Enum.sort(op)), ",", fn {k, v} ->
          Jason.encode!(k) <> ":" <> Jason.encode!(v)
        end) <> "}"

    response =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", "{\"operations\":[#{encoded}]}")
      |> json_response(200)

    assert response["results"] == [opened]

    for changed <- [
          Map.put(op, "rooms", Enum.reverse(op["rooms"])),
          Map.put(op, "metadata", %{"nested" => [1.0, true, nil, %{"a" => 1, "b" => 2}]}),
          Map.delete(op, "metadata")
        ] do
      assert [%{"code" => "operation_id_conflict"}] = batch([changed])
    end

    assert Repo.all(from o in Operations, order_by: o.id) == records
  end

  test "rejections remain original after state changes and corrected revisions conflict" do
    missing = payment("missing")

    [rejected, _, paid, stale, later] =
      batch([
        missing,
        opening(),
        payment("pay"),
        payment("stale", %{"expected_revision" => 1}),
        payment("later")
      ])

    assert rejected["code"] == "group_not_found"
    assert paid["revision"] == 2
    assert stale["actual_revision"] == 2
    assert later["revision"] == 3
    assert batch([missing, payment("stale", %{"expected_revision" => 1})]) == [rejected, stale]

    assert [%{"code" => "operation_id_conflict"}] =
             batch([payment("stale", %{"expected_revision" => 3})])

    assert read("stale") |> json_response(200) == %{"data" => stale}
    assert Reservations.get_group("group").revision == 3
  end

  test "replaying credit settlement and redemption does not duplicate financial effects" do
    cancellation = %{
      "operation_id" => "cancel",
      "type" => "cancel_group",
      "group_id" => "group",
      "occurred_on" => "2026-10-05",
      "refund_method" => "hotel_credit"
    }

    target = opening() |> Map.put("operation_id", "target") |> Map.put("group_id", "target")

    credit = %{
      "operation_id" => "credit",
      "type" => "apply_hotel_credit",
      "group_id" => "target",
      "occurred_on" => "2026-10-06",
      "amount_cents" => 110
    }

    ops = [opening(), payment("pay"), cancellation, target, credit]
    originals = batch(ops)
    balances = Reservations.ledger(~D[2026-10-06])
    assert balances.cash_converted_to_credit_cents == 100
    assert balances.credit_liability_cents == 110
    assert batch(ops) == originals
    assert Reservations.ledger(~D[2026-10-06]) == balances
    assert Repo.aggregate(GroupStay.Reservations.CreditLot, :count) == 1
    assert Repo.aggregate(GroupStay.Reservations.CreditAllocation, :count) == 1
    assert Reservations.get_group("target").revision == 2
  end

  test "invalid identifiable submissions are audited while unidentifiable entries continue" do
    invalid = %{"operation_id" => "invalid", "type" => ["unknown"], "extra" => %{"all" => true}}
    assert [first, second, %{"status" => "applied"}] = batch([invalid, invalid, opening()])
    assert first == second
    assert first["code"] == "invalid_operation"
    assert Repo.get_by!(Operations, operation_id: "invalid").submission == invalid

    assert Enum.all?(
             batch([nil, 12, %{}, %{"operation_id" => ""}]),
             &(&1["code"] == "invalid_operation")
           )

    assert Repo.aggregate(Operations, :count) == 2
  end

  test "handled rejection rolls back partial domain writes but commits its result" do
    result =
      Operations.execute(opening(), fn ->
        Repo.query!(
          "INSERT INTO credit_lots (guest_id, source_operation_id, remaining_cents, expires_on) VALUES ('guest', 'partial', 100, '2027-01-01')"
        )

        Operations.reject(%{code: "insufficient_credit"})
      end)

    assert result.code == "insufficient_credit"
    assert Repo.all(GroupStay.Reservations.CreditLot) == []
    assert Operations.get_result("open") == result
  end

  test "unexpected server faults roll back the operation, abort the batch, and permit retry" do
    Repo.query!("""
    CREATE TRIGGER fail_audit BEFORE INSERT ON partner_operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
    """)

    assert_error_sent 500, fn ->
      batch([opening(), payment("fault"), payment("unreached")])
    end

    assert Reservations.get_group("group").revision == 1
    assert Operations.get_result("open").status == "applied"
    assert Operations.get_result("fault") == nil
    assert Operations.get_result("unreached") == nil
    Repo.query!("DROP TRIGGER fail_audit")

    assert [%{revision: 1}, %{revision: 2}, %{revision: 3}] =
             Reservations.submit([opening(), payment("fault"), payment("unreached")])

    assert Reservations.ledger().cash_held_cents == 200
  end
end
