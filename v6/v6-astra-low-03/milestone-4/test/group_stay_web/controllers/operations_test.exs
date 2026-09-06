defmodule GroupStayWeb.OperationsTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Repo, Operation}
  import Ecto.Query

  defp open do
    %{
      "operation_id" => "open",
      "type" => "open_group",
      "group_id" => "group",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "occurred_on" => "2026-01-01",
      "arrival_on" => "2026-12-01",
      "departure_on" => "2026-12-02",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "a", "nightly_rate_cents" => 10000},
        %{"room_id" => "b", "nightly_rate_cents" => 5000}
      ],
      "extra" => %{"nested" => [true, nil, %{"a" => 1, "b" => 2}]}
    }
  end

  defp op(id, type, attrs \\ %{}),
    do:
      Map.merge(
        %{
          "operation_id" => id,
          "type" => type,
          "group_id" => "group",
          "occurred_on" => "2026-02-01"
        },
        attrs
      )

  defp batch(ops),
    do:
      build_conn()
      |> post("/api/v1/partner-batches", %{"operations" => ops})
      |> json_response(200)
      |> Map.fetch!("results")

  test "exact retries, conflicts, audit contents, commit order and result-only lookup" do
    payment = op("pay", "record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1})

    [opened, paid, moved] =
      batch([
        open(),
        payment,
        op("move", "reschedule_group", %{"new_arrival_on" => "2027-01-01"})
      ])

    assert batch([Map.new(Enum.reverse(Map.to_list(open()))), payment]) == [opened, paid]
    assert moved["revision"] == 3

    for changed <- [
          Map.put(open(), "rooms", Enum.reverse(open()["rooms"])),
          Map.put(payment, "amount_cents", 100.0),
          Map.delete(open(), "extra")
        ] do
      assert [%{"code" => "operation_id_conflict"}] = batch([changed])
    end

    records = Repo.all(from o in Operation, order_by: o.id)
    assert Enum.map(records, & &1.operation_id) == ["open", "pay", "move"]
    assert hd(records).submission == open()
    assert hd(records).type == "open_group"

    assert build_conn() |> get("/api/v1/operations/pay") |> json_response(200) == %{
             "data" => paid
           }

    assert build_conn() |> get("/api/v1/operations/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    assert GroupStay.Reservations.get_group("group").revision == 3
    assert GroupStay.Reservations.ledger().cash_held_cents == 100
  end

  test "rejections and stale details remain fixed while later operations proceed" do
    missing = op("missing", "record_cash_payment", %{"amount_cents" => 100})
    stale = op("stale", "cancel_group", %{"expected_revision" => 0})

    [rejected, _, stale_result, _] =
      batch([missing, open(), stale, op("pay", "record_cash_payment", %{"amount_cents" => 100})])

    assert rejected["code"] == "group_not_found"
    assert stale_result["actual_revision"] == 1
    assert batch([missing, stale]) == [rejected, stale_result]

    assert [%{"code" => "operation_id_conflict"}] =
             batch([Map.put(stale, "expected_revision", 2)])

    invalid = %{"operation_id" => "invalid", "type" => "unknown", "extra" => [1, 2]}
    [invalid_result] = batch([invalid])
    assert invalid_result["code"] == "invalid_operation"
    assert Repo.get_by!(Operation, operation_id: "invalid").submission == invalid
    assert batch([invalid]) == [invalid_result]
  end

  test "retrying credit issuance, redemption and restoration has at-most-once economics" do
    cancel = op("cancel", "cancel_group", %{"refund_method" => "hotel_credit"})
    target = Map.merge(open(), %{"operation_id" => "target", "group_id" => "target"})
    apply = op("apply", "apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 110})
    restore = op("restore", "cancel_group", %{"group_id" => "target"})

    ops = [
      open(),
      op("pay", "record_cash_payment", %{"amount_cents" => 100}),
      cancel,
      target,
      apply,
      restore
    ]

    results = batch(ops)
    assert batch(ops) == results
    assert GroupStay.Reservations.credit("guest", ~D[2026-02-01]).available_cents == 110
    assert GroupStay.Reservations.ledger(~D[2026-02-01]).cash_converted_to_credit_cents == 100
    assert Repo.aggregate(GroupStay.CreditLot, :count) == 1
  end

  test "unexpected failure rolls back domain and audit, aborts batch and permits retry" do
    Repo.query!(
      "CREATE TRIGGER fail_audit BEFORE INSERT ON operations WHEN NEW.operation_id = 'pay' BEGIN SELECT RAISE(ABORT, 'injected failure'); END"
    )

    payment = op("pay", "record_cash_payment", %{"amount_cents" => 100})
    assert_error_sent 500, fn -> batch([open(), payment, op("later", "cancel_group")]) end
    assert GroupStay.Reservations.get_group("group").revision == 1
    assert Repo.get_by(Operation, operation_id: "pay") == nil
    assert Repo.get_by(Operation, operation_id: "later") == nil
    assert Repo.get_by!(Operation, operation_id: "open")
    Repo.query!("DROP TRIGGER fail_audit")
    assert [%{"revision" => 1}, %{"revision" => 2}] = batch([open(), payment])
  end
end
