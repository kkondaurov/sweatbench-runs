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
          open_group_operation("op-2", %{
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
      cases = [
        {"same day", %{"arrival_on" => "2026-12-10", "departure_on" => "2026-12-10"}},
        {"inverted", %{"arrival_on" => "2026-12-13", "departure_on" => "2026-12-10"}},
        {"unparseable arrival", %{"arrival_on" => "2026-13-40"}},
        {"unparseable departure", %{"departure_on" => "not-a-date"}},
        {"missing departure", %{"departure_on" => nil}}
      ]

      for {{label, overrides}, n} <- Enum.with_index(cases) do
        conn = post_batch([open_group_operation("op-#{n}", overrides)])
        result = hd(results(conn))
        assert result["status"] == "rejected", label
        assert result["code"] == "invalid_stay", label
      end
    end

    test "rejects invalid room lists" do
      cases = [
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
      ]

      for {{label, overrides}, n} <- Enum.with_index(cases) do
        conn = post_batch([open_group_operation("op-#{n}", overrides)])
        result = hd(results(conn))
        assert result["status"] == "rejected", label
        assert result["code"] == "invalid_rooms", label
      end
    end

    test "rejects unknown and missing rate plans" do
      conn = post_batch([open_group_operation("op-1", %{"rate_plan" => "corporate"})])
      assert hd(results(conn))["code"] == "invalid_rate_plan"

      conn = post_batch([open_group_operation("op-2", %{"rate_plan" => nil})])
      assert hd(results(conn))["code"] == "invalid_rate_plan"
    end

    test "rejects operations missing data needed to identify and apply them" do
      cases = [
        {"missing guest", %{"guest_id" => nil}},
        {"missing property", %{"property_id" => nil}},
        {"missing group id", %{"group_id" => nil}},
        {"missing operation id", %{"operation_id" => nil}},
        {"missing occurred_on", %{"occurred_on" => nil}},
        {"unparseable occurred_on", %{"occurred_on" => "yesterday"}}
      ]

      for {{label, overrides}, n} <- Enum.with_index(cases) do
        conn = post_batch([open_group_operation("op-#{n}", overrides)])
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

      cases = [
        {"zero", 0},
        {"negative", -100},
        {"string", "5000"},
        {"fractional", 50.5},
        {"missing", nil}
      ]

      for {{label, amount}, n} <- Enum.with_index(cases) do
        conn = post_batch([pay_operation("op-#{n + 2}", "group-81", amount)])
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
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-12-01",
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

      cases = [
        {"same as operation date", "2026-10-04"},
        {"before the operation date", "2026-09-01"},
        {"unparseable", "tomorrow"},
        {"missing", nil}
      ]

      for {{label, new_arrival_on}, n} <- Enum.with_index(cases) do
        conn = post_batch([reschedule_operation("op-#{n + 2}", "group-81", new_arrival_on)])
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
                 "credit_issued_cents" => 0,
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

  describe "policy versions" do
    test "a flexible group booked before 2027-01-01 keeps the 14-day window" do
      post_batch([open_group_operation("op-1", %{"occurred_on" => "2026-12-31"})])

      data = json_response(get_group("group-81"), 200)["data"]
      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2026-11-26"
    end

    test "a flexible group booked on or after 2027-01-01 uses the 30-day window" do
      post_batch([
        open_group_operation("op-1", %{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-04-01",
          "departure_on" => "2027-04-04"
        })
      ])

      data = json_response(get_group("group-81"), 200)["data"]
      assert data["policy_version"] == "flex-30"
      assert data["refundable_until"] == "2027-03-02"
    end

    test "cancellation on the refundable_until date is refundable for flex-30" do
      post_batch([
        open_group_operation("op-1", %{
          "occurred_on" => "2027-01-15",
          "arrival_on" => "2027-04-01",
          "departure_on" => "2027-04-04"
        }),
        pay_operation("op-2", "group-81", 10_000, %{"occurred_on" => "2027-01-16"})
      ])

      conn =
        post_batch([cancel_operation("op-3", "group-81", %{"occurred_on" => "2027-03-02"})])

      assert hd(results(conn))["refunded_cents"] == 10_000

      post_batch([
        open_group_operation("op-4", %{
          "group_id" => "group-82",
          "occurred_on" => "2027-01-15",
          "arrival_on" => "2027-04-01",
          "departure_on" => "2027-04-04"
        }),
        pay_operation("op-5", "group-82", 10_000, %{"occurred_on" => "2027-01-16"})
      ])

      conn =
        post_batch([cancel_operation("op-6", "group-82", %{"occurred_on" => "2027-03-03"})])

      assert hd(results(conn))["refunded_cents"] == 0
      assert hd(results(conn))["retained_cents"] == 10_000
    end

    test "an advance-purchase group is non-refundable with a null refundable_until" do
      post_batch([open_group_operation("op-1", %{"rate_plan" => "advance_purchase"})])

      data = json_response(get_group("group-81"), 200)["data"]
      assert data["policy_version"] == "advance-nonrefundable"
      assert data["refundable_until"] == nil
    end

    test "rescheduling never moves a group to a newer policy" do
      post_batch([
        open_group_operation("op-1", %{
          "occurred_on" => "2026-12-31",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        }),
        reschedule_operation("op-2", "group-81", "2027-07-01", %{"occurred_on" => "2027-01-05"})
      ])

      result = hd(results(post_batch([reschedule_operation("op-3", "group-81", "2027-08-01")])))
      assert result["policy_version"] == "flex-14"
      assert result["refundable_until"] == "2027-07-18"

      data = json_response(get_group("group-81"), 200)["data"]
      assert data["policy_version"] == "flex-14"
      assert data["arrival_on"] == "2027-08-01"
      assert data["refundable_until"] == "2027-07-18"
    end
  end

  describe "cancelling into hotel credit" do
    test "hotel credit settles the cash portion as a credit lot" do
      conn =
        post_batch([
          open_group_operation("op-1"),
          pay_operation("op-2", "group-81", 10_000),
          cancel_operation("op-3", "group-81", %{
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit"
          })
        ])

      assert result_for(conn, "op-3") == %{
               "operation_id" => "op-3",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 11_000,
               "revision" => 3
             }

      # the cash moved to the conversion total and became a credit liability
      assert json_response(get_ledger("2026-12-01"), 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 10_000,
               "credit_liability_cents" => 11_000
             }

      # available through 2027-11-26, expiring on 2027-11-27
      assert json_response(get_guest_credit("guest-22", "2027-11-26"), 200)["data"] == %{
               "guest_id" => "guest-22",
               "available_cents" => 11_000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-3",
                   "remaining_cents" => 11_000,
                   "expires_on" => "2027-11-27"
                 }
               ]
             }

      assert json_response(get_guest_credit("guest-22", "2027-11-27"), 200)["data"] == %{
               "guest_id" => "guest-22",
               "available_cents" => 0,
               "lots" => []
             }
    end

    test "the 10% bonus rounds half a cent upward" do
      conn =
        post_batch([
          open_group_operation("op-1"),
          pay_operation("op-2", "group-81", 10_005),
          cancel_operation("op-3", "group-81", %{
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit"
          })
        ])

      # 10_005 * 10% = 1000.5 -> 1001, so the lot is worth 11_006
      assert result_for(conn, "op-3")["credit_issued_cents"] == 11_006
    end

    test "hotel credit is not a way around a non-refundable policy" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 10_000)])

      conn =
        post_batch([
          cancel_operation("op-3", "group-81", %{
            "occurred_on" => "2026-11-27",
            "refund_method" => "hotel_credit"
          })
        ])

      assert hd(results(conn)) == %{
               "operation_id" => "op-3",
               "status" => "rejected",
               "code" => "refund_method_not_available",
               "group_id" => "group-81"
             }

      # the group is left active and the revision does not advance
      data = json_response(get_group("group-81"), 200)["data"]
      assert data["status"] == "active"
      assert data["revision"] == 2

      # advance purchase is never refundable either
      post_batch([
        open_group_operation("op-4", %{
          "group_id" => "group-82",
          "rate_plan" => "advance_purchase"
        })
      ])

      conn =
        post_batch([
          cancel_operation("op-5", "group-82", %{
            "occurred_on" => "2026-10-04",
            "refund_method" => "hotel_credit"
          })
        ])

      assert hd(results(conn))["code"] == "refund_method_not_available"
    end

    test "an unknown refund_method is rejected" do
      post_batch([open_group_operation("op-1")])

      conn =
        post_batch([cancel_operation("op-2", "group-81", %{"refund_method" => "voucher"})])

      assert hd(results(conn))["code"] == "invalid_operation"
    end

    test "an unpaid group cancels into hotel credit with nothing issued" do
      conn =
        post_batch([
          open_group_operation("op-1"),
          cancel_operation("op-2", "group-81", %{"refund_method" => "hotel_credit"})
        ])

      result = result_for(conn, "op-2")
      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      assert json_response(get_guest_credit("guest-22"), 200)["data"]["lots"] == []
    end

    test "credit issued in a batch is usable by a later operation in the same batch" do
      conn =
        post_batch([
          open_group_operation("op-1"),
          pay_operation("op-2", "group-81", 10_000),
          cancel_operation("op-3", "group-81", %{
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit"
          }),
          open_group_operation("op-4", %{"group_id" => "group-82"}),
          apply_credit_operation("op-5", "group-82", 11_000, %{"occurred_on" => "2026-11-27"})
        ])

      assert Enum.map(results(conn), & &1["status"]) == [
               "applied",
               "applied",
               "applied",
               "applied",
               "applied"
             ]

      assert hd(results(conn) |> Enum.reverse())["outstanding_deposit_cents"] == 8_500
    end
  end

  describe "apply_hotel_credit" do
    test "applies credit to the outstanding deposit and increments the revision" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation("op-4", %{"group_id" => "group-82"})
      ])

      conn =
        post_batch([
          apply_credit_operation("op-5", "group-82", 5_000, %{"occurred_on" => "2026-11-27"})
        ])

      assert results(conn) == [
               %{
                 "operation_id" => "op-5",
                 "status" => "applied",
                 "group_id" => "group-82",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             ]

      data = json_response(get_group("group-82"), 200)["data"]
      assert data["deposit_paid_cents"] == 5_000
      assert data["cash_paid_cents"] == 0
      assert data["credit_paid_cents"] == 5_000

      # the lot was drawn down but the liability is unchanged
      assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"][
               "available_cents"
             ] ==
               6_000

      assert json_response(get_ledger("2026-12-01"), 200)["data"]["credit_liability_cents"] ==
               11_000
    end

    test "a group funded by both cash and credit reports both portions" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation("op-4", %{"group_id" => "group-82"}),
        pay_operation("op-5", "group-82", 4_000),
        apply_credit_operation("op-6", "group-82", 5_000, %{"occurred_on" => "2026-11-27"})
      ])

      data = json_response(get_group("group-82"), 200)["data"]
      assert data["cash_paid_cents"] == 4_000
      assert data["credit_paid_cents"] == 5_000
      assert data["deposit_paid_cents"] == 9_000

      # only the cash portion counts as cash held
      assert json_response(get_ledger("2026-12-01"), 200)["data"]["cash_held_cents"] == 4_000
    end

    test "consumes lots by earliest expiry, then by source_operation_id" do
      post_batch([
        # lot A expires 2027-11-11
        open_group_operation("op-1", %{"group_id" => "group-a"}),
        pay_operation("op-2", "group-a", 10_000),
        cancel_operation("cancel-a", "group-a", %{
          "occurred_on" => "2026-11-10",
          "refund_method" => "hotel_credit"
        }),
        # lot B expires 2027-11-21
        open_group_operation("op-3", %{"group_id" => "group-b"}),
        pay_operation("op-4", "group-b", 10_000),
        cancel_operation("cancel-b", "group-b", %{
          "occurred_on" => "2026-11-20",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation("op-5", %{"group_id" => "group-c"})
      ])

      conn =
        post_batch([
          apply_credit_operation("op-6", "group-c", 15_000, %{"occurred_on" => "2026-11-27"})
        ])

      assert hd(results(conn))["status"] == "applied"

      # the earlier-expiring lot is exhausted first, the later one drawn down
      assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"]["lots"] == [
               %{
                 "source_operation_id" => "cancel-b",
                 "remaining_cents" => 7_000,
                 "expires_on" => "2027-11-21"
               }
             ]
    end

    test "for equal expiries lots are consumed in source_operation_id order" do
      post_batch([
        open_group_operation("op-1", %{"group_id" => "group-a"}),
        pay_operation("op-2", "group-a", 10_000),
        cancel_operation("cancel-b", "group-a", %{
          "occurred_on" => "2026-11-20",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation("op-3", %{"group_id" => "group-b"}),
        pay_operation("op-4", "group-b", 10_000),
        cancel_operation("cancel-a", "group-b", %{
          "occurred_on" => "2026-11-20",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation("op-5", %{"group_id" => "group-c"})
      ])

      conn =
        post_batch([
          apply_credit_operation("op-6", "group-c", 5_000, %{"occurred_on" => "2026-11-27"})
        ])

      assert hd(results(conn))["status"] == "applied"

      assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"]["lots"] == [
               %{
                 "source_operation_id" => "cancel-a",
                 "remaining_cents" => 6_000,
                 "expires_on" => "2027-11-21"
               },
               %{
                 "source_operation_id" => "cancel-b",
                 "remaining_cents" => 11_000,
                 "expires_on" => "2027-11-21"
               }
             ]
    end

    test "expiry is evaluated using the operation's occurred_on date" do
      post_batch([
        # lot expires on 2027-11-27
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation("op-4", %{"group_id" => "group-82"})
      ])

      conn =
        post_batch([
          apply_credit_operation("op-5", "group-82", 1_000, %{"occurred_on" => "2027-11-27"})
        ])

      assert hd(results(conn))["code"] == "insufficient_credit"

      conn =
        post_batch([
          apply_credit_operation("op-6", "group-82", 1_000, %{"occurred_on" => "2027-11-26"})
        ])

      assert hd(results(conn))["status"] == "applied"
    end

    test "rejects applying more credit than the guest has" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation("op-4", %{"group_id" => "group-82"})
      ])

      conn =
        post_batch([
          apply_credit_operation("op-5", "group-82", 11_001, %{"occurred_on" => "2026-11-27"})
        ])

      assert hd(results(conn))["code"] == "insufficient_credit"

      # nothing was consumed and the revision did not advance
      assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"][
               "available_cents"
             ] == 11_000

      data = json_response(get_group("group-82"), 200)["data"]
      assert data["revision"] == 1
      assert data["credit_paid_cents"] == 0
    end

    test "rejects credit exceeding the outstanding deposit" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        }),
        # a small group: 20 cents of deposit due, 11_000 cents of credit
        open_group_operation("op-4", %{
          "group_id" => "group-82",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 100}]
        })
      ])

      conn =
        post_batch([
          apply_credit_operation("op-5", "group-82", 21, %{"occurred_on" => "2026-11-27"})
        ])

      assert hd(results(conn))["code"] == "payment_exceeds_outstanding"
    end

    test "rejects unusable amounts, missing groups, and inactive groups" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation("op-4", %{"group_id" => "group-82"})
      ])

      amount_cases = [
        {"zero", 0},
        {"negative", -100},
        {"string", "5000"},
        {"missing", nil}
      ]

      for {{label, amount}, n} <- Enum.with_index(amount_cases) do
        conn =
          post_batch([
            apply_credit_operation("op-#{n + 5}", "group-82", amount, %{
              "occurred_on" => "2026-11-27"
            })
          ])

        assert hd(results(conn))["code"] == "invalid_amount", label
      end

      conn =
        post_batch([
          apply_credit_operation("op-missing", "group-none", 100, %{"occurred_on" => "2026-11-27"})
        ])

      assert hd(results(conn))["code"] == "group_not_found"

      post_batch([cancel_operation("op-cancel", "group-82", %{"occurred_on" => "2026-11-28"})])

      conn =
        post_batch([
          apply_credit_operation("op-inactive", "group-82", 100, %{
            "occurred_on" => "2026-11-29"
          })
        ])

      assert hd(results(conn))["code"] == "group_not_active"
    end

    test "follows the revision contract" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation("op-4", %{"group_id" => "group-82"})
      ])

      conn =
        post_batch([
          apply_credit_operation("op-5", "group-82", 5_000, %{
            "occurred_on" => "2026-11-27",
            "expected_revision" => 1
          })
        ])

      assert hd(results(conn))["status"] == "applied"
      assert hd(results(conn))["revision"] == 2

      # a stale revision is rejected before the domain rules
      conn =
        post_batch([
          apply_credit_operation("op-6", "group-82", 999_999, %{
            "occurred_on" => "2026-11-28",
            "expected_revision" => 1
          })
        ])

      assert hd(results(conn)) == %{
               "operation_id" => "op-6",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-82",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end
  end

  describe "settling a group funded by credit" do
    test "a refundable cash cancellation restores applied credit to its lot" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation("op-4", %{
          "group_id" => "group-82",
          "arrival_on" => "2026-12-20",
          "departure_on" => "2026-12-23"
        }),
        apply_credit_operation("op-5", "group-82", 5_000, %{"occurred_on" => "2026-11-27"})
      ])

      conn =
        post_batch([
          cancel_operation("op-6", "group-82", %{
            "occurred_on" => "2026-12-01",
            "refund_method" => "cash"
          })
        ])

      result = hd(results(conn))
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      # the lot is whole again and the liability is unchanged
      assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"][
               "available_cents"
             ] == 11_000

      assert json_response(get_ledger("2026-12-01"), 200)["data"]["credit_liability_cents"] ==
               11_000
    end

    test "restored credit whose expiry has passed expires immediately" do
      post_batch([
        # lot expires on 2027-11-27
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        }),
        # a group whose refundable window is still open in 2028
        open_group_operation("op-4", %{
          "group_id" => "group-82",
          "arrival_on" => "2030-01-01",
          "departure_on" => "2030-01-04"
        }),
        apply_credit_operation("op-5", "group-82", 11_000, %{"occurred_on" => "2027-01-01"})
      ])

      # liability covers the credit applied to the active group
      assert json_response(get_ledger("2027-01-01"), 200)["data"]["credit_liability_cents"] ==
               11_000

      conn =
        post_batch([cancel_operation("op-6", "group-82", %{"occurred_on" => "2028-06-01"})])

      assert hd(results(conn))["status"] == "applied"

      # the restored amount expired instead of becoming available again
      assert json_response(get_guest_credit("guest-22"), 200)["data"]["lots"] == []
      assert json_response(get_ledger("2028-06-01"), 200)["data"]["credit_liability_cents"] == 0
    end

    test "a mixed group settles cash into credit and restores the applied credit" do
      post_batch([
        # 11_000 of credit for guest-22
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation("op-4", %{
          "group_id" => "group-82",
          "arrival_on" => "2026-12-20",
          "departure_on" => "2026-12-23"
        }),
        pay_operation("op-5", "group-82", 4_000),
        apply_credit_operation("op-6", "group-82", 5_000, %{"occurred_on" => "2026-11-27"})
      ])

      conn =
        post_batch([
          cancel_operation("op-7", "group-82", %{
            "occurred_on" => "2026-12-01",
            "refund_method" => "hotel_credit"
          })
        ])

      # the 4_000 of cash becomes a 4_400 lot; the applied 5_000 is restored
      assert result_for(conn, "op-7")["credit_issued_cents"] == 4_400
      assert result_for(conn, "op-7")["refunded_cents"] == 0
      assert result_for(conn, "op-7")["retained_cents"] == 0

      assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"]["lots"] == [
               %{
                 "source_operation_id" => "op-3",
                 "remaining_cents" => 11_000,
                 "expires_on" => "2027-11-27"
               },
               %{
                 "source_operation_id" => "op-7",
                 "remaining_cents" => 4_400,
                 "expires_on" => "2027-12-02"
               }
             ]

      assert json_response(get_ledger("2026-12-01"), 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 14_000,
               "credit_liability_cents" => 15_400
             }
    end

    test "a non-refundable cancellation consumes the applied credit" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation("op-4", %{
          "group_id" => "group-82",
          "rate_plan" => "advance_purchase"
        }),
        apply_credit_operation("op-5", "group-82", 11_000, %{"occurred_on" => "2026-11-27"}),
        cancel_operation("op-6", "group-82", %{"occurred_on" => "2026-11-28"})
      ])

      # the lot is consumed, not restored
      assert json_response(get_guest_credit("guest-22"), 200)["data"]["lots"] == []
      assert json_response(get_ledger("2026-12-01"), 200)["data"]["credit_liability_cents"] == 0
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
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
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

  describe "durable idempotency" do
    test "a retry of an applied operation returns the exact original result without reapplying it" do
      post_batch([open_group_operation("op-1")])

      conn = post_batch([pay_operation("op-2", "group-81", 5_000)])
      original = hd(results(conn))

      conn = post_batch([pay_operation("op-2", "group-81", 5_000)])
      assert results(conn) == [original]

      data = json_response(get_group("group-81"), 200)["data"]
      assert data["revision"] == 2
      assert data["deposit_paid_cents"] == 5_000

      assert json_response(get_ledger(), 200)["data"]["cash_held_cents"] == 5_000
    end

    test "a retry returns the stored result even after the domain has moved on" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 5_000)])

      conn = post_batch([reschedule_operation("op-3", "group-81", "2026-12-15")])
      original = hd(results(conn))

      post_batch([cancel_operation("op-4", "group-81", %{"occurred_on" => "2026-11-20"})])

      conn = post_batch([reschedule_operation("op-3", "group-81", "2026-12-15")])
      assert results(conn) == [original]
    end

    test "JSON object key order is irrelevant to payload equivalence" do
      post_batch([open_group_operation("op-1")])

      conn =
        post_batch_json("""
        {"operations": [{
          "amount_cents": 5000,
          "type": "record_cash_payment",
          "group_id": "group-81",
          "occurred_on": "2026-10-04",
          "operation_id": "op-2"
        }]}
        """)

      assert hd(results(conn))["status"] == "applied"

      conn =
        post_batch_json("""
        {"operations": [{
          "operation_id": "op-2",
          "occurred_on": "2026-10-04",
          "group_id": "group-81",
          "type": "record_cash_payment",
          "amount_cents": 5000
        }]}
        """)

      assert hd(results(conn))["status"] == "applied"
      assert hd(results(conn))["revision"] == 2

      data = json_response(get_group("group-81"), 200)["data"]
      assert data["deposit_paid_cents"] == 5_000
    end

    test "array order and values remain significant" do
      conn =
        post_batch([
          open_group_operation("op-1")
        ])

      assert hd(results(conn))["status"] == "applied"

      # the same rooms in a different order is a different payload
      conn =
        post_batch([
          open_group_operation("op-1", %{
            "rooms" => [
              %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
              %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
            ]
          })
        ])

      assert hd(results(conn)) == %{
               "operation_id" => "op-1",
               "status" => "rejected",
               "code" => "operation_id_conflict",
               "group_id" => "group-81"
             }

      # so is a different value
      conn = post_batch([open_group_operation("op-1", %{"property_id" => "par-thon"})])

      assert hd(results(conn))["code"] == "operation_id_conflict"
    end

    test "rejected results are remembered just like applied results" do
      conn =
        post_batch([
          open_group_operation("op-1"),
          apply_credit_operation("op-2", "group-81", 5_000)
        ])

      original = result_for(conn, "op-2")
      assert original["code"] == "insufficient_credit"

      # later operations issue credit that would make the rejected operation valid
      post_batch([
        open_group_operation("op-3", %{"group_id" => "group-82"}),
        pay_operation("op-4", "group-82", 10_000),
        cancel_operation("op-5", "group-82", %{
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        })
      ])

      conn = post_batch([apply_credit_operation("op-2", "group-81", 5_000)])
      assert results(conn) == [original]
    end

    test "reusing an identifier with a different payload does not replace the original record" do
      conn = post_batch([open_group_operation("op-1")])
      original = hd(results(conn))

      conn = post_batch([open_group_operation("op-1", %{"arrival_on" => "2026-12-11"})])
      assert hd(results(conn))["code"] == "operation_id_conflict"

      # the original result is intact and still returned verbatim
      conn = post_batch([open_group_operation("op-1")])
      assert results(conn) == [original]

      assert json_response(get_operation("op-1"), 200)["data"] == original

      # the conflicting submission changed nothing
      data = json_response(get_group("group-81"), 200)["data"]
      assert data["arrival_on"] == "2026-12-10"
      assert data["revision"] == 1
    end

    test "an exact retry of a stale rejection returns the stored revision details" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 1_000)])

      conn = post_batch([pay_operation("op-3", "group-81", 5_000, %{"expected_revision" => 1})])
      original = hd(results(conn))
      assert original["code"] == "stale_revision"
      assert original["actual_revision"] == 2

      # the group advances further after the rejection
      post_batch([pay_operation("op-4", "group-81", 1_000)])

      conn = post_batch([pay_operation("op-3", "group-81", 5_000, %{"expected_revision" => 1})])
      assert results(conn) == [original]
    end

    test "retrying a stale operation with a corrected expected_revision is a conflict" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 1_000)])

      conn = post_batch([pay_operation("op-3", "group-81", 5_000, %{"expected_revision" => 1})])
      assert hd(results(conn))["code"] == "stale_revision"

      conn = post_batch([pay_operation("op-3", "group-81", 5_000, %{"expected_revision" => 2})])
      assert hd(results(conn))["code"] == "operation_id_conflict"

      # the corrected attempt was not applied
      data = json_response(get_group("group-81"), 200)["data"]
      assert data["revision"] == 2
      assert data["deposit_paid_cents"] == 1_000
    end

    test "a duplicate operation_id inside one batch is applied once" do
      post_batch([open_group_operation("op-1")])

      conn =
        post_batch([
          pay_operation("op-2", "group-81", 5_000),
          pay_operation("op-2", "group-81", 5_000)
        ])

      [first, second] = results(conn)
      assert first["status"] == "applied"
      assert second == first

      data = json_response(get_group("group-81"), 200)["data"]
      assert data["revision"] == 2
      assert data["deposit_paid_cents"] == 5_000
    end

    test "operations without a usable operation_id are not remembered" do
      conn =
        post_batch([
          %{
            "operation_id" => 123,
            "type" => "record_cash_payment",
            "group_id" => "group-81",
            "occurred_on" => "2026-10-04",
            "amount_cents" => 100
          }
        ])

      assert hd(results(conn))["code"] == "invalid_operation"

      assert json_response(get_operation("123"), 404) == %{
               "error" => %{"code" => "operation_not_found"}
             }
    end

    test "concurrent retries have at-most-once effects" do
      post_batch([open_group_operation("op-1")])

      operation = pay_operation("op-2", "group-81", 5_000)

      results =
        1..10
        |> Enum.map(fn _ -> Task.async(fn -> hd(results(post_batch([operation]))) end) end)
        |> Enum.map(&Task.await(&1, 10_000))

      assert Enum.uniq(results) == [
               %{
                 "operation_id" => "op-2",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             ]

      data = json_response(get_group("group-81"), 200)["data"]
      assert data["revision"] == 2
      assert data["deposit_paid_cents"] == 5_000
    end
  end

  describe "unexpected faults" do
    # A room rate whose lodging total cannot be stored: validation accepts the
    # integer, but the write fails after the operation has begun.
    @crashing_operation %{
      open_group_operation("op-crash", %{"group_id" => "group-crash"})
      | "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 4_611_686_018_427_387_904}]
    }

    test "an unexpected exception aborts the batch with 500 and is not remembered" do
      # Phoenix renders and sends the 500 response, then re-raises the fault;
      # the partner gateway loses the response and may retry the batch.
      request_conn = build_conn()

      assert_raise Exqlite.Error, fn ->
        post(request_conn, "/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation("op-1"),
            @crashing_operation,
            pay_operation("op-2", "group-81", 5_000)
          ]
        })
      end

      assert_received {_ref, {500, _headers, _body}}

      # the fault is not remembered as an idempotent result
      assert json_response(get_operation("op-crash"), 404) == %{
               "error" => %{"code" => "operation_not_found"}
             }

      # the operations before the fault committed
      data = json_response(get_group("group-81"), 200)["data"]
      assert data["revision"] == 1

      # the operation after the fault was never processed
      assert json_response(get_operation("op-2"), 404)["error"]["code"] == "operation_not_found"
      assert data["deposit_paid_cents"] == 0

      # the gateway may retry the batch: the committed operation is idempotent
      conn = post_batch([open_group_operation("op-1")])

      assert results(conn) == [
               %{
                 "operation_id" => "op-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]
    end
  end
end
