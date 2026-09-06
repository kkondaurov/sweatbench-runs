defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Groups

  @base_open %{
    "operation_id" => "op-1001",
    "type" => "open_group",
    "occurred_on" => "2026-10-03",
    "group_id" => "group-81",
    "guest_id" => "guest-22",
    "property_id" => "ams-canal",
    "arrival_on" => "2026-12-10",
    "departure_on" => "2026-12-13",
    "rate_plan" => "flexible",
    "rooms" => [
      %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
      %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
    ]
  }

  defp post_batch(conn, operations) do
    resp = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    {:ok, json} = Jason.decode(resp.resp_body)
    {resp, json}
  end

  defp submit(conn, op), do: post_batch(conn, [op])

  defp result_for(conn, op) do
    {_resp, json} = submit(conn, op)
    hd(json["results"])
  end

  describe "POST /api/v1/partner-batches" do
    test "opens a group with deposit due, revision, and lodging math", %{conn: conn} do
      result = result_for(conn, @base_open)

      assert result == %{
               "operation_id" => "op-1001",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }
    end

    test "accepts cash within outstanding and reports the rest", %{conn: conn} do
      result_for(conn, @base_open)

      payment = %{
        "operation_id" => "op-1002",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 19_500
      }

      assert result_for(conn, payment) == %{
               "operation_id" => "op-1002",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 19_500,
               "outstanding_deposit_cents" => 0,
               "revision" => 2
             }
    end

    test "returns one result per operation in order and keeps processing after rejection", %{
      conn: conn
    } do
      unknown = %{"operation_id" => "op-x", "type" => "mystery_op"}

      too_much = %{
        "operation_id" => "op-p2",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 999_999
      }

      {resp, json} =
        post_batch(conn, [
          @base_open,
          unknown,
          too_much,
          %{
            "operation_id" => "op-p3",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 100
          }
        ])

      assert resp.status == 200

      assert json["results"] == [
               %{
                 "operation_id" => "op-1001",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{"operation_id" => "op-x", "status" => "rejected", "code" => "invalid_operation"},
               %{
                 "operation_id" => "op-p2",
                 "status" => "rejected",
                 "code" => "payment_exceeds_outstanding",
                 "group_id" => "group-81"
               },
               %{
                 "operation_id" => "op-p3",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 100,
                 "outstanding_deposit_cents" => 19_400,
                 "revision" => 2
               }
             ]
    end

    test "a rejected operation leaves the group and ledger untouched", %{conn: conn} do
      result_for(conn, @base_open)

      bad_payment = %{
        "operation_id" => "op-bad",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "expected_revision" => 9,
        "amount_cents" => 100
      }

      assert result_for(conn, bad_payment) == %{
               "operation_id" => "op-bad",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 9,
               "actual_revision" => 1
             }

      assert Groups.fetch("group-81").revision == 1
    end

    test "returns 422 invalid_batch when operations is missing or not an array", %{conn: conn} do
      assert post(conn, "/api/v1/partner-batches", %{}) |> json_response(422) == %{
               "error" => %{"code" => "invalid_batch"}
             }

      assert post(conn, "/api/v1/partner-batches", %{"operations" => "nope"})
             |> json_response(422) == %{"error" => %{"code" => "invalid_batch"}}
    end
  end

  describe "open_group validation" do
    test "group_already_exists", %{conn: conn} do
      result_for(conn, @base_open)

      assert result_for(conn, @base_open) == %{
               "operation_id" => "op-1001",
               "status" => "rejected",
               "code" => "group_already_exists",
               "group_id" => "group-81"
             }
    end

    test "invalid_stay without a night", %{conn: conn} do
      op = %{@base_open | "departure_on" => "2026-12-10"}

      assert result_for(conn, op) == %{
               "operation_id" => "op-1001",
               "status" => "rejected",
               "code" => "invalid_stay",
               "group_id" => "group-81"
             }
    end

    test "invalid_rooms for duplicate identifiers and empty lists", %{conn: conn} do
      dup = %{
        @base_open
        | "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 100},
            %{"room_id" => "room-a", "nightly_rate_cents" => 200}
          ]
      }

      assert result_for(conn, dup)["code"] == "invalid_rooms"

      empty = %{@base_open | "rooms" => []}
      assert result_for(conn, empty)["code"] == "invalid_rooms"
    end

    test "invalid_rate_plan", %{conn: conn} do
      op = %{@base_open | "rate_plan" => "half-board"}
      assert result_for(conn, op)["code"] == "invalid_rate_plan"
    end

    test "missing data is invalid_operation", %{conn: conn} do
      assert result_for(conn, Map.drop(@base_open, ["rooms"]))["code"] == "invalid_operation"

      assert result_for(conn, Map.drop(@base_open, ["occurred_on"]))["code"] ==
               "invalid_operation"

      assert result_for(conn, %{"operation_id" => "x"})["code"] == "invalid_operation"
      assert result_for(conn, "not-a-map") |> is_map()
    end

    test "unusable dates are invalid_stay", %{conn: conn} do
      op = %{@base_open | "arrival_on" => "not-a-date"}

      assert result_for(conn, op) == %{
               "operation_id" => "op-1001",
               "status" => "rejected",
               "code" => "invalid_stay",
               "group_id" => "group-81"
             }

      payment = %{
        "operation_id" => "op-p",
        "type" => "record_cash_payment",
        "occurred_on" => "not-a-date",
        "group_id" => "group-81",
        "amount_cents" => 100
      }

      assert result_for(conn, payment)["code"] == "invalid_stay"

      cancel = %{
        "operation_id" => "op-c",
        "type" => "cancel_group",
        "occurred_on" => "not-a-date",
        "group_id" => "group-81"
      }

      assert result_for(conn, cancel)["code"] == "invalid_stay"
    end

    test "open_group ignores expected_revision", %{conn: conn} do
      op = Map.put(@base_open, "expected_revision", 5)
      assert result_for(conn, op)["status"] == "applied"
    end
  end

  describe "deposit calculation" do
    test "rounds each flexible room separately to the nearest cent", %{conn: conn} do
      op = %{
        "operation_id" => "op-round",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-round",
        "guest_id" => "g-1",
        "property_id" => "p-1",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "r-1", "nightly_rate_cents" => 137},
          %{"room_id" => "r-2", "nightly_rate_cents" => 137}
        ]
      }

      # 3 nights * 137 = 411 cents lodging; 20% = 82.2 -> 82 cents each; total 164.
      assert result_for(conn, op)["deposit_due_cents"] == 164
    end

    test "advance_purchase deposits the full lodging amount", %{conn: conn} do
      op = %{
        @base_open
        | "group_id" => "group-adv",
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      }

      # 3 nights * 10000 = 30000 lodging.
      assert result_for(conn, op)["deposit_due_cents"] == 30_000
    end
  end

  describe "record_cash_payment validation" do
    setup %{conn: conn} do
      result_for(conn, @base_open)
      :ok
    end

    defp payment(overrides \\ %{}) do
      Map.merge(
        %{
          "operation_id" => "op-p",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 100
        },
        overrides
      )
    end

    test "group_not_found", %{conn: conn} do
      assert result_for(conn, payment(%{"group_id" => "group-missing"}))["code"] ==
               "group_not_found"
    end

    test "payment_exceeds_outstanding", %{conn: conn} do
      assert result_for(conn, payment(%{"amount_cents" => 19_501})) == %{
               "status" => "rejected",
               "code" => "payment_exceeds_outstanding",
               "operation_id" => "op-p",
               "group_id" => "group-81"
             }

      assert Groups.fetch("group-81").deposit_paid_cents == 0
    end

    test "invalid_amount for unusable amounts", %{conn: conn} do
      assert result_for(conn, payment(%{"amount_cents" => 0}))["code"] == "invalid_amount"
      assert result_for(conn, payment(%{"amount_cents" => -5}))["code"] == "invalid_amount"
      assert result_for(conn, payment(%{"amount_cents" => 100.5}))["code"] == "invalid_amount"

      assert result_for(conn, Map.drop(payment(), ["amount_cents"]))["code"] ==
               "invalid_operation"
    end

    test "group_not_active after cancellation", %{conn: conn} do
      cancel = %{
        "operation_id" => "op-c",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-81"
      }

      result_for(conn, cancel)

      assert result_for(conn, payment())["code"] == "group_not_active"
    end
  end

  describe "expected_revision" do
    test "applies when expected matches and updates per-batch visibility", %{conn: conn} do
      result_for(conn, @base_open)

      pay1 = %{
        "operation_id" => "op-p1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 100
      }

      pay2 = %{
        "operation_id" => "op-p2",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 100,
        "expected_revision" => 2
      }

      {_resp, json} = post_batch(conn, [pay1, pay2])

      assert json["results"] == [
               %{
                 "operation_id" => "op-p1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 100,
                 "outstanding_deposit_cents" => 19_400,
                 "revision" => 2
               },
               %{
                 "operation_id" => "op-p2",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 100,
                 "outstanding_deposit_cents" => 19_300,
                 "revision" => 3
               }
             ]
    end

    test "matching expected_revision applies cancellations and increments once", %{conn: conn} do
      result_for(conn, @base_open)

      result_for(conn, %{
        "operation_id" => "op-p",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 100
      })

      cancel = %{
        "operation_id" => "op-c",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81",
        "expected_revision" => 2
      }

      assert result_for(conn, cancel)["revision"] == 3
      assert Groups.fetch("group-81").revision == 3
    end

    test "stale revision is rejected before other domain rules", %{conn: conn} do
      result_for(conn, @base_open)

      cancel = %{
        "operation_id" => "op-c",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-81"
      }

      result_for(conn, cancel)

      # Group is cancelled (would be group_not_active) and the amount is
      # unusable, but the stale revision wins.
      stale = %{
        "operation_id" => "op-s",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 0,
        "expected_revision" => 1
      }

      assert result_for(conn, stale) == %{
               "operation_id" => "op-s",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end

    test "missing group wins over stale revision", %{conn: conn} do
      op = %{
        "operation_id" => "op-s",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-nope",
        "amount_cents" => 100,
        "expected_revision" => 1
      }

      assert result_for(conn, op)["code"] == "group_not_found"
    end

    test "stale rejection leaves group and ledger untouched", %{conn: conn} do
      result_for(conn, @base_open)

      result_for(conn, %{
        "operation_id" => "op-p",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 100
      })

      stale = %{
        "operation_id" => "op-s",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "new_arrival_on" => "2027-01-01",
        "expected_revision" => 1
      }

      result_for(conn, stale)

      group = Groups.fetch("group-81")
      assert group.revision == 2
      assert group.arrival_on == ~D[2026-12-10]

      assert Jason.decode!(get(conn, "/api/v1/ledger").resp_body)["data"]["cash_held_cents"] ==
               100
    end
  end

  describe "reschedule_group" do
    test "increments revision even when the stay does not visibly move", %{conn: conn} do
      result_for(conn, @base_open)

      op = %{
        "operation_id" => "op-r",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-10"
      }

      assert result_for(conn, op) == %{
               "operation_id" => "op-r",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-10",
               "new_departure_on" => "2026-12-13",
               "revision" => 2
             }

      data = Groups.to_response(Groups.fetch("group-81"))
      assert data["arrival_on"] == ~D[2026-12-10]
      assert data["revision"] == 2
    end

    test "moves the stay keeping the same number of nights", %{conn: conn} do
      result_for(conn, @base_open)

      op = %{
        "operation_id" => "op-r",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "new_arrival_on" => "2027-01-05"
      }

      assert result_for(conn, op) == %{
               "operation_id" => "op-r",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2027-01-05",
               "new_departure_on" => "2027-01-08",
               "revision" => 2
             }

      data = Groups.to_response(Groups.fetch("group-81"))
      assert data["arrival_on"] == ~D[2027-01-05]
      assert data["departure_on"] == ~D[2027-01-08]
      assert data["lodging_total_cents"] == 97_500
    end

    test "rejects a new arrival on or before the operation date", %{conn: conn} do
      result_for(conn, @base_open)

      op = %{
        "operation_id" => "op-r",
        "type" => "reschedule_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-01"
      }

      assert result_for(conn, op)["code"] == "invalid_stay"
      assert Groups.fetch("group-81").arrival_on == ~D[2026-12-10]
    end

    test "rejects missing or cancelled groups", %{conn: conn} do
      op = %{
        "operation_id" => "op-r",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "new_arrival_on" => "2027-01-05"
      }

      assert result_for(conn, op)["code"] == "group_not_found"

      result_for(conn, @base_open)

      result_for(conn, %{
        "operation_id" => "op-c",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-81"
      })

      assert result_for(conn, op)["code"] == "group_not_active"
    end
  end

  describe "cancel_group" do
    test "refunds cash for a flexible cancellation at least 14 days out", %{conn: conn} do
      result_for(conn, @base_open)

      result_for(conn, %{
        "operation_id" => "op-p",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 19_500
      })

      # Arrival 2026-12-10; cancellation 2026-11-01 is 39 days out.
      cancel = %{
        "operation_id" => "op-c",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81"
      }

      assert result_for(conn, cancel) == %{
               "operation_id" => "op-c",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 19_500,
               "retained_cents" => 0,
               "revision" => 3
             }
    end

    test "retains cash for a late flexible cancellation", %{conn: conn} do
      result_for(conn, @base_open)

      result_for(conn, %{
        "operation_id" => "op-p",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 500
      })

      # 13 days before arrival is not refundable.
      cancel = %{
        "operation_id" => "op-c",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-27",
        "group_id" => "group-81"
      }

      result = result_for(conn, cancel)
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 500
    end

    test "exactly 14 days before arrival is refundable", %{conn: conn} do
      result_for(conn, @base_open)

      result_for(conn, %{
        "operation_id" => "op-p",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 700
      })

      cancel = %{
        "operation_id" => "op-c",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      }

      result = result_for(conn, cancel)
      assert result["refunded_cents"] == 700
      assert result["retained_cents"] == 0
    end

    test "advance_purchase cancellations are always retained", %{conn: conn} do
      adv = %{@base_open | "group_id" => "group-adv", "rate_plan" => "advance_purchase"}
      result_for(conn, adv)

      result_for(conn, %{
        "operation_id" => "op-p",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-adv",
        "amount_cents" => 30_000
      })

      cancel = %{
        "operation_id" => "op-c",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-adv"
      }

      result = result_for(conn, cancel)
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 30_000
    end

    test "cancelled groups reject later operations", %{conn: conn} do
      result_for(conn, @base_open)

      cancel = %{
        "operation_id" => "op-c",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81"
      }

      result_for(conn, cancel)

      assert result_for(conn, cancel)["code"] == "group_not_active"

      pay = %{
        "operation_id" => "op-p",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 100
      }

      assert result_for(conn, pay)["code"] == "group_not_active"
    end
  end
end
