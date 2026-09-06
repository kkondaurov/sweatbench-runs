defmodule GroupStayWeb.RoomAccountingTest do
  @moduledoc """
  End-to-end coverage of room-level accounting and the cancel_rooms
  operation: room fill order, room views, settling selected rooms, and the
  group totals over active rooms only.
  """

  use GroupStayWeb.ConnCase, async: false

  import GroupStay.PartnerHelpers

  defp issue_credit(prefix \\ "x") do
    post_batch([
      open_group_operation("op-#{prefix}-open", %{"group_id" => "group-#{prefix}"}),
      pay_operation("op-#{prefix}-pay", "group-#{prefix}", 10_000),
      cancel_operation("op-#{prefix}-cancel", "group-#{prefix}", %{
        "occurred_on" => "2026-11-10",
        "refund_method" => "hotel_credit"
      })
    ])
  end

  describe "room-level accounting" do
    test "cash fills room deposits in the rooms' original order" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 12_000)])

      rooms = json_response(get_group("group-81"), 200)["data"]["rooms"]

      assert Enum.map(rooms, &{&1["room_id"], &1["cash_paid_cents"]}) ==
               [{"room-a", 9_000}, {"room-b", 3_000}]

      assert Enum.map(rooms, &{&1["room_id"], &1["deposit_due_cents"]}) ==
               [{"room-a", 9_000}, {"room-b", 10_500}]
    end

    test "rooms expose their status, lodging, deposit, and funding" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 12_000)])

      assert [room_a, room_b] = json_response(get_group("group-81"), 200)["data"]["rooms"]

      assert room_a == %{
               "room_id" => "room-a",
               "nightly_rate_cents" => 15_000,
               "status" => "active",
               "lodging_total_cents" => 45_000,
               "deposit_due_cents" => 9_000,
               "cash_paid_cents" => 9_000,
               "credit_paid_cents" => 0
             }

      assert room_b["lodging_total_cents"] == 52_500
      assert room_b["status"] == "active"
      assert room_b["cash_paid_cents"] == 3_000
      assert room_b["credit_paid_cents"] == 0
    end

    test "credit continues filling after cash, lot by lot" do
      issue_credit()

      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 12_000),
        apply_credit_operation("op-3", "group-81", 2_000, %{"occurred_on" => "2026-11-27"})
      ])

      data = json_response(get_group("group-81"), 200)["data"]

      assert Enum.map(
               data["rooms"],
               &{&1["room_id"], &1["cash_paid_cents"], &1["credit_paid_cents"]}
             ) ==
               [{"room-a", 9_000, 0}, {"room-b", 3_000, 2_000}]

      assert data["cash_paid_cents"] == 12_000
      assert data["credit_paid_cents"] == 2_000
      assert data["deposit_paid_cents"] == 14_000
      assert data["outstanding_deposit_cents"] == 5_500
    end
  end

  describe "cancel_rooms" do
    test "settles the selected rooms and leaves the others unchanged" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 12_000)])

      conn =
        post_batch([
          cancel_rooms_operation("op-3", "group-81", ["room-b"], %{"occurred_on" => "2026-11-20"})
        ])

      assert results(conn) == [
               %{
                 "operation_id" => "op-3",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "cancelled_room_ids" => ["room-b"],
                 "refunded_cents" => 3_000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]

      data = json_response(get_group("group-81"), 200)["data"]

      assert data["status"] == "active"
      assert data["lodging_total_cents"] == 45_000
      assert data["deposit_due_cents"] == 9_000
      assert data["deposit_paid_cents"] == 9_000
      assert data["cash_paid_cents"] == 9_000
      assert data["credit_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 0

      assert [room_a, room_b] = data["rooms"]
      assert room_a["status"] == "active"
      assert room_a["cash_paid_cents"] == 9_000
      assert room_b["status"] == "cancelled"
      assert room_b["cash_paid_cents"] == 0
      assert room_b["credit_paid_cents"] == 0

      assert json_response(get_ledger("2026-12-01"), 200)["data"] == %{
               "cash_held_cents" => 9_000,
               "cash_refunded_cents" => 3_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "returns cancelled_room_ids in the group's original room order" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 12_000)])

      conn =
        post_batch([
          cancel_rooms_operation("op-3", "group-81", ["room-b", "room-a"], %{
            "occurred_on" => "2026-11-20"
          })
        ])

      assert hd(results(conn))["cancelled_room_ids"] == ["room-a", "room-b"]

      # no active rooms remain, so the group becomes cancelled
      data = json_response(get_group("group-81"), 200)["data"]
      assert data["status"] == "cancelled"
      assert data["deposit_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 0

      later =
        post_batch([
          pay_operation("op-4", "group-81", 100),
          cancel_rooms_operation("op-5", "group-81", ["room-a"])
        ])

      assert Enum.map(results(later), & &1["code"]) == ["group_not_active", "group_not_active"]
    end

    test "computes the hotel-credit bonus once on the combined cash" do
      post_batch([
        open_group_operation("op-1", %{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 25_025},
            %{"room_id" => "room-b", "nightly_rate_cents" => 25_025}
          ]
        }),
        pay_operation("op-2", "group-81", 10_010)
      ])

      conn =
        post_batch([
          cancel_rooms_operation("op-3", "group-81", ["room-a", "room-b"], %{
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          })
        ])

      result = hd(results(conn))

      # 10_010 cash combined: 10_010 + round_half_up(1_001) = 11_011, not
      # 2 x (5_005 + 501) = 11_012
      assert result["credit_issued_cents"] == 11_011
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0

      assert json_response(get_guest_credit("guest-22", "2026-11-21"), 200)["data"]["lots"] == [
               %{
                 "source_operation_id" => "op-3",
                 "remaining_cents" => 11_011,
                 "expires_on" => "2027-11-21"
               }
             ]
    end

    test "settles selected rooms non-refundably" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 12_000)])

      conn =
        post_batch([
          cancel_rooms_operation("op-3", "group-81", ["room-a"], %{"occurred_on" => "2026-12-01"})
        ])

      assert hd(results(conn))["retained_cents"] == 9_000

      data = json_response(get_group("group-81"), 200)["data"]
      assert data["status"] == "active"
      assert data["deposit_paid_cents"] == 3_000
      assert data["outstanding_deposit_cents"] == 7_500

      assert json_response(get_ledger("2026-12-01"), 200)["data"]["cash_retained_cents"] == 9_000
    end

    test "restores only the selected rooms' applied credit" do
      issue_credit()

      post_batch([
        open_group_operation("op-1"),
        apply_credit_operation("op-2", "group-81", 5_000, %{"occurred_on" => "2026-11-20"}),
        pay_operation("op-3", "group-81", 3_000)
      ])

      conn =
        post_batch([
          cancel_rooms_operation("op-4", "group-81", ["room-a"], %{"occurred_on" => "2026-11-21"})
        ])

      result = hd(results(conn))
      assert result["refunded_cents"] == 3_000
      assert result["credit_issued_cents"] == 0

      # the restored credit is whole again
      assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"][
               "available_cents"
             ] == 11_000

      assert json_response(get_ledger("2026-12-01"), 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 3_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 10_000,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 11_000,
               "credit_shortfall_cents" => 0
             }
    end

    test "consumes the selected rooms' credit when non-refundable" do
      issue_credit()

      post_batch([
        open_group_operation("op-1"),
        apply_credit_operation("op-2", "group-81", 5_000, %{"occurred_on" => "2026-11-20"})
      ])

      conn =
        post_batch([
          cancel_rooms_operation("op-3", "group-81", ["room-a"], %{"occurred_on" => "2026-12-01"})
        ])

      assert hd(results(conn))["retained_cents"] == 0

      # the applied credit was consumed, not restored
      assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"][
               "available_cents"
             ] == 6_000

      assert json_response(get_ledger("2026-12-01"), 200)["data"]["credit_liability_cents"] ==
               6_000
    end

    test "rejects room selections that are not distinct active rooms of the group" do
      post_batch([
        open_group_operation("op-1"),
        open_group_operation("op-2", %{
          "group_id" => "group-82",
          "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 10_000}]
        }),
        cancel_rooms_operation("op-3", "group-81", ["room-a"])
      ])

      cases = [
        {"unknown room", ["room-z"]},
        {"room of another group", ["room-c"]},
        {"duplicate rooms", ["room-a", "room-a"]},
        {"already cancelled room", ["room-a"]},
        {"already cancelled room among valid", ["room-b", "room-a"]},
        {"empty selection", []},
        {"non-string identifier", [1]},
        {"missing selection", nil},
        {"not a list", "room-b"}
      ]

      for {{label, room_ids}, n} <- Enum.with_index(cases) do
        conn = post_batch([cancel_rooms_operation("op-#{n + 10}", "group-81", room_ids)])
        result = hd(results(conn))
        assert result["status"] == "rejected", label
        assert result["code"] == "invalid_rooms", label
      end

      # the group and its remaining room are untouched
      data = json_response(get_group("group-81"), 200)["data"]
      assert data["status"] == "active"
      assert data["deposit_paid_cents"] == 0
      assert data["revision"] == 2
    end

    test "hotel credit is not a way around a non-refundable policy" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 12_000)])

      conn =
        post_batch([
          cancel_rooms_operation("op-3", "group-81", ["room-a"], %{
            "occurred_on" => "2026-12-01",
            "refund_method" => "hotel_credit"
          })
        ])

      assert hd(results(conn)) == %{
               "operation_id" => "op-3",
               "status" => "rejected",
               "code" => "refund_method_not_available",
               "group_id" => "group-81"
             }

      data = json_response(get_group("group-81"), 200)["data"]
      assert data["status"] == "active"
      assert data["revision"] == 2
      assert data["deposit_paid_cents"] == 12_000
    end

    test "follows the revision contract" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 12_000)])

      conn =
        post_batch([
          cancel_rooms_operation("op-3", "group-81", ["room-a"], %{"expected_revision" => 1})
        ])

      assert hd(results(conn)) == %{
               "operation_id" => "op-3",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      conn =
        post_batch([
          cancel_rooms_operation("op-4", "group-81", ["room-a"], %{"expected_revision" => 2})
        ])

      assert hd(results(conn))["status"] == "applied"
      assert hd(results(conn))["revision"] == 3

      conn = post_batch([cancel_rooms_operation("op-5", "group-none", ["room-a"])])
      assert hd(results(conn))["code"] == "group_not_found"
    end

    test "is durably idempotent" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 12_000)])

      operation =
        cancel_rooms_operation("op-3", "group-81", ["room-a"], %{"occurred_on" => "2026-11-20"})

      original = hd(results(post_batch([operation])))
      assert original["refunded_cents"] == 9_000

      assert results(post_batch([operation])) == [original]

      data = json_response(get_group("group-81"), 200)["data"]
      assert data["revision"] == 3
      assert json_response(get_ledger("2026-12-01"), 200)["data"]["cash_refunded_cents"] == 9_000
    end
  end

  describe "cancel_group after cancel_rooms" do
    test "settles only the remaining active rooms" do
      conn =
        post_batch([
          open_group_operation("op-1"),
          pay_operation("op-2", "group-81", 12_000),
          cancel_rooms_operation("op-3", "group-81", ["room-a"], %{"occurred_on" => "2026-11-20"}),
          cancel_operation("op-4", "group-81", %{"occurred_on" => "2026-11-21"})
        ])

      assert Enum.map(results(conn), & &1["status"]) ==
               ["applied", "applied", "applied", "applied"]

      # room-a was already settled by cancel_rooms; cancel_group settles only
      # the remaining active room's cash
      assert result_for(conn, "op-3")["refunded_cents"] == 9_000
      assert result_for(conn, "op-4")["refunded_cents"] == 3_000

      data = json_response(get_group("group-81"), 200)["data"]
      assert data["status"] == "cancelled"

      assert json_response(get_ledger("2026-12-01"), 200)["data"]["cash_refunded_cents"] == 12_000
    end
  end
end
