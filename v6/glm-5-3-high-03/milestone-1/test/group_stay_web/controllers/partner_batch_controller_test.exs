defmodule GroupStayWeb.PartnerBatchControllerTest do
  @moduledoc """
  End-to-end coverage of the partner batch endpoint: every operation type,
  every rejection code, the batch semantics, and the revision contract.
  """

  use GroupStayWeb.ConnCase, async: false

  import GroupStay.PartnerHelpers

  describe "batch shape" do
    test "a body without an operations array is an invalid batch" do
      conn = post_invalid_batch(%{})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}

      conn = post_invalid_batch(%{"operations" => "nope"})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "an empty batch returns one result per operation (none)" do
      conn = post_batch([])
      assert results(conn) == []
    end

    test "results come back in operation order" do
      conn =
        post_batch([
          open_group_operation("op-1", %{"group_id" => "group-a"}),
          open_group_operation("op-2", %{"group_id" => "group-b"})
        ])

      assert Enum.map(results(conn), & &1["operation_id"]) == ["op-1", "op-2"]
      assert Enum.map(results(conn), & &1["group_id"]) == ["group-a", "group-b"]
    end

    test "an operation that is not an object is rejected with invalid_operation" do
      conn = post_batch(["not-an-object"])

      assert results(conn) == [%{"status" => "rejected", "code" => "invalid_operation"}]
    end

    test "a rejected operation does not undo earlier operations nor stop later ones" do
      conn =
        post_batch([
          open_group_operation("op-1"),
          %{"operation_id" => "op-2", "type" => "explode_group", "occurred_on" => "2026-10-04"},
          pay_operation("op-3", "group-81", 5_000)
        ])

      [first, second, third] = results(conn)

      assert first["status"] == "applied"

      assert second == %{
               "operation_id" => "op-2",
               "status" => "rejected",
               "code" => "invalid_operation"
             }

      assert third["status"] == "applied"

      # The payment in the same batch observed the group opened above it.
      assert third["outstanding_deposit_cents"] == 14_500
    end

    test "an operation can observe changes made by an earlier operation in the batch" do
      conn =
        post_batch([
          open_group_operation("op-1"),
          pay_operation("op-2", "group-81", 19_500, %{"expected_revision" => 1}),
          cancel_operation("op-3", "group-81", %{"expected_revision" => 2})
        ])

      [first, second, third] = results(conn)

      assert first["revision"] == 1
      assert second["outstanding_deposit_cents"] == 0
      assert third["refunded_cents"] == 19_500
      assert third["revision"] == 3
    end

    test "opening the same group twice inside one batch sees the earlier open" do
      conn =
        post_batch([
          open_group_operation("op-1"),
          open_group_operation("op-2")
        ])

      [first, second] = results(conn)

      assert first["status"] == "applied"
      assert second["status"] == "rejected"
      assert second["code"] == "group_already_exists"
    end
  end

  describe "open_group" do
    test "applies the documented example and reports the deposit and revision" do
      conn = post_batch([open_group_operation("op-1001")])

      assert results(conn) == [
               %{
                 "operation_id" => "op-1001",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]
    end

    test "an advance_purchase room requires its full lodging amount as deposit" do
      conn = post_batch([open_group_operation("op-1", %{"rate_plan" => "advance_purchase"})])

      assert hd(results(conn))["deposit_due_cents"] == 97_500
    end

    test "flexible deposits round each room to the nearest cent, half upward" do
      conn =
        post_batch([
          open_group_operation("op-1", %{
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 153}]
          })
        ])

      # 153 * 20% = 30.6 -> 31
      assert hd(results(conn))["deposit_due_cents"] == 31

      conn =
        post_batch([
          open_group_operation("op-1", %{
            "group_id" => "group-82",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 151}]
          })
        ])

      # 151 * 20% = 30.2 -> 30
      assert hd(results(conn))["deposit_due_cents"] == 30
    end

    test "room deposits are rounded separately before summing" do
      conn =
        post_batch([
          open_group_operation("op-1", %{
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 153},
              %{"room_id" => "room-b", "nightly_rate_cents" => 153}
            ]
          })
        ])

      # each room rounds 30.6 up to 31, so the group deposit is 62
      assert hd(results(conn))["deposit_due_cents"] == 62
    end

    test "rejects a duplicate group identifier" do
      post_batch([open_group_operation("op-1")])
      conn = post_batch([open_group_operation("op-2")])

      assert hd(results(conn)) == %{
               "operation_id" => "op-2",
               "status" => "rejected",
               "code" => "group_already_exists",
               "group_id" => "group-81"
             }
    end

    test "rejects stays without at least one night" do
      for {label, overrides} <- [
            {"same day", %{"arrival_on" => "2026-12-10", "departure_on" => "2026-12-10"}},
            {"inverted", %{"arrival_on" => "2026-12-13", "departure_on" => "2026-12-10"}},
            {"unparseable arrival", %{"arrival_on" => "2026-13-40"}},
            {"unparseable departure", %{"departure_on" => "not-a-date"}},
            {"missing departure", %{"departure_on" => nil}}
          ] do
        conn = post_batch([open_group_operation("op-1", overrides)])
        result = hd(results(conn))
        assert result["status"] == "rejected", label
        assert result["code"] == "invalid_stay", label
      end
    end

    test "rejects invalid room lists" do
      for {label, overrides} <- [
            {"no rooms", %{"rooms" => []}},
            {"missing rooms", %{"rooms" => nil}},
            {"not a list", %{"rooms" => "room-a"}},
            {"duplicate room ids",
             %{
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
               ]
             }},
            {"room without a rate", %{"rooms" => [%{"room_id" => "room-a"}]}},
            {"room without an id", %{"rooms" => [%{"nightly_rate_cents" => 15_000}]}},
            {"room with a negative rate",
             %{"rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => -1}]}},
            {"room with a non-integer rate",
             %{"rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => "15000"}]}}
          ] do
        conn = post_batch([open_group_operation("op-1", overrides)])
        result = hd(results(conn))
        assert result["status"] == "rejected", label
        assert result["code"] == "invalid_rooms", label
      end
    end

    test "rejects unknown and missing rate plans" do
      conn = post_batch([open_group_operation("op-1", %{"rate_plan" => "corporate"})])
      assert hd(results(conn))["code"] == "invalid_rate_plan"

      conn = post_batch([open_group_operation("op-1", %{"rate_plan" => nil})])
      assert hd(results(conn))["code"] == "invalid_rate_plan"
    end

    test "rejects operations missing data needed to identify and apply them" do
      for {label, overrides} <- [
            {"missing guest", %{"guest_id" => nil}},
            {"missing property", %{"property_id" => nil}},
            {"missing group id", %{"group_id" => nil}},
            {"missing operation id", %{"operation_id" => nil}},
            {"missing occurred_on", %{"occurred_on" => nil}},
            {"unparseable occurred_on", %{"occurred_on" => "yesterday"}}
          ] do
        conn = post_batch([open_group_operation("op-1", overrides)])
        result = hd(results(conn))
        assert result["status"] == "rejected", label
        assert result["code"] == "invalid_operation", label
      end
    end

    test "expected_revision is not used by open_group" do
      conn = post_batch([open_group_operation("op-1", %{"expected_revision" => 99})])

      assert hd(results(conn))["status"] == "applied"
      assert hd(results(conn))["revision"] == 1
    end
  end

  describe "record_cash_payment" do
    test "applies cash to the outstanding deposit and increments the revision" do
      post_batch([open_group_operation("op-1")])
      conn = post_batch([pay_operation("op-2", "group-81", 5_000)])

      assert results(conn) == [
               %{
                 "operation_id" => "op-2",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             ]
    end

    test "a payment equal to the outstanding deposit settles it exactly" do
      post_batch([open_group_operation("op-1")])
      conn = post_batch([pay_operation("op-2", "group-81", 19_500)])

      assert hd(results(conn))["outstanding_deposit_cents"] == 0

      conn = post_batch([pay_operation("op-3", "group-81", 1)])
      assert hd(results(conn))["code"] == "payment_exceeds_outstanding"
    end

    test "rejects a payment naming a missing group" do
      conn = post_batch([pay_operation("op-1", "group-none", 100)])

      assert hd(results(conn)) == %{
               "operation_id" => "op-1",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "group-none"
             }
    end

    test "rejects amounts that are not usable as a payment" do
      post_batch([open_group_operation("op-1")])

      for {label, amount} <- [
            {"zero", 0},
            {"negative", -100},
            {"string", "5000"},
            {"fractional", 50.5},
            {"missing", nil}
          ] do
        conn = post_batch([pay_operation("op-2", "group-81", amount)])
        result = hd(results(conn))
        assert result["status"] == "rejected", label
        assert result["code"] == "invalid_amount", label
      end
    end

    test "rejects a payment exceeding the outstanding deposit" do
      post_batch([open_group_operation("op-1")])
      conn = post_batch([pay_operation("op-2", "group-81", 19_501)])

      assert hd(results(conn))["code"] == "payment_exceeds_outstanding"
    end

    test "rejects a payment to a cancelled group" do
      post_batch([open_group_operation("op-1"), cancel_operation("op-2", "group-81")])
      conn = post_batch([pay_operation("op-3", "group-81", 100)])

      assert hd(results(conn))["code"] == "group_not_active"
    end
  end

  describe "reschedule_group" do
    test "shifts departure by the same number of days and increments the revision" do
      post_batch([open_group_operation("op-1")])
      conn = post_batch([reschedule_operation("op-2", "group-81", "2026-12-15")])

      assert results(conn) == [
               %{
                 "operation_id" => "op-2",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2026-12-15",
                 "new_departure_on" => "2026-12-18",
                 "revision" => 2
               }
             ]

      group = json_response(get_group("group-81"), 200)["data"]

      assert group["arrival_on"] == "2026-12-15"
      assert group["departure_on"] == "2026-12-18"
      # the length and price of the stay do not change
      assert group["lodging_total_cents"] == 97_500
      assert group["deposit_due_cents"] == 19_500
    end

    test "rescheduling to the current arrival still increments the revision" do
      post_batch([open_group_operation("op-1")])
      conn = post_batch([reschedule_operation("op-2", "group-81", "2026-12-10")])

      result = hd(results(conn))
      assert result["status"] == "applied"
      assert result["revision"] == 2
      assert result["new_arrival_on"] == "2026-12-10"
    end

    test "rejects unusable dates" do
      post_batch([open_group_operation("op-1")])

      for {label, new_arrival_on} <- [
            {"same as operation date", "2026-10-04"},
            {"before the operation date", "2026-09-01"},
            {"unparseable", "tomorrow"},
            {"missing", nil}
          ] do
        conn = post_batch([reschedule_operation("op-2", "group-81", new_arrival_on)])
        result = hd(results(conn))
        assert result["status"] == "rejected", label
        assert result["code"] == "invalid_stay", label
      end
    end

    test "rejects a reschedule naming a missing group" do
      conn = post_batch([reschedule_operation("op-1", "group-none", "2026-12-15")])

      assert hd(results(conn))["code"] == "group_not_found"
    end

    test "rejects a reschedule to a cancelled group" do
      post_batch([open_group_operation("op-1"), cancel_operation("op-2", "group-81")])
      conn = post_batch([reschedule_operation("op-3", "group-81", "2026-12-15")])

      assert hd(results(conn))["code"] == "group_not_active"
    end
  end

  describe "cancel_group" do
    test "refunds flexible cash when cancelled at least 14 days before arrival" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 10_000)])

      # arrival 2026-12-10, cancelled 2026-11-26: exactly 14 days before
      conn = post_batch([cancel_operation("op-3", "group-81", %{"occurred_on" => "2026-11-26"})])

      assert results(conn) == [
               %{
                 "operation_id" => "op-3",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "refunded_cents" => 10_000,
                 "retained_cents" => 0,
                 "revision" => 3
               }
             ]
    end

    test "retains flexible cash when cancelled 13 days before arrival" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 10_000)])

      conn = post_batch([cancel_operation("op-3", "group-81", %{"occurred_on" => "2026-11-27"})])

      result = hd(results(conn))
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 10_000
    end

    test "advance_purchase reservations are always non-refundable" do
      post_batch([
        open_group_operation("op-1", %{"rate_plan" => "advance_purchase"}),
        pay_operation("op-2", "group-81", 97_500)
      ])

      conn = post_batch([cancel_operation("op-3", "group-81", %{"occurred_on" => "2026-10-04"})])

      result = hd(results(conn))
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 97_500
    end

    test "an unpaid group cancels with nothing refunded or retained" do
      post_batch([open_group_operation("op-1")])
      conn = post_batch([cancel_operation("op-2", "group-81")])

      result = hd(results(conn))
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["revision"] == 2
    end

    test "later operations on a cancelled group are rejected" do
      post_batch([open_group_operation("op-1"), cancel_operation("op-2", "group-81")])

      conn =
        post_batch([
          pay_operation("op-3", "group-81", 100),
          reschedule_operation("op-4", "group-81", "2026-12-20"),
          cancel_operation("op-5", "group-81")
        ])

      assert Enum.map(results(conn), & &1["code"]) ==
               ["group_not_active", "group_not_active", "group_not_active"]
    end

    test "rejects a cancellation naming a missing group" do
      conn = post_batch([cancel_operation("op-1", "group-none")])

      assert hd(results(conn))["code"] == "group_not_found"
    end
  end

  describe "revisions" do
    test "every applied operation increments the revision exactly once" do
      conn =
        post_batch([
          open_group_operation("op-1"),
          pay_operation("op-2", "group-81", 1_000),
          reschedule_operation("op-3", "group-81", "2026-12-11"),
          cancel_operation("op-4", "group-81", %{"occurred_on" => "2026-11-26"})
        ])

      assert Enum.map(results(conn), & &1["revision"]) == [1, 2, 3, 4]

      group = json_response(get_group("group-81"), 200)["data"]
      assert group["revision"] == 4
    end

    test "rejections never increment the revision" do
      post_batch([open_group_operation("op-1")])

      post_batch([
        pay_operation("op-2", "group-81", 999_999),
        reschedule_operation("op-3", "group-81", nil),
        cancel_operation("op-4", "group-none")
      ])

      group = json_response(get_group("group-81"), 200)["data"]
      assert group["revision"] == 1
    end

    test "an operation with a matching expected_revision is applied" do
      post_batch([open_group_operation("op-1")])
      conn = post_batch([pay_operation("op-2", "group-81", 5_000, %{"expected_revision" => 1})])

      assert hd(results(conn))["status"] == "applied"
      assert hd(results(conn))["revision"] == 2
    end

    test "a stale revision is rejected with the fields from the API document" do
      post_batch([open_group_operation("op-1001"), pay_operation("op-x", "group-81", 1_000)])

      conn =
        post_batch([pay_operation("op-1002", "group-81", 5_000, %{"expected_revision" => 1})])

      assert results(conn) == [
               %{
                 "operation_id" => "op-1002",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ]

      group = json_response(get_group("group-81"), 200)["data"]
      assert group["revision"] == 2
      assert group["deposit_paid_cents"] == 1_000

      # the stale rejection leaves the group and the ledger unchanged
      assert json_response(get_ledger(), 200)["data"] == %{
               "cash_held_cents" => 1_000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
    end

    test "a stale rejection is evaluated before other domain rules" do
      post_batch([open_group_operation("op-1"), cancel_operation("op-2", "group-81")])

      conn =
        post_batch([
          pay_operation("op-3", "group-81", 0, %{"expected_revision" => 1}),
          cancel_operation("op-4", "group-81", %{"expected_revision" => 99})
        ])

      assert Enum.map(results(conn), & &1["code"]) == ["stale_revision", "stale_revision"]
    end

    test "group existence is resolved before comparing revisions" do
      conn = post_batch([pay_operation("op-1", "group-none", 100, %{"expected_revision" => 3})])

      assert hd(results(conn))["code"] == "group_not_found"
    end

    test "omitting expected_revision preserves the unconditional behavior" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 1_000)])
      conn = post_batch([pay_operation("op-3", "group-81", 1_000)])

      assert hd(results(conn))["status"] == "applied"
      assert hd(results(conn))["revision"] == 3
    end
  end
end
